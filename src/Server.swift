// Nuedeface — serveur autoritaire headless (extrait du top-level pour être embarquable).
//
// Un socket Unix, plusieurs clients (le pattern mpv/mpd/redis du concept) :
//   - boucle d'apply SÉRIALISÉE (queue "apply") = source de vérité, last-write-wins par param ;
//   - chaque mutate diffuse un DELTA ATTRIBUÉ à tous les clients (rev monotone) ;
//   - protocole-fil JSON ligne par ligne, machine-first.
//
// `Server.run` bloque (mode --headless) ; `Server.startInBackground` le lance sur un thread
// (mode GUI : la fenêtre est alors un client socket comme un autre, cf. AppHost).

import Foundation
import Darwin

// --- état autoritaire + queue d'apply unique ---
let doc = Document()
let applyQ = DispatchQueue(label: "nuedeface.apply")   // toutes les MUTATIONS passent par là (sérialisées)
// Lectures lourdes (analyze/loudness/meters/spectrum/detectSilence/export ≈ plusieurs secondes de render) : sur
// une queue CONCURRENTE, chacune depuis un clone immuable du doc (cloneForRead). Sans ça, une mesure ou un export
// gelait toutes les mutations (souris ET IA) le temps du render — cf. caches lock-és côté Engine.
let readQ = DispatchQueue(label: "nuedeface.read", attributes: .concurrent)

// --- une connexion client : file d'envoi DÉDIÉE ---
// Le point clé du multi-clients : l'écriture socket (bloquante si le client lit lentement) ne doit JAMAIS
// se faire sur la queue d'apply, sinon un seul client lent gèle les mutations de TOUS. Chaque client a donc
// sa propre queue série d'envoi ; `applyQ` y dépose les octets en async et repart aussitôt. Si le backlog
// d'un client dépasse un plafond, on le déconnecte (shutdown) au lieu de gonfler la RAM ou de le désync en
// silence — il se reconnectera et re-snapshotera.
final class ClientConn {
    let fd: Int32
    let name: String
    private let q: DispatchQueue
    private let lock = NSLock()
    private var pendingBytes = 0
    private var dead = false
    private let maxBacklog = 8 * 1024 * 1024

    init(fd: Int32, name: String) { self.fd = fd; self.name = name; q = DispatchQueue(label: "nuedeface.send.\(name)") }

    func send(_ data: Data) {
        lock.lock()
        if dead { lock.unlock(); return }
        if pendingBytes + data.count > maxBacklog {
            dead = true; lock.unlock()
            shutdown(fd, SHUT_RDWR)   // débloque le read() du clientLoop → il fermera proprement le fd
            return
        }
        pendingBytes += data.count
        lock.unlock()
        q.async { [weak self] in self?.writeAll(data) }
    }

    // write-all : un seul write() peut être partiel (gros getState, signal) → on boucle jusqu'au bout.
    private func writeAll(_ data: Data) {
        var off = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while off < data.count {
                let n = write(fd, base + off, data.count - off)
                if n > 0 { off += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }   // EPIPE/erreur : client parti
            }
        }
        lock.lock(); pendingBytes -= data.count; if off < data.count { dead = true }; lock.unlock()
    }

    func markDead() { lock.lock(); dead = true; lock.unlock() }
}

// --- registre des clients (pour le broadcast) ---
final class Clients {
    private var conns: [Int32: ClientConn] = [:]
    private var subs: Set<Int32> = []                 // abonnés à la télémétrie (opt-in via `subscribe`)
    private var counter = 0
    private let lock = NSLock()
    func add(_ fd: Int32) -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1; let name = "client#\(counter)"; conns[fd] = ClientConn(fd: fd, name: name); return name
    }
    func remove(_ fd: Int32) { lock.lock(); let c = conns[fd]; conns[fd] = nil; subs.remove(fd); lock.unlock(); c?.markDead() }
    func conn(_ fd: Int32) -> ClientConn? { lock.lock(); defer { lock.unlock() }; return conns[fd] }
    func allConns() -> [ClientConn] { lock.lock(); defer { lock.unlock() }; return Array(conns.values) }
    func subscribe(_ fd: Int32, _ on: Bool) { lock.lock(); if on { subs.insert(fd) } else { subs.remove(fd) }; lock.unlock() }
    func subscriberConns() -> [ClientConn] { lock.lock(); defer { lock.unlock() }; return subs.compactMap { conns[$0] } }
}
let clients = Clients()

// moteur de preview live (transport éphémère + télémétrie best-effort, hors document)
let live = LiveEngine()

// slots A/B (P11) : logs sérialisés nommés, en mémoire. Recall = remplace l'état (compare audible).
var abSlots: [String: [String: Any]] = [:]

func encodeLine(_ obj: [String: Any]) -> Data? {
    guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
    data.append(0x0A); return data
}
func sendLine(_ fd: Int32, _ obj: [String: Any]) {
    guard let data = encodeLine(obj) else { return }
    clients.conn(fd)?.send(data)
}
func broadcast(_ obj: [String: Any]) {
    guard let data = encodeLine(obj) else { return }     // sérialisé UNE fois pour tous les clients
    for c in clients.allConns() { c.send(data) }
}

// --- helpers d'analyse/recettes (appelés sur applyQ, comme tout le reste) ---

/// Gain master à poser pour viser `target` LUFS, SANS dépasser `ceilingTP` dBTP (true-peak) : un « normalize -16 »
/// ne doit jamais créer de clipping. Si la correction de loudness pousserait les crêtes au-dessus du plafond, on
/// réduit le gain pour respecter le plafond (le mix est alors limité par les crêtes, pas par la loudness). nil si silence.
func normalizeGain(_ target: Double, ceilingTP: Double = -1.0) -> (newGain: Double, lufs: Double)? {
    let m = Engine.loudnessMetrics(doc)
    guard m.integrated.isFinite else { return nil }
    let cur = doc.buses["master"]?.gain ?? 1.0
    var newGain = cur * pow(10.0, (target - m.integrated) / 20.0)
    if m.truePeak.isFinite {                                   // garde true-peak : TP_après = TP + 20·log10(newGain/cur)
        let predictedTP = m.truePeak + 20.0 * log10(newGain / cur)
        if predictedTP > ceilingTP { newGain *= pow(10.0, (ceilingTP - predictedTP) / 20.0) }
    }
    return (max(0.01, min(4.0, newGain)), m.integrated)
}

/// Résout le buffer L/R d'une cible d'analyse : assetId (fichier entier), clipId (tranche jouée), ou trackId.
/// `doc` est passé explicitement (un clone immuable quand l'appel vient de la queue de lecture concurrente).
func resolveBuffer(_ msg: [String: Any], _ doc: Document) -> (l: [Float], r: [Float])? {
    if let aid = msg["assetId"] as? String, let info = doc.assets[aid] { return Engine.decode48k(info.path) }
    if let cid = msg["clipId"] as? String {
        for tid in doc.trackOrder {
            guard let t = doc.tracks[tid], let cl = t.clips[cid], let info = doc.assets[cl.asset], let src = Engine.decode48k(info.path) else { continue }
            let lo = max(0, cl.offset), hi = min(src.l.count, cl.offset + cl.duration)
            guard lo < hi else { return nil }
            return (Array(src.l[lo..<hi]), Array(src.r[lo..<hi]))
        }
        return nil
    }
    if let tid = msg["trackId"] as? String, let t = doc.tracks[tid] { return Engine.trackBuffer(t, doc) }
    return nil
}

/// Ducking (P9) : enveloppe de gain bakée sur la cible, pilotée par le RMS de la source. Renvoie une erreur ou nil.
func applyDuck(source: String, target: String, msg: [String: Any]) -> String? {
    guard let st = doc.tracks[source] else { return "duck: source inconnue: \(source)" }
    guard doc.tracks[target] != nil else { return "duck: cible inconnue: \(target)" }
    guard let sb = Engine.trackBuffer(st, doc) else { return "duck: source vide" }
    func dd(_ k: String, _ def: Double) -> Double { (msg[k] as? Double) ?? (msg[k] as? NSNumber)?.doubleValue ?? def }
    let env = Engine.duckEnvelope(sb.l, sb.r, thresholdDb: dd("threshold", -35), depthDb: dd("depth", -12),
                                  attackMs: dd("attack", 30), releaseMs: dd("release", 250))
    guard !env.isEmpty else { return "duck: enveloppe vide" }
    let path = "track/\(target)/controls/gain"
    if let err = doc.mutate(["op": "automation.enable", "path": path]) { return err }
    for pt in env { _ = doc.mutate(["op": "automation.point.add", "path": path, "id": doc.freshId("p"), "t": pt.t, "v": pt.v]) }
    return nil
}

/// fx.apply (P6) : expanse une recette en primitives mutate (chaîne FX) + actions serveur (normalize/duck).
func applyRecipe(_ preset: String, msg: [String: Any]) -> String? {
    let target: Recipes.Target
    if preset == "ambience-duck" {
        guard let src = msg["source"] as? String, let tgt = (msg["target"] as? String) ?? (msg["trackId"] as? String) else { return "fx.apply ambience-duck: 'source' et 'target' (trackId) requis" }
        target = .duck(source: src, target: tgt)
    } else if let bid = msg["busId"] as? String { target = .bus(bid) }
    else if let tid = msg["trackId"] as? String { target = .track(tid) }
    else { return "fx.apply: trackId ou busId requis" }
    let (plan, err) = Recipes.plan(preset, doc: doc, target: target)
    if let err = err { return err }
    guard let p = plan else { return "fx.apply: plan vide" }
    if let d = p.duck { return applyDuck(source: d.source, target: d.target, msg: msg) }
    for cmd in p.cmds { if let e = doc.mutate(cmd) { return "fx.apply: \(e)" } }
    if let t = p.normalizeTo, let res = normalizeGain(t) { _ = doc.mutate(["op": "set", "path": "bus/master/controls/gain", "value": res.newGain]) }
    return nil
}

// --- paquet de projet auto-suffisant (.nuedeface) : un dossier { project.json + assets/ } ---
// Le doc reste autoritaire en chemins ABSOLUS (le moteur décode des chemins absolus). Le paquet, lui, stocke
// des chemins RELATIFS et copie les fichiers à côté → projet déplaçable/partageable. La conversion se fait à la
// frontière : à la sauvegarde on copie + réécrit relatif ; au chargement on réécrit relatif → absolu.
func saveBundle(to dir: String) -> String? {
    let fm = FileManager.default
    let assetsDir = (dir as NSString).appendingPathComponent("assets")
    do { try fm.createDirectory(atPath: assetsDir, withIntermediateDirectories: true) }
    catch { return "création du paquet échouée: \(error.localizedDescription)" }
    var data = doc.serialize()
    var assets = data["assets"] as? [String: [String: Any]] ?? [:]
    var usedNames = Set<String>()
    for (id, info0) in assets {
        var info = info0
        guard let src = info["path"] as? String, fm.fileExists(atPath: src) else { continue }  // asset manquant : on garde son chemin tel quel
        var name = (src as NSString).lastPathComponent
        if usedNames.contains(name) { name = "\(id)-\(name)" }                                   // anti-collision de noms
        usedNames.insert(name)
        let dst = (assetsDir as NSString).appendingPathComponent(name)
        try? fm.removeItem(atPath: dst)
        do { try fm.copyItem(atPath: src, toPath: dst) }
        catch { return "copie d'asset échouée (\(name)): \(error.localizedDescription)" }
        info["path"] = "assets/\(name)"                                                          // chemin RELATIF dans le paquet
        assets[id] = info
    }
    data["assets"] = assets
    guard let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]) else { return "sérialisation échouée" }
    let projFile = (dir as NSString).appendingPathComponent("project.json")
    do { try json.write(to: URL(fileURLWithPath: projFile)) } catch { return "écriture échouée: \(error.localizedDescription)" }
    return nil
}

/// Lit project.json d'un paquet et réécrit les chemins d'assets RELATIFS en absolus (résolus contre le paquet).
func loadBundleObject(_ dir: String) -> [String: Any]? {
    let projFile = (dir as NSString).appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: projFile)),
          var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var assets = obj["assets"] as? [String: [String: Any]] ?? [:]
    for (id, info0) in assets {
        var info = info0
        if let p = info["path"] as? String, !(p as NSString).isAbsolutePath {
            info["path"] = (dir as NSString).appendingPathComponent(p); assets[id] = info
        }
    }
    obj["assets"] = assets
    return obj
}

// --- dispatch d'une commande (toujours sur applyQ) ---
func handle(_ msg: [String: Any], from fd: Int32, who: String) {
    let id = msg["id"] as? Int
    let cmd = msg["cmd"] as? String ?? ""
    func reply(_ extra: [String: Any]) {
        var r: [String: Any] = ["ok": true, "rev": doc.rev]; if let id = id { r["id"] = id }
        for (k, v) in extra { r[k] = v }; sendLine(fd, r)
    }
    func fail(_ e: String) {
        var r: [String: Any] = ["ok": false, "error": e]; if let id = id { r["id"] = id }; sendLine(fd, r)
    }
    // sec → samples (le bord protocole parle en secondes, le canonique en samples)
    func samp(_ k: String) -> Int? {
        guard let v = (msg[k] as? Double) ?? (msg[k] as? NSNumber)?.doubleValue else { return nil }
        return Int((v * doc.sampleRate).rounded())
    }

    // verbe structurel → commande canonique + mutate + delta
    func structural() {
        var canon: [String: Any] = ["op": cmd]
        for k in ["trackId", "busId", "asset", "name", "color", "output", "dest", "type", "subType", "path", "curve", "a", "b"] where msg[k] != nil { canon[k] = msg[k] }
        if let order = msg["order"] as? [String] { canon["order"] = order }
        if let b = msg["bypass"] as? Bool { canon["bypass"] = b }
        if let pr = msg["pre"] as? Bool { canon["pre"] = pr }
        if let lv = (msg["level"] as? Double) ?? (msg["level"] as? NSNumber)?.doubleValue { canon["level"] = lv }
        if let v = (msg["v"] as? Double) ?? (msg["v"] as? NSNumber)?.doubleValue { canon["v"] = v }
        for k in ["start", "offset", "duration", "fadeIn", "fadeOut", "t", "at"] { if let v = samp(k) { canon[k] = v } }
        // l'ID d'entité passe par une clé dédiée (jamais "id" = id de requête).
        var newId: String?
        switch cmd {
        case "track.add":  newId = doc.freshId("t")
        case "clip.add":   newId = doc.freshId("c")
            if let sh = msg["shape"] as? String { canon["shape"] = sh }
        case "insert.add": newId = doc.freshId("i")
        case "clip.split", "clip.duplicate":               // clipId = source ; id = nouvelle pièce
            newId = doc.freshId("c")
            if let cid = msg["clipId"] as? String { canon["clipId"] = cid }
        case "clip.remove", "clip.move", "clip.trim", "clip.setFade":
            if let cid = msg["clipId"] as? String { canon["id"] = cid }
            if let sh = msg["shape"] as? String { canon["shape"] = sh }
        case "insert.remove", "insert.setBypass", "insert.reorder":
            if let iid = msg["insertId"] as? String { canon["id"] = iid }
        case "track.remove", "track.rename", "track.reorder", "track.setOutput":
            if let t = msg["trackId"] as? String { canon["id"] = t }
        case "bus.add":
            newId = doc.freshId("b")
        case "bus.remove", "bus.rename", "bus.reorder", "bus.setOutput":
            if let bid = msg["busId"] as? String { canon["id"] = bid }
        case "send.add":
            newId = doc.freshId("s")
        case "send.remove":
            if let sid = msg["sendId"] as? String { canon["id"] = sid }
        case "automation.point.add":
            newId = doc.freshId("p")
        case "automation.point.move", "automation.point.remove":
            if let pid = msg["pointId"] as? String { canon["id"] = pid }
        default: break
        }
        if let nid = newId { canon["id"] = nid }
        if let err = doc.mutate(canon) { return fail(err) }
        reply(newId.map { ["newId": $0] } ?? [:])   // PAS "id" (réservé à l'appariement requête↔réponse)
        var delta = canon; delta["event"] = "delta"; delta["rev"] = doc.rev; delta["who"] = who
        broadcast(delta)
    }

    // Réponse d'une lecture concurrente : on répond avec la rev DU CLONE (l'état mesuré), pas du doc live.
    // Le client corrèle par `id` ; une mesure peut donc renvoyer une rev antérieure à la rev courante si une
    // mutation est passée entre-temps — c'est correct (la mesure reflète l'instant de la requête).
    func readReply(_ rev: Int, _ extra: [String: Any]) {
        var r: [String: Any] = ["ok": true, "rev": rev]; if let id = id { r["id"] = id }
        for (k, v) in extra { r[k] = v }; sendLine(fd, r)
    }
    func readFail(_ e: String) {
        var r: [String: Any] = ["ok": false, "error": e]; if let id = id { r["id"] = id }; sendLine(fd, r)
    }

    switch cmd {
    case "describe", "help": reply(["schema": doc.describe()])   // `help` = alias d'intuition (humain ET LLM)
    case "getState": reply(["state": doc.snapshot()])
    case "analyze":
        let snap = doc.cloneForRead(); let from = samp("from") ?? 0, to = samp("to")
        readQ.async {
            let a = Engine.analyze(snap, from: from, to: to)   // fenêtre optionnelle {from,to} en secondes
            // JSON ne sait pas sérialiser ±inf/NaN (mix silencieux) → on plancher à -120 dB.
            readReply(snap.rev, ["lufs": a.lufs.isFinite ? a.lufs : -120.0,
                                 "peakDBFS": a.peak.isFinite ? a.peak : -120.0, "clipping": a.clipping])
        }
    case "master.envelope":
        // enveloppe de crête du mix complet (rendu offline) → lane master « rendu complet », à la demande
        let snap = doc.cloneForRead()
        let bsec = (msg["bucket"] as? Double) ?? (msg["bucket"] as? NSNumber)?.doubleValue ?? 0.05
        readQ.async {
            let env = Engine.masterEnvelope(snap, bucketSec: bsec)
            readReply(snap.rev, ["bucket": env.bucket, "peaks": env.peaks.map { Double($0) }])
        }
    case "spectrum":
        let snap = doc.cloneForRead(); let from = samp("from") ?? 0, to = samp("to")
        readQ.async {
            let (l, r) = Engine.render(snap, from: from, to: to)   // fenêtre optionnelle
            let sp = Spectrum.analyze(l, r, sr: snap.sampleRate)
            func fin(_ x: Double) -> Double { x.isFinite ? x : -120.0 }
            readReply(snap.rev, ["bands": sp.bands.map { ["name": $0.name, "loHz": $0.lo, "hiHz": $0.hi, "db": fin($0.db)] },
                                 "centroidHz": fin(sp.centroidHz), "peakHz": fin(sp.peakHz), "tiltDb": fin(sp.tiltDb)])
        }
    case "meters":
        let snap = doc.cloneForRead()
        readQ.async {
            let arr = Engine.trackMeters(snap).map { m -> [String: Any] in
                ["id": m.id, "lufs": m.lufs.isFinite ? m.lufs : -120.0,
                 "peakDBFS": m.peak.isFinite ? m.peak : -120.0, "clipping": m.clipping]
            }
            readReply(snap.rev, ["tracks": arr])
        }
    case "loudness":
        // suite R128 : momentary/short-term/true-peak (programme) + integrated/LRA (programme entier).
        let snap = doc.cloneForRead(); let from = samp("from") ?? 0, to = samp("to")
        readQ.async {
            let m = Engine.loudnessMetrics(snap, from: from, to: to)
            func fin(_ x: Double) -> Double { x.isFinite ? x : -120.0 }
            readReply(snap.rev, ["integrated": fin(m.integrated), "momentary": fin(m.momentaryMax),
                                 "shortTerm": fin(m.shortTermMax), "truePeak": fin(m.truePeak), "lra": m.lra.isFinite ? m.lra : 0])
        }
    case "detectSilence":
        // régions de blanc sur une source (asset/clip) ou une piste — « trim les blancs » pour l'IA.
        let snap = doc.cloneForRead()
        let minDb = (msg["minDb"] as? Double) ?? (msg["minDb"] as? NSNumber)?.doubleValue ?? -50
        let minDur = (msg["minDurMs"] as? Double) ?? (msg["minDurMs"] as? NSNumber)?.doubleValue ?? 300
        readQ.async {
            guard let buf = resolveBuffer(msg, snap) else { return readFail("detectSilence: assetId, clipId ou trackId requis") }
            let regions = Engine.detectSilence(buf.l, buf.r, thresholdDb: minDb, minDurSamples: Int(minDur / 1000 * snap.sampleRate))
            readReply(snap.rev, ["regions": regions.map { ["from": Double($0.start) / snap.sampleRate, "to": Double($0.end) / snap.sampleRate] }])
        }
    case "normalize":
        guard let target = (msg["target"] as? Double) ?? (msg["target"] as? NSNumber)?.doubleValue else { return fail("normalize: 'target' (LUFS) requis") }
        guard let res = normalizeGain(target) else { return fail("normalize: mix silencieux") }
        if let err = doc.mutate(["op": "set", "path": "bus/master/controls/gain", "value": res.newGain]) { return fail(err) }
        reply(["lufs": res.lufs.isFinite ? res.lufs : -120, "masterGain": res.newGain, "target": target])
        broadcast(["event": "delta", "op": "set", "rev": doc.rev, "who": who, "path": "bus/master/controls/gain", "value": res.newGain])
        live.updateMix(doc)
    case "match":
        guard let ref = msg["refPath"] as? String else { return fail("match: 'refPath' requis") }
        guard FileManager.default.fileExists(atPath: ref) else { return fail("match: réf introuvable: \(ref)") }
        let mode = (msg["mode"] as? String ?? "loudness").lowercased()
        if mode == "tone" {
            guard let rb = Engine.decode48k(ref) else { return fail("match: décodage réf échoué") }
            let refSp = Spectrum.analyze(rb.l, rb.r, sr: doc.sampleRate)
            let mix = Engine.render(doc); let mixSp = Spectrum.analyze(mix.l, mix.r, sr: doc.sampleRate)
            func band(_ sp: Spectrum.Result, _ n: String) -> Double { sp.bands.first { $0.name == n }?.db ?? -120 }
            func diff(_ n: String) -> Double { max(-9, min(9, band(refSp, n) - band(mixSp, n))) }
            // 4 bandes EQ master correctives (bornées ±9 dB)
            let iid = doc.freshId("i")
            if let err = doc.mutate(["op": "insert.add", "id": iid, "busId": "master", "type": "eq"]) { return fail(err) }
            let fx = "bus/master/fx/\(iid)/params"
            let sets: [(String, Double)] = [
                ("b0_freq", 120), ("b0_gain", diff("bass")),
                ("b1_freq", 600), ("b1_gain", (diff("lowMid") + diff("mid")) / 2),
                ("b2_freq", 3_000), ("b2_gain", diff("highMid")),
                ("b3_freq", 9_000), ("b3_gain", (diff("presence") + diff("air")) / 2),
            ]
            for (k, v) in sets { _ = doc.mutate(["op": "set", "path": "\(fx)/\(k)", "value": v]) }
            reply(["mode": "tone", "insertId": iid, "bands": sets.filter { $0.0.hasSuffix("gain") }.map { ["param": $0.0, "db": $0.1] }])
            broadcast(["event": "delta", "op": "match", "rev": doc.rev, "who": who]); live.updateMix(doc)
        } else {
            guard let rb = Engine.decode48k(ref) else { return fail("match: décodage réf échoué") }
            let refLufs = Engine.lufsIntegrated(rb.l, rb.r, sr: doc.sampleRate)
            guard refLufs.isFinite, let res = normalizeGain(refLufs) else { return fail("match: loudness réf invalide") }
            if let err = doc.mutate(["op": "set", "path": "bus/master/controls/gain", "value": res.newGain]) { return fail(err) }
            reply(["mode": "loudness", "refLufs": refLufs, "masterGain": res.newGain])
            broadcast(["event": "delta", "op": "set", "rev": doc.rev, "who": who, "path": "bus/master/controls/gain", "value": res.newGain]); live.updateMix(doc)
        }
    case "duck":
        guard let src = msg["source"] as? String, let tgt = (msg["target"] as? String) ?? (msg["trackId"] as? String) else { return fail("duck: 'source' et 'target' (trackId) requis") }
        if let err = applyDuck(source: src, target: tgt, msg: msg) { return fail(err) }
        reply(["ducked": tgt, "source": src])
        broadcast(["event": "delta", "op": "duck", "rev": doc.rev, "who": who])   // clients → re-snapshot (lane d'automation)
        live.updateMix(doc)
    case "fx.apply":
        guard let preset = msg["preset"] as? String else { return fail("fx.apply: 'preset' requis") }
        if let err = applyRecipe(preset, msg: msg) { return fail(err) }
        reply(["applied": preset])
        broadcast(["event": "delta", "op": "fx.apply", "preset": preset, "rev": doc.rev, "who": who])   // clients → re-snapshot
        live.updateMix(doc)
    case "ab.capture":
        let slot = (msg["slot"] as? String ?? "A").uppercased()
        abSlots[slot] = doc.serialize()
        reply(["slot": slot, "rev": doc.rev])
    case "ab.recall":
        let slot = (msg["slot"] as? String ?? "A").uppercased()
        guard let snap = abSlots[slot] else { return fail("ab.recall: slot '\(slot)' vide") }
        live.stop()
        if let err = doc.loadProject(snap) { return fail(err) }
        reply(["recalled": slot, "rev": doc.rev])
        broadcast(["event": "delta", "op": "ab.recall", "slot": slot, "rev": doc.rev, "who": who])
    case "ab.list":
        let slots = abSlots.keys.sorted().map { k -> [String: Any] in ["slot": k, "rev": (abSlots[k]?["rev"] as? Int) ?? 0] }
        reply(["slots": slots])
    case "project.save":
        guard let path = msg["path"] as? String else { return fail("project.save: 'path' requis") }
        // paquet auto-suffisant si le chemin finit en .nuedeface (ou bundle:true) ; sinon JSON plat (back-compat).
        if path.hasSuffix(".nuedeface") || (msg["bundle"] as? Bool == true) {
            if let err = saveBundle(to: path) { return fail(err) }
            reply(["wrote": path, "bundle": true])
        } else {
            guard let data = try? JSONSerialization.data(withJSONObject: doc.serialize(), options: [.sortedKeys, .prettyPrinted]) else { return fail("sérialisation échouée") }
            do { try data.write(to: URL(fileURLWithPath: path)); reply(["wrote": path]) }
            catch { fail("écriture échouée: \(error)") }
        }
    case "project.load":
        guard let path = msg["path"] as? String else { return fail("project.load: 'path' requis") }
        // paquet (dossier .nuedeface) ou JSON plat : on détecte, et on résout les assets relatifs si paquet.
        var isDir: ObjCBool = false
        let isBundle = (FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) || path.hasSuffix(".nuedeface")
        let obj: [String: Any]?
        if isBundle {
            obj = loadBundleObject(path)
        } else {
            obj = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        guard let obj else { return fail("lecture/parse échouée: \(path)") }
        live.stop()
        if let err = doc.loadProject(obj) { return fail(err) }
        reply(["loaded": path, "rev": doc.rev])
        broadcast(["event": "delta", "op": "project.load", "rev": doc.rev, "who": who])   // clients → re-snapshot
    case "redo":
        guard doc.redo() else { return fail("rien à refaire") }
        reply([:])
        broadcast(["event": "delta", "op": "redo", "rev": doc.rev, "who": who])
    case "import":
        guard let path = msg["path"] as? String else { return fail("import: 'path' requis") }
        guard FileManager.default.fileExists(atPath: path) else { return fail("fichier introuvable: \(path)") }
        let assetId = doc.importAsset(path: path)
        reply(["assetId": assetId])
        broadcast(["event": "delta", "op": "import", "rev": doc.rev, "who": who, "path": path, "assetId": assetId])
    case "set":
        guard let path = msg["path"] as? String, let value = msg["value"] else { return fail("set: 'path' et 'value' requis") }
        if let err = doc.mutate(["op": "set", "path": path, "value": value]) { return fail(err) }
        reply([:])
        broadcast(["event": "delta", "op": "set", "rev": doc.rev, "who": who, "path": path, "value": value])
        live.updateMix(doc)   // si en lecture : gain/pan/mute/eq suivent en direct
    case "transport.play":
        func dd(_ k: String) -> Double? { (msg[k] as? Double) ?? (msg[k] as? NSNumber)?.doubleValue }
        live.play(doc, from: dd("from") ?? 0, to: dd("to"), loop: msg["loop"] as? Bool ?? false)
        reply(["playing": true])
    case "transport.stop":
        live.stop(); reply(["playing": false])
    case "transport.seek":
        let t = (msg["t"] as? Double) ?? (msg["t"] as? NSNumber)?.doubleValue ?? 0
        live.seek(doc, to: t); reply(["seek": t])
    case "subscribe":
        let on = msg["on"] as? Bool ?? true          // {on:false} pour se désabonner
        clients.subscribe(fd, on)
        reply(["subscribed": on])
    case "export":
        guard let path = msg["path"] as? String else { return fail("export: 'path' requis") }
        let aac = (msg["format"] as? String ?? "wav").lowercased() == "m4a"
        let snap = doc.cloneForRead()                              // render + écriture fichier hors applyQ
        readQ.async {
            let ok = Engine.export(snap, to: URL(fileURLWithPath: path), aac: aac)
            ok ? readReply(snap.rev, ["wrote": path]) : readFail("échec d'export vers \(path)")
        }
    case "undo":
        guard doc.undo() else { return fail("rien à annuler") }
        reply([:])
        broadcast(["event": "delta", "op": "undo", "rev": doc.rev, "who": who])
    case "track.add", "track.remove", "track.rename", "track.reorder", "track.setOutput",
         "bus.add", "bus.remove", "bus.rename", "bus.reorder", "bus.setOutput",
         "send.add", "send.remove",
         "clip.add", "clip.remove", "clip.move", "clip.trim", "clip.setFade",
         "clip.split", "clip.duplicate", "clip.crossfade",
         "insert.add", "insert.remove", "insert.reorder", "insert.setBypass",
         "automation.enable", "automation.disable",
         "automation.point.add", "automation.point.move", "automation.point.remove":
        structural()
    default: fail("commande inconnue: « \(cmd) » — envoie {\"cmd\":\"describe\"} (ou \"help\") pour la liste des verbes et leurs arguments")
    }
}

// --- boucle de lecture par client (JSON ligne par ligne) ---
func clientLoop(_ fd: Int32) {
    let who = clients.add(fd)
    sendLine(fd, ["event": "hello", "who": who, "rev": doc.rev, "hint": "envoie {\"cmd\":\"describe\"}"])
    var acc = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    let maxLine = 16 * 1024 * 1024   // garde-fou : une ligne sans '\n' ne doit pas faire grossir la RAM sans fin
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        acc.append(contentsOf: buf[0..<n])
        if acc.count > maxLine && !acc.contains(0x0A) {
            sendLine(fd, ["ok": false, "error": "ligne trop longue (> \(maxLine) octets) — connexion fermée"])
            break
        }
        while let nl = acc.firstIndex(of: 0x0A) {
            let line = acc.subdata(in: acc.startIndex..<nl)
            acc.removeSubrange(acc.startIndex...nl)
            if line.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                applyQ.async { handle(obj, from: fd, who: who) }
            } else {
                sendLine(fd, ["ok": false, "error": "JSON invalide"])
            }
        }
    }
    close(fd); clients.remove(fd)
}

// --- socket Unix ---

/// Renvoie true si un serveur écoute DÉJÀ sur ce chemin (connexion test réussie). Sert à ne pas
/// arracher (`unlink`) le point d'entrée d'une instance vivante — sinon deux serveurs se marchent dessus.
func socketIsAlive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in _ = path.withCString { strncpy(dst, $0, cap - 1) } }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}

func makeServerSocket(_ path: String) -> Int32 {
    // un fichier socket peut traîner après un arrêt brutal : on ne le supprime QUE s'il est mort.
    if FileManager.default.fileExists(atPath: path) {
        if socketIsAlive(path) {
            FileHandle.standardError.write("nuedeface: une instance écoute déjà sur \(path) — abandon\n".data(using: .utf8)!)
            exit(1)
        }
        unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { perror("socket"); exit(1) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
            _ = path.withCString { strncpy(dst, $0, cap - 1) }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    guard r == 0 else { perror("bind"); exit(1) }
    chmod(path, 0o600)   // socket local mono-utilisateur : pas d'accès aux autres comptes de la machine
    guard listen(fd, 16) == 0 else { perror("listen"); exit(1) }
    return fd
}

enum Server {
    // sources de signaux retenues (sinon désallouées) pour un arrêt propre : on referme le listen,
    // on supprime le fichier socket, puis on quitte — pas de socket fantôme laissé derrière.
    private static var signalSources: [DispatchSourceSignal] = []
    private static func installShutdown(socketPath: String, listenFD: Int32) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                close(listenFD); unlink(socketPath)
                FileHandle.standardError.write("nuedeface: arrêt propre\n".data(using: .utf8)!)
                exit(0)
            }
            src.resume(); signalSources.append(src)
        }
    }

    /// Lance le serveur et BLOQUE sur la boucle d'accept (mode headless).
    static func run(socketPath: String) {
        // toutes les mutations de graphe live passent par applyQ (le serveur les y appelle déjà) ; la tick
        // télémétrie y route loop-replay/auto-stop → le graphe ne change que sur une seule queue.
        live.controlQueue = applyQ
        // télémétrie live (playhead + niveau master) → diffusée best-effort, séparée des deltas document
        live.onTelemetry = { t in
            let byTrack: [String: Double] = t.tracks.mapValues { Double($0) }
            let byBus: [String: Double] = t.buses.mapValues { Double($0) }
            func fin(_ x: Double) -> Double { x.isFinite ? x : -120 }
            var obj: [String: Any] = ["event": "telemetry", "playhead": t.playhead,
                                      "peak": Double(max(t.peakL, t.peakR)),       // compat (niveau master mono)
                                      "peakL": Double(t.peakL), "peakR": Double(t.peakR),
                                      "peakByTrack": byTrack, "peakByBus": byBus,
                                      "playing": t.playing,
                                      "momentary": fin(t.momentary), "shortTerm": fin(t.shortTerm), "truePeak": fin(t.truePeak)]
            if !t.spectrum.isEmpty { obj["spectrum"] = t.spectrum.map { fin(Double($0)) } }
            if !t.gainReduction.isEmpty { obj["gainReduction"] = t.gainReduction.mapValues { Double($0) } }
            guard let data = encodeLine(obj) else { return }
            for c in clients.subscriberConns() { c.send(data) }   // seulement les abonnés (opt-in)
        }
        let server = makeServerSocket(socketPath)
        installShutdown(socketPath: socketPath, listenFD: server)
        FileHandle.standardError.write(
            "nuedeface: écoute sur \(socketPath) (rev \(doc.rev), \(doc.tracks.count) pistes)\n".data(using: .utf8)!)
        while true {
            let c = accept(server, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }   // signal bénin → on reboucle
                usleep(2000)                     // erreur persistante (ex. EMFILE) → on évite de spinner le CPU
                continue
            }
            Thread.detachNewThread { clientLoop(c) }
        }
    }

    /// Lance le serveur sur un thread de fond et REND LA MAIN (mode GUI : la fenêtre tourne
    /// sur la main-loop AppKit et se connecte au socket comme n'importe quel client).
    static func startInBackground(socketPath: String) {
        Thread.detachNewThread { Server.run(socketPath: socketPath) }
    }
}
