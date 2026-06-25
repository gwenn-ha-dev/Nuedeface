// Nuedeface — le document autoritaire, arbre adressé par ID.
//
// État = fold d'un LOG DE COMMANDES CANONIQUES. Une commande canonique est un [String:Any]
// normalisé : ID générés gravés dedans, temps en SAMPLES (le bord protocole parle en secondes).
// `applyCommand` est le mutateur pur ; `mutate` = applyCommand + append au log + rev++.
// undo = drop de la dernière commande + REFOLD depuis l'état de base (master + 2 pistes seed).
//
// Périmètre de CETTE étape (structurel) : tracks/trackOrder, clips multiples, chaîne d'inserts
// (fxOrder), verbes track.*/clip.*/insert.*, set scalaire. Déféré (forme prête) : automation
// (Param.auto), bus multiples + sends, autres types d'inserts. Un seul type d'insert : "eq".

import Foundation
import AVFoundation

final class Document {
    let sampleRate: Double = 48_000

    struct Insert {
        let id: String
        var type: String                 // "eq"/"reverb"/"delay"/"distortion" (typés) ou "au" (générique)
        var bypass = false
        var params: [String: Double]     // eq → {gain, freq} ; au → clés = identifiers de l'AUParameterTree
        var subType: String? = nil       // "au" seulement : 4cc de l'AU effet Apple (ex. "dcmp")
    }
    struct Send {
        let id: String
        var dest: String          // bus destination (aux)
        var level = 1.0           // gain du tap (linéaire)
        var pre = false           // pré-fader (tap post-insert, avant gain/pan/mute) ; sinon post-fader
    }
    struct Clip {
        let id: String
        let trackId: String
        var asset: String                // assetId
        var start: Int                   // position timeline (samples)
        var offset: Int                  // trim tête dans le fichier (samples)
        var duration: Int                // longueur jouée (samples)
        var fadeIn: Int = 0              // samples
        var fadeOut: Int = 0
        var fadeShape: String = "linear" // galbe des fades (in ET out) : "linear" | "exp" | "scurve"
        var gain: Double = 1.0
    }
    struct Track {
        let id: String
        var name: String
        var color: String = "#8aa0ff"
        var gain = 1.0
        var pan = 0.0
        var mute = false
        var solo = false
        var output = "master"
        var fx: [String: Insert] = [:]
        var fxOrder: [String] = []
        var sends: [Send] = []        // taps parallèles vers des bus aux (pré/post-fader)
        var clips: [String: Clip] = [:]
        var clipOrder: [String] = []
    }
    struct Bus {
        let id: String
        var name: String
        var gain = 1.0
        var mute = false
        var output = "master"             // route vers un autre bus ou master ; master → sortie physique (ignoré)
        var fx: [String: Insert] = [:]    // chaîne d'inserts du bus (ex. limiteur/multibande sur le master)
        var fxOrder: [String] = []
        var sends: [Send] = []            // sends de bus → autre bus aux (post-fader seulement)
    }
    struct AssetInfo { var path: String; var sampleRate: Double; var channels: Int; var frames: Int }

    // automation (Param.auto) — sidecar indexé par path. t en samples, v dans l'unité du param.
    struct AutoPoint { let id: String; var t: Int; var v: Double; var curve: String }
    struct Lane { var on: Bool; var points: [AutoPoint] }   // points triés par t

    private(set) var tracks: [String: Track] = [:]
    private(set) var trackOrder: [String] = []
    private(set) var buses: [String: Bus] = [:]
    private(set) var busOrder: [String] = []
    private(set) var assets: [String: AssetInfo] = [:]   // collant, hors log d'undo
    private(set) var automation: [String: Lane] = [:]    // path -> lane
    private(set) var rev = 0
    private(set) var log: [[String: Any]] = []
    private var redoStack: [[String: Any]] = []      // commandes annulées, rejouables par redo (vidé à toute nouvelle mutation)
    private var counters: [String: Int] = [:]

    init() { seedBase() }

    /// État de base (hors log) : un master + UNE piste vide (avec un insert EQ). C'est aussi le plancher d'undo
    /// et l'ancre du contrat de persistance (le log d'un projet est rejoué par-dessus) → `t1`/`i1` restent stables.
    private func seedBase() {
        tracks = [:]; trackOrder = []; buses = [:]; busOrder = []; automation = [:]
        buses["master"] = Bus(id: "master", name: "Master")
        busOrder = ["master"]
        var t = Track(id: "t1", name: "Piste 1")
        t.fx["i1"] = Insert(id: "i1", type: "eq", params: ["gain": 0, "freq": 1_000])
        t.fxOrder = ["i1"]
        tracks["t1"] = t; trackOrder = ["t1"]
        counters = ["t": 1, "i": 1]   // t1 et i1 déjà pris
    }

    func freshId(_ prefix: String) -> String {
        let n = (counters[prefix] ?? 0) + 1; counters[prefix] = n
        return "\(prefix)\(n)"
    }

    /// Params par défaut par type d'insert (nil = type inconnu). Schéma exposé via describe.
    static func defaultParams(_ type: String) -> [String: Double]? {
        switch type {
        case "eq":         return ["gain": 0, "freq": 1_000]
        case "reverb":     return ["mix": 30, "preset": 6]            // preset 6 = largeHall
        case "delay":      return ["time": 0.25, "feedback": 30, "mix": 25]
        case "distortion": return ["drive": -6, "mix": 40, "preset": 0]
        default:           return nil
        }
    }

    /// Au moins une piste en solo ? (alors seules les pistes solo sont audibles)
    func anySolo() -> Bool { trackOrder.contains { tracks[$0]?.solo == true } }

    /// `start` peut-il atteindre `target` en suivant outputs ET sends de bus ? (détection de boucle de feedback)
    private func busReaches(from start: String, target: String) -> Bool {
        var stack = [start]; var seen = Set<String>()
        while let cur = stack.popLast() {
            if cur == target { return true }
            if cur == "master" || seen.contains(cur) { continue }
            seen.insert(cur)
            guard let b = buses[cur] else { continue }
            stack.append(b.output)
            for snd in b.sends { stack.append(snd.dest) }
        }
        return false
    }

    /// Le bus `busId`, s'il routait vers `proposedOutput`, atteindrait-il master sans cycle ?
    private func wouldReachMaster(busId: String, proposedOutput: String) -> Bool {
        var cur = proposedOutput
        var seen: Set<String> = [busId]                 // revenir à la source = cycle
        for _ in 0...(buses.count + 1) {
            if cur == "master" { return true }
            guard let b = buses[cur], !seen.contains(cur) else { return false }
            seen.insert(cur); cur = b.output
        }
        return false
    }

    /// Une automation active (on + au moins un point) pour ce path ?
    func isAutomated(_ path: String) -> Bool {
        guard let l = automation[path] else { return false }
        return l.on && !l.points.isEmpty
    }

    /// Valeur résolue de la lane à l'instant `s` (samples) — nil si pas automatée. Hold avant/après les bornes.
    func laneValue(_ path: String, atSample s: Int) -> Double? {
        guard let l = automation[path] else { return nil }
        return Document.laneValue(l, atSample: s)
    }

    /// Évaluateur PUR (sur une Lane copiée) : sert au moteur live qui travaille sur un snapshot immuable
    /// des lanes (pris au build du graphe) pour ne JAMAIS lire `automation` pendant qu'une mutation l'écrit.
    static func laneValue(_ l: Lane, atSample s: Int) -> Double? {
        guard l.on, let first = l.points.first, let last = l.points.last else { return nil }
        if s <= first.t { return first.v }
        if s >= last.t { return last.v }
        for k in 1..<l.points.count where s < l.points[k].t {
            let a = l.points[k - 1], b = l.points[k]
            if a.curve == "hold" { return a.v }
            let frac = Double(s - a.t) / Double(max(1, b.t - a.t))
            // "bezier" = smootherstep (S-curve cubique, dérivées nulles aux extrémités → transition douce ET
            // MONOTONE : ne dépasse jamais [a.v, b.v], sûr pour le gain). Sinon interpolation linéaire.
            let e = a.curve == "bezier" ? frac * frac * frac * (frac * (6 * frac - 15) + 10) : frac
            return a.v + (b.v - a.v) * e
        }
        return last.v
    }

    /// Copie immuable des lanes ACTIVES pour un ensemble de paths (Lane/AutoPoint sont des value types → deep copy).
    func automationSnapshot(paths: Set<String>) -> [String: Lane] {
        var out: [String: Lane] = [:]
        for p in paths { if let l = automation[p], l.on, !l.points.isEmpty { out[p] = l } }
        return out
    }

    // IMPORT : sticky, hors undo. Sonde le fichier (SR/canaux/frames) pour que l'UI place les clips sans décoder.
    func importAsset(path: String) -> String {
        for (id, a) in assets where a.path == path { return id }   // idempotent
        let id = freshId("a")
        var info = AssetInfo(path: path, sampleRate: sampleRate, channels: 2, frames: 0)
        if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
            info.sampleRate = f.processingFormat.sampleRate
            info.channels = Int(f.processingFormat.channelCount)
            // frames ramenés à 48k (la timeline est en samples @ sampleRate du projet)
            info.frames = Int(Double(f.length) * sampleRate / f.processingFormat.sampleRate)
        }
        assets[id] = info; rev += 1
        return id
    }

    // --- LE mutateur unique ---
    @discardableResult
    func mutate(_ c: [String: Any]) -> String? {
        if let err = applyCommand(c) { return err }
        log.append(c); redoStack.removeAll(); rev += 1; return nil   // toute nouvelle mutation invalide le redo
    }

    func undo() -> Bool {
        guard !log.isEmpty else { return false }
        redoStack.append(log.removeLast())
        seedBase()
        for c in log { _ = applyCommand(c) }
        rev += 1
        return true
    }

    func redo() -> Bool {
        guard let c = redoStack.popLast() else { return false }
        if let _ = applyCommand(c) { return false }   // ne devrait pas échouer (état identique à avant l'undo)
        log.append(c); rev += 1
        return true
    }

    /// Clone IMMUABLE pour lecture concurrente (analyze/loudness/meters/spectrum/export…) hors de la queue d'apply.
    /// tracks/buses/automation/assets sont des value types (dicts COW) → la copie est O(1) jusqu'à la prochaine
    /// mutation du doc autoritaire, qui ne fait alors que dévier SA propre copie : le clone garde l'état figé au
    /// moment de la requête. Le moteur rend depuis ce clone → jamais de lecture du doc pendant qu'une mutation l'écrit.
    func cloneForRead() -> Document {
        let c = Document()                       // seedBase (négligeable) puis on écrase tout l'état observable du render
        c.tracks = tracks; c.trackOrder = trackOrder
        c.buses = buses; c.busOrder = busOrder
        c.assets = assets; c.automation = automation
        c.counters = counters; c.rev = rev
        return c
    }

    // --- persistance : le LOG canonique EST le projet (rejouable). assets + counters en sidecar. ---
    func serialize() -> [String: Any] {
        let assetsRaw = assets.mapValues {
            ["path": $0.path, "sampleRate": $0.sampleRate, "channels": $0.channels, "frames": $0.frames] as [String: Any]
        }
        return ["version": 1, "rev": rev, "assets": assetsRaw, "counters": counters, "log": log]
    }

    func loadProject(_ data: [String: Any]) -> String? {
        guard let savedLog = data["log"] as? [[String: Any]] else { return "projet invalide : 'log' manquant" }
        seedBase()
        redoStack = []
        assets = [:]
        for (id, info) in (data["assets"] as? [String: [String: Any]] ?? [:]) {
            assets[id] = AssetInfo(path: info["path"] as? String ?? "",
                                   sampleRate: (info["sampleRate"] as? NSNumber)?.doubleValue ?? sampleRate,
                                   channels: (info["channels"] as? NSNumber)?.intValue ?? 2,
                                   frames: (info["frames"] as? NSNumber)?.intValue ?? 0)
        }
        if let c = data["counters"] as? [String: Any] {           // pour que freshId ne réutilise pas d'ids
            counters = c.compactMapValues { ($0 as? NSNumber)?.intValue ?? ($0 as? Int) }
        }
        log = []
        for c in savedLog { if let err = applyCommand(c) { return "replay échoué : \(err)" }; log.append(c) }
        rev += 1
        return nil
    }

    // --- mutateur pur : applique une commande canonique (samples, ids présents) ---
    private func applyCommand(_ c: [String: Any]) -> String? {
        let op = c["op"] as? String ?? c["cmd"] as? String ?? ""
        func s(_ k: String) -> String? { c[k] as? String }
        func i(_ k: String) -> Int? { (c[k] as? Int) ?? (c[k] as? NSNumber)?.intValue }
        func d(_ k: String) -> Double? { (c[k] as? Double) ?? (c[k] as? NSNumber)?.doubleValue }

        switch op {
        case "set":
            guard let path = s("path"), let value = c["value"] else { return "set: path/value requis" }
            return setScalar(path: path, value: value)

        case "track.add":
            guard let id = s("id") else { return "track.add: id requis" }
            var t = Track(id: id, name: s("name") ?? id)
            if let col = s("color") { t.color = col }
            tracks[id] = t; trackOrder.append(id)
        case "track.remove":
            guard let id = s("id"), tracks[id] != nil else { return "track inconnue" }
            tracks[id] = nil; trackOrder.removeAll { $0 == id }
        case "track.rename":
            guard let id = s("id"), let n = s("name"), tracks[id] != nil else { return "track.rename: args" }
            tracks[id]?.name = n
        case "track.reorder":
            guard let order = c["order"] as? [String], Set(order) == Set(trackOrder) else { return "track.reorder: ordre invalide" }
            trackOrder = order
        case "track.setOutput":
            guard let id = s("id"), let out = s("output"), tracks[id] != nil, buses[out] != nil else { return "track.setOutput: args" }
            tracks[id]?.output = out

        case "bus.add":
            guard let id = s("id") else { return "bus.add: id requis" }
            buses[id] = Bus(id: id, name: s("name") ?? id); busOrder.append(id)
        case "bus.remove":
            guard let id = s("id"), id != "master", buses[id] != nil else { return "bus.remove: bus inconnu ou master" }
            for tid in trackOrder where tracks[tid]?.output == id { tracks[tid]?.output = "master" }   // re-pointer
            for bid in busOrder where buses[bid]?.output == id { buses[bid]?.output = "master" }
            buses[id] = nil; busOrder.removeAll { $0 == id }
        case "bus.rename":
            guard let id = s("id"), let n = s("name"), buses[id] != nil else { return "bus.rename: args" }
            buses[id]?.name = n
        case "bus.reorder":
            guard let order = c["order"] as? [String], Set(order) == Set(busOrder) else { return "bus.reorder: ordre invalide" }
            busOrder = order
        case "bus.setOutput":
            guard let id = s("id"), let out = s("output"), id != "master", buses[id] != nil, buses[out] != nil else { return "bus.setOutput: args" }
            guard wouldReachMaster(busId: id, proposedOutput: out) else { return "bus.setOutput: cycle ou n'atteint pas master" }
            buses[id]?.output = out

        case "send.add":
            guard let id = s("id"), let dest = s("dest"), buses[dest] != nil else { return "send.add: dest (bus) invalide" }
            let level = max(0, d("level") ?? 1.0)
            let pre = (c["pre"] as? Bool) ?? false
            if let tid = s("trackId"), tracks[tid] != nil {
                tracks[tid]?.sends.append(Send(id: id, dest: dest, level: level, pre: pre))   // piste : pré OU post
            } else if let bid = s("busId"), buses[bid] != nil {
                guard !busReaches(from: dest, target: bid) else { return "send.add: cycle de bus" }
                buses[bid]?.sends.append(Send(id: id, dest: dest, level: level, pre: false))   // bus : post-fader seulement
            } else { return "send.add: trackId ou busId requis" }
        case "send.remove":
            guard let id = s("id") else { return "send.remove: id requis" }
            if let tid = s("trackId"), tracks[tid] != nil { tracks[tid]?.sends.removeAll { $0.id == id } }
            else if let bid = s("busId"), buses[bid] != nil { buses[bid]?.sends.removeAll { $0.id == id } }
            else { return "send.remove: trackId ou busId requis" }

        case "clip.add":
            guard let id = s("id"), let tid = s("trackId"), let asset = s("asset") else { return "clip.add: args" }
            guard tracks[tid] != nil else { return "track inconnue: \(tid)" }
            guard let a = assets[asset] else { return "asset inconnu: \(asset)" }
            let offset = i("offset") ?? 0
            var dur = i("duration") ?? 0
            if dur <= 0 { dur = max(0, a.frames - offset) }
            var clip = Clip(id: id, trackId: tid, asset: asset, start: i("start") ?? 0, offset: offset, duration: dur)
            clip.fadeIn = i("fadeIn") ?? 0; clip.fadeOut = i("fadeOut") ?? 0
            if let sh = s("shape") { clip.fadeShape = sh }
            tracks[tid]?.clips[id] = clip; tracks[tid]?.clipOrder.append(id)
        case "clip.remove":
            guard let id = s("id"), let tid = clipTrack(id) else { return "clip inconnu" }
            tracks[tid]?.clips[id] = nil; tracks[tid]?.clipOrder.removeAll { $0 == id }
        case "clip.move":
            guard let id = s("id"), let tid = clipTrack(id), let start = i("start") else { return "clip.move: args" }
            if let dst = s("trackId"), dst != tid {                 // déplacement INTER-PISTES (trackId = piste cible)
                guard tracks[dst] != nil, let src = tracks[tid]?.clips[id] else { return "clip.move: piste cible inconnue" }
                var moved = Clip(id: src.id, trackId: dst, asset: src.asset, start: max(0, start),
                                 offset: src.offset, duration: src.duration)
                moved.fadeIn = src.fadeIn; moved.fadeOut = src.fadeOut; moved.fadeShape = src.fadeShape; moved.gain = src.gain
                tracks[tid]?.clips[id] = nil; tracks[tid]?.clipOrder.removeAll { $0 == id }
                tracks[dst]?.clips[id] = moved; tracks[dst]?.clipOrder.append(id)
            } else {
                tracks[tid]?.clips[id]?.start = max(0, start)
            }
        case "clip.trim":
            guard let id = s("id"), let tid = clipTrack(id) else { return "clip.trim: args" }
            if let st = i("start") { tracks[tid]?.clips[id]?.start = max(0, st) }   // trim du bord gauche (start+offset+durée atomiques)
            if let off = i("offset") { tracks[tid]?.clips[id]?.offset = max(0, off) }
            if let dur = i("duration") { tracks[tid]?.clips[id]?.duration = max(0, dur) }
        case "clip.setFade":
            guard let id = s("id"), let tid = clipTrack(id) else { return "clip.setFade: args" }
            if let f = i("fadeIn") { tracks[tid]?.clips[id]?.fadeIn = max(0, f) }
            if let f = i("fadeOut") { tracks[tid]?.clips[id]?.fadeOut = max(0, f) }
            if let sh = s("shape") { tracks[tid]?.clips[id]?.fadeShape = sh }
        case "clip.split":
            // coupe le clip en deux à la position timeline `at` ; `id` = nouvelle pièce (droite). Audio continu.
            guard let id = s("id"), let cid = s("clipId"), let tid = clipTrack(cid),
                  let at = i("at"), var orig = tracks[tid]?.clips[cid] else { return "clip.split: args" }
            guard at > orig.start, at < orig.start + orig.duration else { return "clip.split: position hors du clip" }
            let leftDur = at - orig.start
            var right = Clip(id: id, trackId: tid, asset: orig.asset, start: at,
                             offset: orig.offset + leftDur, duration: orig.duration - leftDur)
            right.gain = orig.gain; right.fadeIn = 0; right.fadeOut = orig.fadeOut; right.fadeShape = orig.fadeShape   // droite garde le fadeOut
            orig.duration = leftDur; orig.fadeOut = 0                                 // gauche garde le fadeIn
            orig.fadeIn = min(orig.fadeIn, leftDur)
            tracks[tid]?.clips[cid] = orig
            tracks[tid]?.clips[id] = right
            if let idx = tracks[tid]?.clipOrder.firstIndex(of: cid) { tracks[tid]?.clipOrder.insert(id, at: idx + 1) }
            else { tracks[tid]?.clipOrder.append(id) }
        case "clip.duplicate":
            // copie le clip (même asset/offset/durée/fades/gain) ; `id` = copie, `start` = position (défaut : juste après).
            guard let id = s("id"), let cid = s("clipId"), let tid = clipTrack(cid),
                  let src = tracks[tid]?.clips[cid] else { return "clip.duplicate: args" }
            var copy = Clip(id: id, trackId: tid, asset: src.asset, start: max(0, i("start") ?? (src.start + src.duration)),
                            offset: src.offset, duration: src.duration)
            copy.fadeIn = src.fadeIn; copy.fadeOut = src.fadeOut; copy.fadeShape = src.fadeShape; copy.gain = src.gain
            tracks[tid]?.clips[id] = copy
            if let idx = tracks[tid]?.clipOrder.firstIndex(of: cid) { tracks[tid]?.clipOrder.insert(id, at: idx + 1) }
            else { tracks[tid]?.clipOrder.append(id) }
        case "clip.crossfade":
            // fondu enchaîné sur le chevauchement de a (antérieur) et b (postérieur), même piste.
            guard let a = s("a"), let b = s("b"), let tid = clipTrack(a), clipTrack(b) == tid,
                  let ca = tracks[tid]?.clips[a], let cb = tracks[tid]?.clips[b] else { return "clip.crossfade: a/b même piste requis" }
            let overlap = (ca.start + ca.duration) - cb.start
            guard overlap > 0 else { return "clip.crossfade: pas de chevauchement (déplace b sous a d'abord)" }
            let dur = i("duration").map { min($0, overlap) } ?? overlap
            tracks[tid]?.clips[a]?.fadeOut = min(dur, ca.duration)
            tracks[tid]?.clips[b]?.fadeIn = min(dur, cb.duration)

        case "insert.add":
            guard let id = s("id") else { return "insert.add: id requis" }
            let type = s("type") ?? "eq"
            var ins: Insert
            if type == "au" {
                guard let st = s("subType") else { return "insert.add au: subType requis" }
                guard AU.exists(st) else { return "subType AU inconnu: \(st)" }
                let params = Dictionary(uniqueKeysWithValues: AU.schema(st).map { ($0.id, $0.def) })
                ins = Insert(id: id, type: type, params: params, subType: st)
            } else {
                guard let params = Document.defaultParams(type) else { return "type d'insert non supporté: \(type)" }
                ins = Insert(id: id, type: type, params: params)
            }
            if let tid = s("trackId") {
                guard tracks[tid] != nil else { return "track inconnue: \(tid)" }
                tracks[tid]?.fx[id] = ins; tracks[tid]?.fxOrder.append(id)
            } else if let bid = s("busId") {
                guard buses[bid] != nil else { return "bus inconnu: \(bid)" }
                buses[bid]?.fx[id] = ins; buses[bid]?.fxOrder.append(id)
            } else { return "insert.add: trackId ou busId requis" }
        case "insert.remove":
            guard let id = s("id") else { return "insert.remove: id requis" }
            if let tid = s("trackId"), tracks[tid]?.fx[id] != nil {
                tracks[tid]?.fx[id] = nil; tracks[tid]?.fxOrder.removeAll { $0 == id }
            } else if let bid = s("busId"), buses[bid]?.fx[id] != nil {
                buses[bid]?.fx[id] = nil; buses[bid]?.fxOrder.removeAll { $0 == id }
            } else { return "insert inconnu" }
        case "insert.reorder":
            guard let order = c["order"] as? [String] else { return "insert.reorder: order requis" }
            if let tid = s("trackId"), let t = tracks[tid], Set(order) == Set(t.fxOrder) {
                tracks[tid]?.fxOrder = order
            } else if let bid = s("busId"), let b = buses[bid], Set(order) == Set(b.fxOrder) {
                buses[bid]?.fxOrder = order
            } else { return "insert.reorder: invalide" }
        case "insert.setBypass":
            guard let id = s("id"), let b = c["bypass"] as? Bool else { return "insert.setBypass: args" }
            if let tid = s("trackId"), tracks[tid]?.fx[id] != nil { tracks[tid]?.fx[id]?.bypass = b }
            else if let bid = s("busId"), buses[bid]?.fx[id] != nil { buses[bid]?.fx[id]?.bypass = b }
            else { return "insert.setBypass: introuvable" }

        case "automation.enable", "automation.disable":
            guard let path = s("path") else { return "automation: path requis" }
            var lane = automation[path] ?? Lane(on: false, points: [])
            lane.on = (op == "automation.enable")
            automation[path] = lane
        case "automation.point.add":
            guard let path = s("path"), let id = s("id"), let t = i("t"), let v = d("v") else { return "point.add: args" }
            var lane = automation[path] ?? Lane(on: true, points: [])
            lane.points.append(AutoPoint(id: id, t: max(0, t), v: v, curve: s("curve") ?? "linear"))
            lane.points.sort { $0.t < $1.t }
            automation[path] = lane
        case "automation.point.move":
            guard let path = s("path"), let pid = s("id"), var lane = automation[path],
                  let j = lane.points.firstIndex(where: { $0.id == pid }) else { return "point.move: introuvable" }
            if let t = i("t") { lane.points[j].t = max(0, t) }
            if let v = d("v") { lane.points[j].v = v }
            if let cv = s("curve") { lane.points[j].curve = cv }   // changer le galbe du segment (linear|bezier|hold)
            lane.points.sort { $0.t < $1.t }
            automation[path] = lane
        case "automation.point.remove":
            guard let path = s("path"), let pid = s("id"), var lane = automation[path] else { return "point.remove: lane" }
            lane.points.removeAll { $0.id == pid }
            automation[path] = lane

        default: return "op inconnue: \(op)"
        }
        return nil
    }

    private func clipTrack(_ clipId: String) -> String? {
        for (tid, t) in tracks where t.clips[clipId] != nil { return tid }
        return nil
    }

    // --- set scalaire par path (sous l'arbre adressé par ID) ---
    private func setScalar(path: String, value: Any) -> String? {
        func dbl() -> Double? { (value as? Double) ?? (value as? NSNumber)?.doubleValue }
        func bool() -> Bool? { (value as? Bool) ?? (value as? NSNumber)?.boolValue }
        let c = path.split(separator: "/").map(String.init)

        if c.count >= 2, c[0] == "bus", let bid = c.indices.contains(1) ? c[1] : nil, buses[bid] != nil {
            let p = Array(c.dropFirst(2))
            switch p {
            case ["controls", "gain"]: guard let v = dbl() else { return "gain: nombre" }; buses[bid]?.gain = max(0, v)
            case ["controls", "mute"]: guard let v = bool() else { return "mute: booléen" }; buses[bid]?.mute = v
            default:
                if p.count == 4, p[0] == "fx", p[2] == "params", buses[bid]?.fx[p[1]] != nil, let v = dbl() {
                    buses[bid]?.fx[p[1]]?.params[p[3]] = v
                } else if p.count == 3, p[0] == "sends", p[2] == "level", let j = buses[bid]?.sends.firstIndex(where: { $0.id == p[1] }), let v = dbl() {
                    buses[bid]?.sends[j].level = max(0, v)
                } else { return "chemin bus inconnu: \(path)" }
            }
            return nil
        }

        guard c.count >= 3, c[0] == "track", tracks[c[1]] != nil else { return "chemin inconnu: \(path)" }
        let tid = c[1]
        let p = Array(c.dropFirst(2))
        if p == ["controls", "gain"] {
            guard let v = dbl() else { return "gain: nombre" }; tracks[tid]?.gain = max(0, v)
        } else if p == ["controls", "pan"] {
            guard let v = dbl() else { return "pan: nombre" }; tracks[tid]?.pan = max(-1, min(1, v))
        } else if p == ["controls", "mute"] {
            guard let v = bool() else { return "mute: booléen" }; tracks[tid]?.mute = v
        } else if p == ["controls", "solo"] {
            guard let v = bool() else { return "solo: booléen" }; tracks[tid]?.solo = v
        } else if p.count == 3, p[0] == "clips", p[2] == "gain" {
            guard tracks[tid]?.clips[p[1]] != nil, let v = dbl() else { return "clip/gain inconnu: \(path)" }
            tracks[tid]?.clips[p[1]]?.gain = max(0, v)
        } else if p.count == 4, p[0] == "fx", p[2] == "params" {
            guard tracks[tid]?.fx[p[1]] != nil, let v = dbl() else { return "fx/param inconnu: \(path)" }
            tracks[tid]?.fx[p[1]]?.params[p[3]] = v
        } else if p.count == 3, p[0] == "sends", p[2] == "level" {
            guard let j = tracks[tid]?.sends.firstIndex(where: { $0.id == p[1] }), let v = dbl() else { return "send/level inconnu: \(path)" }
            tracks[tid]?.sends[j].level = max(0, v)
        } else if p.count == 3, p[0] == "sends", p[2] == "pre" {
            guard let j = tracks[tid]?.sends.firstIndex(where: { $0.id == p[1] }), let v = bool() else { return "send/pre inconnu: \(path)" }
            tracks[tid]?.sends[j].pre = v
        } else {
            return "chemin inconnu: \(path)"
        }
        return nil
    }

    // --- sérialisation (temps → secondes au bord) ---
    private func sec(_ samples: Int) -> Double { Double(samples) / sampleRate }

    func snapshot() -> [String: Any] {
        func insertJSON(_ ins: Insert) -> [String: Any] {
            var o: [String: Any] = ["id": ins.id, "type": ins.type, "bypass": ins.bypass, "params": ins.params]
            if let st = ins.subType {       // insert générique "au" : auto-décrit par instance (bornes issues de l'AU)
                o["subType"] = st
                o["schema"] = AU.schema(st).map { sp in
                    ["id": sp.id, "name": sp.name, "unit": sp.unit, "min": sp.min, "max": sp.max, "default": sp.def] as [String: Any]
                }
            }
            return o
        }
        func sendsJSON(_ sends: [Send]) -> [[String: Any]] {
            sends.map { ["id": $0.id, "dest": $0.dest, "level": $0.level, "pre": $0.pre] }
        }
        func trackJSON(_ t: Track) -> [String: Any] {
            let clips: [[String: Any]] = t.clipOrder.compactMap { t.clips[$0] }.map { cl in
                ["id": cl.id, "asset": cl.asset, "start": sec(cl.start), "offset": sec(cl.offset),
                 "duration": sec(cl.duration), "fadeIn": sec(cl.fadeIn), "fadeOut": sec(cl.fadeOut),
                 "fadeShape": cl.fadeShape, "gain": cl.gain]
            }
            return ["id": t.id, "name": t.name, "color": t.color, "output": t.output,
                    "controls": ["gain": t.gain, "pan": t.pan, "mute": t.mute, "solo": t.solo],
                    "fx": t.fx.mapValues(insertJSON), "fxOrder": t.fxOrder,
                    "sends": sendsJSON(t.sends),
                    "clips": clips]
        }
        let assetsJSON = assets.mapValues { a in
            ["path": a.path, "sampleRate": a.sampleRate, "channels": a.channels,
             "frames": a.frames, "duration": sec(a.frames)] as [String: Any]
        }
        let busesJSON = buses.mapValues { b in
            ["id": b.id, "name": b.name, "output": b.output, "controls": ["gain": b.gain, "mute": b.mute],
             "fx": b.fx.mapValues(insertJSON), "fxOrder": b.fxOrder, "sends": sendsJSON(b.sends)] as [String: Any]
        }
        let autoJSON = automation.mapValues { lane in
            ["on": lane.on,
             "points": lane.points.map { ["id": $0.id, "t": sec($0.t), "v": $0.v, "curve": $0.curve] }] as [String: Any]
        }
        return [
            "rev": rev,
            "project": ["sampleRate": sampleRate, "name": "Nuedeface"],
            "assets": assetsJSON,
            "tracks": trackOrder.compactMap { tracks[$0] }.map(trackJSON),
            "trackOrder": trackOrder,
            "buses": busesJSON, "busOrder": busOrder,
            "automation": autoJSON,
        ]
    }

    func describe() -> [String: Any] {
        func p(_ u: String, _ lo: Double, _ hi: Double, _ d: Double) -> [String: Any] {
            ["unit": u, "min": lo, "max": hi, "default": d, "automatable": true]   // gain/pan/clip-gain/params d'inserts rendus
        }
        return [
            "tree": "adressage par ID stable : track/<id>/… , track/<id>/fx/<insertId>/params/<name> , track/<id>/clips/<clipId>/gain",
            "time": "secondes au bord du protocole (samples en interne)",
            "verbs": [
                "help", "describe", "getState", "import", "analyze", "loudness", "meters", "spectrum", "detectSilence", "export", "undo", "redo",
                "normalize", "match", "duck", "fx.apply", "ab.capture", "ab.recall", "ab.list",
                "project.save", "project.load",
                "set", "track.add", "track.remove", "track.rename", "track.reorder", "track.setOutput",
                "bus.add", "bus.remove", "bus.rename", "bus.reorder", "bus.setOutput",
                "send.add", "send.remove",
                "clip.add", "clip.remove", "clip.move", "clip.trim", "clip.setFade",
                "clip.split", "clip.duplicate", "clip.crossfade",
                "insert.add", "insert.remove", "insert.reorder", "insert.setBypass",
                "automation.enable", "automation.disable",
                "automation.point.add", "automation.point.move", "automation.point.remove",
                "transport.play", "transport.stop", "transport.seek", "subscribe",
            ],
            "automation": ["note": "Param.auto : automation.enable/disable {path} ; point.add {path,t(s),v,curve?} → id ; point.move/remove {path,pointId}. RENDUS : track/<id>/controls/gain & /pan, track/<id>/clips/<clipId>/gain (bakés → offline ET live) ; track/<id>/fx/<i>/params/<name> & bus/master/fx/<i>/params/<name> (ramps par bloc offline, best-effort au playhead en live). Galbe par point (champ 'curve' de point.add/move) : 'linear' (défaut), 'bezier' (smootherstep, S-curve douce et monotone), 'hold' (palier)."],
            "transport": ["note": "ÉPHÉMÈRE, hors document : transport.play {from(s),to(s)?,loop?} · stop · seek {t(s)}. loop=true relance à la fin de la plage.",
                          "telemetry": "event:telemetry {playhead(s), peak(0..1), playing} ~30 Hz — OPT-IN : envoie {cmd:subscribe} pour le recevoir, {cmd:subscribe,on:false} pour couper"],
            "structure": [
                "track.add": ["args": ["name?"], "returns": "id"],
                "clip.add": ["args": ["trackId", "asset", "start(s)", "offset(s)?", "duration(s)?", "fadeIn(s)?", "fadeOut(s)?"], "returns": "id"],
                "clip.move": ["args": ["id", "start(s)"]], "clip.trim": ["args": ["id", "start(s)?", "offset(s)?", "duration(s)?"]],
                "clip.setFade": ["args": ["id", "fadeIn(s)?", "fadeOut(s)?", "shape?(linear|exp|scurve)"]],
                "clip.split": ["args": ["clipId", "at(s)"], "returns": "id (pièce droite)", "note": "coupe à `at` ; audio continu ; gauche garde fadeIn, droite fadeOut"],
                "clip.duplicate": ["args": ["clipId", "start(s)?"], "returns": "id", "note": "copie (défaut : juste après la source)"],
                "clip.crossfade": ["args": ["a (antérieur)", "b (postérieur)", "duration(s)?"], "note": "fondu enchaîné sur leur chevauchement ; b doit déjà chevaucher a"],
                "bus.add": ["args": ["name?"], "returns": "id", "note": "bus de sous-mix ; route vers master par défaut. bus.setOutput {busId, output} le re-route (anti-cycle, doit atteindre master) ; bus.remove re-pointe ses dépendants vers master (master non supprimable). track.setOutput {trackId, output} envoie une piste vers un bus."],
                "send.add": ["args": ["trackId OU busId", "dest (busId)", "level?(lin)", "pre?(bool)"], "returns": "id", "note": "tap parallèle vers un bus aux (s'ajoute à la sortie principale). pré-fader (tap post-inserts, avant gain/pan) ou post-fader. Sends de bus = post-fader seulement, anti-cycle. Niveau/pré : set track/<id>/sends/<sendId>/level|pre."],
                "insert.add": ["args": ["trackId OU busId", "type(eq|reverb|delay|distortion|au)", "subType(si au)"], "returns": "id",
                               "note": "cible une piste (trackId) ou un bus (busId, ex. 'master' pour un limiteur de bus). insert.remove/reorder/setBypass acceptent aussi busId. Params de bus fx : set bus/<id>/fx/<insertId>/params/<name>."],
            ],
            "controls": ["gain": p("lin", 0, 4, 1), "pan": p("lin", -1, 1, 0), "mute": ["type": "bool"], "solo": ["type": "bool"]],
            "inserts": [
                "eq":         ["params": ["gain": p("dB", -24, 24, 0), "freq": p("Hz", 20, 20_000, 1_000)]],
                "reverb":     ["params": ["mix": p("%", 0, 100, 30), "preset": p("idx", 0, 12, 6)]],
                "delay":      ["params": ["time": p("s", 0, 2, 0.25), "feedback": p("%", -100, 100, 30), "mix": p("%", 0, 100, 25)]],
                "distortion": ["params": ["drive": p("dB", -80, 20, -6), "mix": p("%", 0, 100, 40), "preset": p("idx", 0, 21, 0)]],
                "au": ["note": "insert GÉNÉRIQUE : insert.add {trackId, type:'au', subType:'<4cc>'} instancie n'importe quelle Audio Unit effet Apple. Ses params sont auto-décrits PAR INSTANCE dans getState (champ 'schema' de l'insert : id/name/unit/min/max/default) et réglables via set track/<id>/fx/<insertId>/params/<id>. subType ∈ 'catalog' ci-dessous.",
                       "catalog": AU.catalog().map { ["subType": $0.subType, "name": $0.name] }],
                "_note": "chaque insert a aussi bypass(bool) via insert.setBypass ; chaîne ordonnée par fxOrder",
            ],
            "analyze": ["returns": ["lufs", "peakDBFS", "clipping"], "args": ["from(s)?", "to(s)?"], "note": "render offline du mix (fenêtre optionnelle {from,to}), ferme la boucle muter→mesurer"],
            "loudness": ["args": ["from(s)?", "to(s)?"], "returns": "{integrated, momentary, shortTerm, truePeak(dBTP), lra}", "note": "suite EBU R128 : momentary 400 ms / short-term 3 s (max sur le programme), integrated + LRA (programme entier), true-peak ×4 (approx)"],
            "meters": ["returns": "tracks:[{id,lufs,peakDBFS,clipping}]", "note": "mètre par piste (chaque piste rendue isolée, mute/solo ignorés)"],
            "spectrum": ["args": ["from(s)?", "to(s)?"], "returns": "{bands:[{name,loHz,hiHz,db}], centroidHz, peakHz, tiltDb}", "note": "oreille tonale : FFT du mix → énergie par bande (sub/bass/lowMid/mid/highMid/presence/air), centroïde (brillance), tilt (clair+/sombre−), fréquence dominante"],
            "detectSilence": ["args": ["assetId OU clipId OU trackId", "minDb?(=-50)", "minDurMs?(=300)"], "returns": "{regions:[{from(s),to(s)}]}", "note": "régions sous seuil RMS ≥ durée min → l'IA voit où couper (trim des blancs)"],
            "normalize": ["args": ["target(LUFS)"], "note": "ajuste le gain master pour viser `target` LUFS (analyze → facteur correctif, clampé). Mutating, undoable."],
            "match": ["args": ["refPath", "mode(loudness|tone)"], "note": "aligne le mix sur une réf. loudness = même LUFS ; tone = pose un EQ 4 bandes correctif sur le master (différence de spectre long-terme, bornée ±9 dB). Mutating."],
            "duck": ["args": ["source(trackId, ex. voix)", "target(trackId, ex. ambiance)", "threshold?(dB=-35)", "depth?(dB=-12)", "attack?(ms=30)", "release?(ms=250)"], "note": "ducking par AUTOMATION bakée : la cible baisse sous la source. Pas de vrai sidechain (mur API Apple) — lane de gain ré-éditable. Mutating."],
            "fx.apply": ["args": ["preset", "trackId OU busId (OU source+target pour ambience-duck)"], "note": "applique une recette nommée (cf. 'recipes'). S'expanse en primitives undoables. master-podcast normalise à −16 ; ambience-duck appelle duck."],
            "ab": ["note": "ab.capture {slot:A|B} sauve l'état courant ; ab.recall {slot} le restaure (compare audible, REMPLACE l'état — non-undoable) ; ab.list liste les slots."],
            "recipes": Recipes.metas.map { ["id": $0.id, "name": $0.name, "group": $0.group, "target": $0.target, "description": $0.description, "expands": $0.expands] },
            "examples": [
                "Voix téléphone : fx.apply {preset:'telephone', trackId:'t1'} — sinon à la main : EQ bande passante 300–3400 Hz (b0_gain −24 @320, b3_gain −24 @3400, bosse medium) + distortion mix~12.",
                "Voix propre & forte : fx.apply {preset:'voice-radio', trackId:'t1'} puis detectSilence {trackId:'t1'} → clip.trim pour ôter les blancs.",
                "Voix + ambiance : pose l'ambiance (import + clip.add sur t2), puis fx.apply {preset:'ambience-duck', source:'t1', target:'t2'} (ou duck directement).",
                "Mastering podcast : fx.apply {preset:'master-podcast', busId:'master'} (EQ+comp+limiteur+normalize −16). Vérifie avec loudness {} (true-peak < −1 dBTP).",
                "Caler sur une réf : match {refPath:'/abs/ref.wav', mode:'loudness'} pour le niveau, mode:'tone' pour le timbre.",
                "Comparer deux versions : ab.capture {slot:'A'} → modifie → ab.capture {slot:'B'} → ab.recall {slot:'A'} pour réécouter.",
            ],
            "project": ["note": "project.save {path} : si `path` finit en .nuedeface (ou bundle:true) → PAQUET auto-suffisant (dossier { project.json + assets/ copiés, chemins relatifs }, déplaçable) ; sinon JSON plat (chemins absolus). project.load {path} détecte paquet (dossier) vs JSON et résout les assets. undo/redo : redo refait la dernière annulation (toute mutation vide la pile redo)."],
            "export": ["args": ["path", "format(wav|m4a)"]],
        ]
    }
}
