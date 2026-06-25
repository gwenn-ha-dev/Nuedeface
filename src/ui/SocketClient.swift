// Nuedeface — le client socket de l'UI (modèle structurel).
//
// L'UI est un CLIENT comme un autre : snapshot via `getState`, deltas attribués, émet set/structurels.
// Réplique observable par SwiftUI. Temps reçus EN SECONDES (le serveur convertit depuis les samples).

import Foundation
import Darwin
import Combine
import SwiftUI   // withAnimation : les deltas distants font GLISSER les contrôles

/// Schéma d'un param d'insert générique « au » (issu de l'AUParameterTree, via getState).
struct InsertParamSpec: Identifiable { let id: String; let name: String; let unit: String; let min: Double; let max: Double; let def: Double }
/// Une AU effet Apple disponible (catalogue exposé par describe) pour le menu +FX.
struct AUOption: Identifiable { let subType: String; let name: String; var id: String { subType } }
struct InsertVM: Identifiable {
    let id: String; var type: String; var bypass: Bool; var params: [String: Double]
    var subType: String? = nil               // "au" : 4cc de l'AU
    var schema: [InsertParamSpec] = []        // "au" : params auto-décrits
}
/// Cible d'une chaîne d'inserts : une piste ou un bus (master). Donne le préfixe de path + l'arg de verbe.
enum FXLoc {
    case track(String), bus(String)
    var pathPrefix: String { switch self { case .track(let id): return "track/\(id)"; case .bus(let id): return "bus/\(id)" } }
    var arg: [String: Any] { switch self { case .track(let id): return ["trackId": id]; case .bus(let id): return ["busId": id] } }
}
struct SendVM: Identifiable { let id: String; var dest: String; var level: Double; var pre: Bool }
/// Un bus (sous-mix / aux) ou le master : même forme qu'une piste côté chaîne FX + un output + des sends.
struct BusVM: Identifiable { let id: String; var name: String; var gain: Double; var mute: Bool; var output: String; var inserts: [InsertVM]; var sends: [SendVM] }
struct ClipVM: Identifiable {
    let id: String; var asset: String
    var start: Double; var offset: Double; var duration: Double
    var fadeIn: Double; var fadeOut: Double; var gain: Double
    var fadeShape: String = "linear"    // galbe des fades : "linear" | "exp" | "scurve"
}
struct TrackVM: Identifiable {
    let id: String
    var name: String
    var gain: Double; var pan: Double; var mute: Bool; var solo: Bool
    var output: String           // bus de destination ("master" par défaut)
    var inserts: [InsertVM]      // ordonnés selon fxOrder
    var sends: [SendVM]          // taps parallèles vers des bus aux
    var clips: [ClipVM]
}
struct AssetVM { var path: String; var duration: Double }
struct AutoPointVM: Identifiable { let id: String; var t: Double; var v: Double; var curve: String }
struct AutoLaneVM { var on: Bool; var points: [AutoPointVM] }
struct Metrics { var lufs: Double; var peak: Double; var clipping: Bool }
struct SpectrumBand: Identifiable { let name: String; let db: Double; var id: String { name } }
struct SpectrumVM { var bands: [SpectrumBand]; var centroidHz: Double; var peakHz: Double; var tiltDb: Double }
/// Suite loudness EBU R128 (à la demande pour integrated/LRA).
struct LoudnessVM { var integrated: Double; var momentary: Double; var shortTerm: Double; var truePeak: Double; var lra: Double }
/// Une recette du cookbook (describe.recipes) pour le menu « baguette ».
struct RecipeVM: Identifiable { let id: String; let name: String; let group: String; let target: String; let description: String; let expands: String }
/// Message éphémère (échec d'une commande, ou « ✓ fait » d'un gros geste) — l'app cesse d'être muette.
struct Toast: Identifiable { let id = UUID(); let message: String; let isError: Bool }
/// Une entrée du feed d'activité : qui a fait quoi, quand. `mine` = ce client (vs IA/script).
struct ActivityEntry: Identifiable { let id = UUID(); let who: String; let op: String; let detail: String; let date: Date; let mine: Bool }

/// Canal courant éditable dans le rack : une piste ou un bus (master = `.bus("master")`). (UI pure.)
enum Channel: Equatable { case track(String); case bus(String) }

/// Les trois zones logiques = trois lentilles sur le même document : WAVES (arranger le temps),
/// MIX (sculpter chaque piste), MASTER (finaliser le rendu). La zone-scène suit la dernière sélection
/// (focus AUTO) ; une épingle la gèle. (UI pure.)
enum Zone: Equatable { case waves, mix, master }

final class SocketClient: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var tracks: [TrackVM] = []
    @Published private(set) var assets: [String: AssetVM] = [:]
    @Published private(set) var automation: [String: AutoLaneVM] = [:]   // path -> lane
    @Published private(set) var auCatalog: [AUOption] = []                // effets AU Apple dispo (describe)
    @Published private(set) var buses: [BusVM] = []                       // tous les bus (master inclus), ordonnés
    var master: BusVM { buses.first { $0.id == "master" } ?? BusVM(id: "master", name: "MASTER", gain: 1, mute: false, output: "master", inserts: [], sends: []) }
    var auxBuses: [BusVM] { buses.filter { $0.id != "master" } }          // bus aux/sous-groupes (hors master)
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var rev = 0
    @Published private(set) var who = ""
    @Published private(set) var lastDelta: String?
    @Published private(set) var metrics: Metrics?
    @Published private(set) var analyzing = false
    @Published private(set) var spectrum: SpectrumVM?          // oreille tonale (à la demande)
    @Published private(set) var spectrumLoading = false
    // nouveaux flux live (élargissement télémétrie) : FFT derrière l'EQ, GR mesurée, loudness live
    @Published private(set) var liveSpectrum: [Float] = []           // bins log (dB) — FFT live derrière la courbe d'EQ
    @Published private(set) var spectrogram: [[Float]] = []          // pile de trames (temps × fréq) pour le spectrogramme
    @Published private(set) var gainReduction: [String: Double] = [:]  // insertId → GR mesurée (dB ≥ 0)
    @Published private(set) var momentary = -120.0
    @Published private(set) var shortTerm = -120.0
    @Published private(set) var truePeak = -120.0
    // loudness pro à la demande (integrated + LRA = programme entier)
    @Published private(set) var loudness: LoudnessVM?
    @Published private(set) var loudnessLoading = false
    @Published private(set) var recipes: [RecipeVM] = []             // cookbook (describe) → menu recettes
    private let spectrogramMax = 240                                  // ~8 s d'historique @30 Hz
    // feedback & conscience (A/B/C)
    @Published var toast: Toast?                                      // échec/succès éphémère
    @Published private(set) var activity: [ActivityEntry] = []        // feed attribué (qui·quoi·quand) — la signature « je regarde l'IA »
    @Published private(set) var projectPath: String?                 // fichier projet courant (nil = jamais enregistré)
    @Published private(set) var dirty = false                        // modifications non enregistrées
    var projectName: String { projectPath.map { ($0 as NSString).lastPathComponent } ?? "sans titre" }
    /// nom de projet sans extension de format (.nuedeface / .nuedeface.json) — pour proposer un nom d'export.
    var cleanProjectName: String {
        projectName.replacingOccurrences(of: ".nuedeface.json", with: "").replacingOccurrences(of: ".nuedeface", with: "")
    }

    /// affiche un message éphémère (auto-effacé). Sûr depuis n'importe quel thread.
    func showToast(_ message: String, isError: Bool) {
        let t = Toast(message: message, isError: isError)
        DispatchQueue.main.async {
            self.toast = t
            DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 4 : 2.2)) {
                if self.toast?.id == t.id { self.toast = nil }
            }
        }
    }
    // transport / télémétrie (éphémère, hors document)
    @Published private(set) var playing = false
    @Published private(set) var playhead = 0.0
    @Published private(set) var liveLevel = 0.0
    @Published private(set) var trackLevels: [String: Double] = [:]   // VU live par piste (crête 0..1)
    @Published private(set) var busLevels: [String: Double] = [:]     // VU live par bus aux (crête 0..1)
    @Published private(set) var masterL = 0.0
    @Published private(set) var masterR = 0.0
    @Published private(set) var masterWave: [Float] = []   // enveloppe crête du mix, DESSINÉE EN LIVE (lane master read-only)
    let masterWaveBucket = 0.05                             // 50 ms par bucket de temps
    @Published private(set) var masterOffline: [Float] = []   // enveloppe crête du RENDU COMPLET offline (à la demande, en fond)
    @Published private(set) var masterOfflineBucket = 0.05
    @Published private(set) var masterRendering = false
    // sélection d'édition (UI pure : le clip courant, prérequis trim/fade/split — Slice 1)
    @Published var selectedClipId: String? = nil
    // canal courant (UI pure) : piste OU master — pilote le rack d'effets du bas (Slice 3)
    @Published var selectedChannel: Channel = .bus("master")
    /// id de la piste sélectionnée (nil si master) — surbrillance timeline.
    var selectedTrackId: String? { if case .track(let id) = selectedChannel { return id }; return nil }
    // FOCUS (UI pure) : la zone-scène déduite de la dernière sélection ; épingle = scène gelée.
    @Published var focusZone: Zone = .mix
    @Published var pinnedZone: Zone? = nil
    /// Zone réellement en scène : l'épingle prime, sinon le focus auto.
    var stageZone: Zone { pinnedZone ?? focusZone }
    func focus(_ z: Zone) { focusZone = z }
    func togglePin(_ z: Zone) { pinnedZone = (pinnedZone == z) ? nil : z }
    @Published var autoSel: [String: String] = [:]   // automation affichée/éditée par piste (chemin relatif ; défaut volume)

    private var fd: Int32 = -1
    private var nextId = 0
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private let lock = NSLock()
    private var analyzeGen = 0
    // coalescing des `set` continus (fader/knob/nœud EQ) : on applique localement à chaque frame (réactif)
    // mais on n'envoie au serveur qu'à ~30 Hz, dernière valeur par path → fin du flood sans perdre l'audio live.
    private var pendingSets: [String: Any] = [:]
    private var setFlushScheduled = false

    // --- connexion (retry tant que le serveur embarqué n'écoute pas encore) ---
    func connect(path: String) { Thread.detachNewThread { [weak self] in self?.connectBlocking(path) } }

    private func connectBlocking(_ path: String) {
        let f = socket(AF_UNIX, SOCK_STREAM, 0)
        guard f >= 0 else { return }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in _ = path.withCString { strncpy(dst, $0, cap - 1) } }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        var tries = 0
        while true {
            let r = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(f, $0, len) } }
            if r == 0 { break }
            tries += 1; if tries > 200 { close(f); return }; usleep(50_000)
        }
        fd = f
        DispatchQueue.main.async { self.connected = true }
        readLoop()
    }

    // --- envoi ---
    private func rawSend(_ obj: [String: Any]) {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }
    func call(_ cmd: String, _ args: [String: Any] = [:], _ done: (([String: Any]) -> Void)? = nil) {
        // ORDRE : toute commande ≠ set vide d'abord les set en attente → le serveur a les dernières valeurs
        // avant un export/analyze/normalize/save (sinon on mesurerait/exporterait un état périmé).
        if cmd != "set" { flushSets() }
        lock.lock(); nextId += 1; let id = nextId; if let d = done { pending[id] = d }; lock.unlock()
        var o = args; o["cmd"] = cmd; o["id"] = id
        rawSend(o)
    }

    // --- verbes UI ---
    /// Réglage d'un paramètre : applique LOCALEMENT tout de suite (réactif + audio live), mais COALESCE
    /// l'envoi serveur à ~30 Hz par path → un drag de fader n'inonde plus le socket ni le feed.
    func set(_ path: String, _ value: Any) {
        applyLocal(path: path, value: value)          // optimiste, chaque frame
        pendingSets[path] = value                     // dernière valeur par path
        if !setFlushScheduled {
            setFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { [weak self] in self?.flushSets() }
        }
    }
    /// Envoie au serveur les set coalescés (dernière valeur par path).
    private func flushSets() {
        setFlushScheduled = false
        guard !pendingSets.isEmpty else { return }
        let batch = pendingSets; pendingSets = [:]
        for (path, value) in batch {
            lock.lock(); nextId += 1; let id = nextId; lock.unlock()
            rawSend(["cmd": "set", "path": path, "value": value, "id": id])
        }
    }
    func setBypass(_ loc: FXLoc, insertId: String, _ bypass: Bool) {
        var a = loc.arg; a["insertId"] = insertId; a["bypass"] = bypass; call("insert.setBypass", a)
    }
    func addInsert(_ loc: FXLoc, type: String, subType: String? = nil) {
        var a = loc.arg; a["type"] = type; if let st = subType { a["subType"] = st }
        call("insert.add", a)
    }
    func removeInsert(_ loc: FXLoc, insertId: String) { var a = loc.arg; a["insertId"] = insertId; call("insert.remove", a) }
    func reorderInsert(_ loc: FXLoc, order: [String]) { var a = loc.arg; a["order"] = order; call("insert.reorder", a) }

    // automation (volume = track/<id>/controls/gain)
    func gainAutoPath(_ trackId: String) -> String { "track/\(trackId)/controls/gain" }
    // automation : quel chemin (vol/pan/gain-de-clip/param d'insert) est affiché par piste + ses bornes d'affichage
    func autoRel(_ trackId: String) -> String { autoSel[trackId] ?? "controls/gain" }
    func autoFullPath(_ trackId: String) -> String { "track/\(trackId)/\(autoRel(trackId))" }
    func setAutoSel(_ trackId: String, _ rel: String) { autoSel[trackId] = rel }

    /// Titre court d'un insert (même vocabulaire que la carte du rack).
    func insertTitle(_ ins: InsertVM) -> String {
        if ins.type == "au" { return (auCatalog.first { $0.subType == ins.subType }?.name ?? ins.subType ?? "AU") }
        return ["eq": "EQ", "reverb": "Reverb", "delay": "Delay", "distortion": "Drive"][ins.type] ?? ins.type
    }
    /// Paramètres AUTOMATISABLES d'un insert + leurs bornes d'affichage (mêmes plages que les knobs du rack).
    struct AutoParamSpec: Identifiable { let id: String; let name: String; let lo: Double; let hi: Double; let unit: Double }
    func autoParamSpecs(_ ins: InsertVM) -> [AutoParamSpec] {
        switch ins.type {
        case "au": return ins.schema.map { AutoParamSpec(id: $0.id, name: $0.name, lo: $0.min, hi: max($0.min + 0.0001, $0.max), unit: $0.min) }
        case "eq": return (0..<4).map { AutoParamSpec(id: "b\($0)_gain", name: "gain \($0)", lo: -24, hi: 24, unit: 0) }
        case "reverb": return [AutoParamSpec(id: "mix", name: "mix", lo: 0, hi: 100, unit: 0)]
        case "delay": return [AutoParamSpec(id: "time", name: "time", lo: 0, hi: 2, unit: 0),
                              AutoParamSpec(id: "feedback", name: "fb", lo: -100, hi: 100, unit: 0),
                              AutoParamSpec(id: "mix", name: "mix", lo: 0, hi: 100, unit: 0)]
        case "distortion": return [AutoParamSpec(id: "drive", name: "drive", lo: -80, hi: 20, unit: 0),
                                   AutoParamSpec(id: "mix", name: "mix", lo: 0, hi: 100, unit: 0)]
        default: return []
        }
    }
    private func insertFor(_ trackId: String, _ insertId: String) -> InsertVM? {
        tracks.first { $0.id == trackId }?.inserts.first { $0.id == insertId }
    }
    /// Bornes d'affichage de la lane selon le chemin relatif sélectionné (résout via le schéma de l'insert).
    func autoRange(_ trackId: String, _ rel: String) -> (lo: Double, hi: Double, unit: Double) {
        if rel == "controls/pan" { return (-1, 1, 0) }
        let c = rel.split(separator: "/").map(String.init)
        if c.count == 3, c[0] == "clips", c[2] == "gain" { return (0, 2, 1) }              // gain de clip
        if c.count == 4, c[0] == "fx", c[2] == "params",
           let ins = insertFor(trackId, c[1]), let sp = autoParamSpecs(ins).first(where: { $0.id == c[3] }) {
            return (sp.lo, sp.hi, sp.unit)
        }
        return (0, 2, 1)                                                                    // volume (défaut)
    }
    /// Libellé court de la lane sélectionnée (pour l'entête et le sélecteur).
    func autoName(_ trackId: String, _ rel: String) -> String {
        if rel == "controls/pan" { return "pan" }
        if rel == "controls/gain" { return "volume" }
        let c = rel.split(separator: "/").map(String.init)
        if c.count == 3, c[0] == "clips", c[2] == "gain" { return "gain clip" }
        if c.count == 4, c[0] == "fx", c[2] == "params", let ins = insertFor(trackId, c[1]) {
            let pn = autoParamSpecs(ins).first(where: { $0.id == c[3] })?.name ?? c[3]
            return "\(insertTitle(ins))·\(pn)"
        }
        return rel
    }
    func enableAuto(_ path: String, _ on: Bool) { call(on ? "automation.enable" : "automation.disable", ["path": path]) }
    func addPoint(_ path: String, t: Double, v: Double) { call("automation.point.add", ["path": path, "t": max(0, t), "v": v]) }
    func removePoint(_ path: String, pointId: String) { call("automation.point.remove", ["path": path, "pointId": pointId]) }
    func commitPoint(_ path: String, pointId: String, t: Double, v: Double) {
        call("automation.point.move", ["path": path, "pointId": pointId, "t": max(0, t), "v": v])
    }
    /// change le galbe du segment partant d'un point : "linear" | "bezier" (S-curve douce) | "hold" (palier).
    func setPointCurve(_ path: String, pointId: String, curve: String) {
        call("automation.point.move", ["path": path, "pointId": pointId, "curve": curve])
    }
    /// déplacement optimiste d'un point pendant le drag (sans round-trip).
    func previewPoint(_ path: String, pointId: String, t: Double, v: Double) {
        DispatchQueue.main.async {
            guard var lane = self.automation[path], let j = lane.points.firstIndex(where: { $0.id == pointId }) else { return }
            lane.points[j].t = max(0, t); lane.points[j].v = v
            lane.points.sort { $0.t < $1.t }
            self.automation[path] = lane
        }
    }
    /// importe un fichier puis pose un clip sur la piste (le geste « poser de l'audio »), à `start` secondes.
    func importToTrack(_ path: String, trackId: String, start: Double = 0) {
        call("import", ["path": path]) { [weak self] reply in
            guard let self, let aId = reply["assetId"] as? String else { return }
            self.call("clip.add", ["trackId": trackId, "asset": aId, "start": max(0, start)])
        }
    }
    func addTrack() { call("track.add", ["name": "Piste"]) }
    func removeTrack(_ id: String) { call("track.remove", ["trackId": id]); if selectedTrackId == id { selectMaster() } }
    func renameTrack(_ id: String, _ name: String) { let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }; call("track.rename", ["trackId": id, "name": n]) }
    func undo() { call("undo") }
    func redo() { call("redo") }
    /// mesure du spectre (oreille tonale) — à la demande, comme le LUFS (rend le mix offline).
    func fetchSpectrum() {
        DispatchQueue.main.async { self.spectrumLoading = true }
        call("spectrum") { [weak self] r in
            guard let self else { return }
            let bands = (r["bands"] as? [[String: Any]] ?? []).map {
                SpectrumBand(name: $0["name"] as? String ?? "?", db: dbl($0["db"]) ?? -120)
            }
            DispatchQueue.main.async {
                self.spectrum = SpectrumVM(bands: bands, centroidHz: dbl(r["centroidHz"]) ?? 0,
                                           peakHz: dbl(r["peakHz"]) ?? 0, tiltDb: dbl(r["tiltDb"]) ?? 0)
                self.spectrumLoading = false
            }
        }
    }
    /// rendu COMPLET du mix master en enveloppe (offline, à la demande) → dessiné en fond de la lane master.
    func fetchMasterEnvelope() {
        DispatchQueue.main.async { self.masterRendering = true }
        call("master.envelope", ["bucket": masterWaveBucket]) { [weak self] r in
            guard let self else { return }
            let peaks = (r["peaks"] as? [Any] ?? []).compactMap { dbl($0).map { Float($0) } }
            let b = dbl(r["bucket"]) ?? 0.05
            DispatchQueue.main.async { self.masterOffline = peaks; self.masterOfflineBucket = b; self.masterRendering = false }
        }
    }
    func save(path: String) {
        call("project.save", ["path": path]) { [weak self] r in
            guard (r["ok"] as? Bool) == true else { return }
            DispatchQueue.main.async { self?.projectPath = path; self?.dirty = false }
            self?.showToast("Projet enregistré", isError: false)
        }
    }
    func load(path: String) {
        call("project.load", ["path": path]) { [weak self] r in
            guard (r["ok"] as? Bool) == true else { return }
            DispatchQueue.main.async { self?.projectPath = path; self?.dirty = false }
            self?.showToast("Projet chargé", isError: false)
        }
    }
    var canSave: Bool { projectPath != nil }

    /// Rend et écrit le mix vers un fichier (wav | m4a). Toast de progression → résultat.
    func export(path: String, format: String) {
        showToast("Export en cours…", isError: false)
        call("export", ["path": path, "format": format]) { [weak self] r in
            if (r["ok"] as? Bool) == true { self?.showToast("Exporté : \((path as NSString).lastPathComponent)", isError: false) }
            else { self?.showToast("Échec de l'export : \((r["error"] as? String) ?? "?")", isError: true) }
        }
    }

    /// sélection d'édition (clic = sélectionne, clic dans le vide = désélectionne). UI pure, pas de socket.
    /// Sélectionner un clip met WAVES en scène (focus auto : on manipule le temps).
    func selectClip(_ id: String?) {
        selectedClipId = id
        if let id, let (i, _) = locate(id) { selectedChannel = .track(tracks[i].id); focusZone = .waves }
    }
    /// canal courant (clic sur un mini-fader / une piste / une entête). UI pure. → focus MIX.
    func selectTrack(_ id: String?) { if let id { selectedChannel = .track(id); focusZone = .mix } }
    func selectBus(_ id: String) { selectedChannel = .bus(id); focusZone = (id == "master") ? .master : .mix }
    func selectMaster() { selectedChannel = .bus("master"); focusZone = .master }

    // --- routing (Slice 4) : bus, output, sends ---
    func addBus(name: String = "Bus") { call("bus.add", ["name": name]) }
    func removeBus(_ id: String) { guard id != "master" else { return }; call("bus.remove", ["busId": id]); if selectedChannel == .bus(id) { selectMaster() } }
    func renameBus(_ id: String, _ name: String) { let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty, id != "master" else { return }; call("bus.rename", ["busId": id, "name": n]) }
    func reorderBuses(_ order: [String]) { call("bus.reorder", ["order": order]) }
    /// route une piste/un bus vers un bus de destination (anti-cycle validé côté moteur).
    func setOutput(_ loc: FXLoc, dest: String) {
        switch loc {
        case .track(let id): call("track.setOutput", ["trackId": id, "output": dest])
        case .bus(let id):   call("bus.setOutput", ["busId": id, "output": dest])
        }
    }
    /// sends (taps parallèles vers un bus aux) : ajout/retrait + niveau (via set) + pré/post.
    func addSend(_ loc: FXLoc, dest: String, pre: Bool = false) { var a = loc.arg; a["dest"] = dest; a["pre"] = pre; call("send.add", a) }
    func removeSend(_ loc: FXLoc, sendId: String) { var a = loc.arg; a["sendId"] = sendId; call("send.remove", a) }
    func setSendPre(_ loc: FXLoc, sendId: String, _ pre: Bool) { set("\(loc.pathPrefix)/sends/\(sendId)/pre", pre) }

    // boucle (UI) : une zone [loopStart, loopEnd] + un interrupteur. Pilote transport.play {from,to,loop}.
    @Published private(set) var loopOn = false
    @Published private(set) var loopStart = 0.0
    @Published private(set) var loopEnd = 0.0
    var hasLoopRegion: Bool { loopEnd > loopStart }

    // transport (éphémère)
    /// Émet la lecture selon les réglages courants (boucle de zone, boucle globale, ou lecture simple).
    private func issuePlay() {
        if loopOn && hasLoopRegion { call("transport.play", ["from": loopStart, "to": loopEnd, "loop": true]) }
        else if loopOn { call("transport.play", ["from": max(0, playhead), "loop": true]) }
        else { call("transport.play", ["from": max(0, playhead)]) }
    }
    func togglePlay() { if playing { call("transport.stop") } else { issuePlay() } }
    /// active/coupe la boucle ; si on joue, relance avec les nouveaux paramètres (sans interruption perçue).
    func toggleLoop() { loopOn.toggle(); if playing { issuePlay() } }
    /// définit la zone de boucle (glisser sur la règle) et l'active ; relance si en lecture.
    func setLoopRange(_ a: Double, _ b: Double) {
        loopStart = max(0, min(a, b)); loopEnd = max(a, b); loopOn = true
        if playing { issuePlay() }
    }
    func clearLoop() { loopOn = false; loopStart = 0; loopEnd = 0; if playing { issuePlay() } }
    func seek(to t: Double) { call("transport.seek", ["t": max(0, t)]) }
    func returnToStart() { call("transport.seek", ["t": 0]) }

    /// déplacement de clip : optimiste en continu pendant le drag, commit à la fin.
    func previewClipStart(trackId: String, clipId: String, _ start: Double) {
        DispatchQueue.main.async {
            guard let i = self.tracks.firstIndex(where: { $0.id == trackId }),
                  let j = self.tracks[i].clips.firstIndex(where: { $0.id == clipId }) else { return }
            self.tracks[i].clips[j].start = max(0, start)
        }
    }
    func commitClipMove(clipId: String, start: Double) {
        call("clip.move", ["clipId": clipId, "start": max(0, start)])
    }
    /// déplacement inter-pistes (Slice 2 B) : la piste cible part dans `trackId`.
    func commitClipMoveToTrack(clipId: String, start: Double, trackId: String) {
        call("clip.move", ["clipId": clipId, "start": max(0, start), "trackId": trackId])
    }
    /// fondu enchaîné sur le chevauchement de deux clips d'une même piste (a = antérieur, b = postérieur).
    func crossfade(a: String, b: String) { call("clip.crossfade", ["a": a, "b": b]) }
    /// réordonne les pistes (permutation complète de l'ordre).
    func reorderTracks(_ order: [String]) { call("track.reorder", ["order": order]) }

    // --- édition de clip au geste (Slice 2) : preview optimiste continu + commit en fin de geste ---
    private func locate(_ clipId: String) -> (Int, Int)? {
        for (i, t) in tracks.enumerated() { if let j = t.clips.firstIndex(where: { $0.id == clipId }) { return (i, j) } }
        return nil
    }
    /// applique localement (sans round-trip) les champs d'un clip pendant un drag de poignée.
    func previewClipEdit(clipId: String, start: Double? = nil, offset: Double? = nil,
                         duration: Double? = nil, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        DispatchQueue.main.async {
            guard let (i, j) = self.locate(clipId) else { return }
            if let v = start { self.tracks[i].clips[j].start = max(0, v) }
            if let v = offset { self.tracks[i].clips[j].offset = max(0, v) }
            if let v = duration { self.tracks[i].clips[j].duration = max(0, v) }
            if let v = fadeIn { self.tracks[i].clips[j].fadeIn = max(0, v) }
            if let v = fadeOut { self.tracks[i].clips[j].fadeOut = max(0, v) }
        }
    }
    func commitTrim(clipId: String, start: Double? = nil, offset: Double? = nil, duration: Double? = nil) {
        var a: [String: Any] = ["clipId": clipId]
        if let v = start { a["start"] = max(0, v) }
        if let v = offset { a["offset"] = max(0, v) }
        if let v = duration { a["duration"] = max(0, v) }
        call("clip.trim", a)
    }
    func commitFade(clipId: String, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        var a: [String: Any] = ["clipId": clipId]
        if let v = fadeIn { a["fadeIn"] = max(0, v) }
        if let v = fadeOut { a["fadeOut"] = max(0, v) }
        call("clip.setFade", a)
    }
    /// galbe des fades du clip (in ET out) : "linear" | "exp" | "scurve".
    func setFadeShape(clipId: String, _ shape: String) {
        DispatchQueue.main.async {                                   // optimiste : reflète tout de suite le galbe
            guard let (i, j) = self.locate(clipId) else { return }
            self.tracks[i].clips[j].fadeShape = shape
        }
        call("clip.setFade", ["clipId": clipId, "shape": shape])
    }
    func splitClip(clipId: String, at t: Double) { call("clip.split", ["clipId": clipId, "at": max(0, t)]) }
    func duplicateClip(clipId: String, start: Double? = nil) {
        var a: [String: Any] = ["clipId": clipId]; if let s = start { a["start"] = max(0, s) }
        call("clip.duplicate", a)
    }
    func removeClip(clipId: String) { call("clip.remove", ["clipId": clipId]); if selectedClipId == clipId { selectedClipId = nil } }

    /// `analyze` rend tout le mix offline → débounce ; revient toujours à un état stable.
    func scheduleAnalyze() {
        lock.lock(); analyzeGen += 1; let gen = analyzeGen; lock.unlock()
        DispatchQueue.main.async { self.analyzing = true }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let still = self.analyzeGen == gen; self.lock.unlock()
            guard still else { return }
            self.call("analyze") { [weak self] reply in
                guard let self else { return }
                self.lock.lock(); let current = self.analyzeGen == gen; self.lock.unlock()
                DispatchQueue.main.async {
                    if let l = reply["lufs"] as? Double, let p = reply["peakDBFS"] as? Double, let c = reply["clipping"] as? Bool {
                        self.metrics = Metrics(lufs: l, peak: p, clipping: c)
                    }
                    if current { self.analyzing = false }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                self.lock.lock(); let current = self.analyzeGen == gen; self.lock.unlock()
                if current { self.analyzing = false }
            }
        }
    }

    // --- réception ---
    private func readLoop() {
        var acc = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
            while let nl = acc.firstIndex(of: 0x0A) {
                let line = acc.subdata(in: acc.startIndex..<nl)
                acc.removeSubrange(acc.startIndex...nl)
                if line.isEmpty { continue }
                if let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { dispatch(m) }
            }
        }
        DispatchQueue.main.async { self.connected = false }
    }

    private func dispatch(_ m: [String: Any]) {
        if let ev = m["event"] as? String {
            switch ev {
            case "hello":
                if let w = m["who"] as? String { DispatchQueue.main.async { self.who = w } }
                refresh(); fetchDescribe(); call("subscribe")   // opt-in à la télémétrie (playhead/mètre)
                return
            case "delta": applyDeltaEvent(m); return
            case "telemetry":
                let head = dbl(m["playhead"]) ?? 0, pk = dbl(m["peak"]) ?? 0
                let pL = dbl(m["peakL"]) ?? pk, pR = dbl(m["peakR"]) ?? pk
                let pl = m["playing"] as? Bool ?? false
                var levels: [String: Double] = [:]
                for (k, v) in (m["peakByTrack"] as? [String: Any] ?? [:]) { if let d = dbl(v) { levels[k] = d } }
                var bLevels: [String: Double] = [:]
                for (k, v) in (m["peakByBus"] as? [String: Any] ?? [:]) { if let d = dbl(v) { bLevels[k] = d } }
                let spec = (m["spectrum"] as? [Any])?.compactMap { dbl($0).map { Float($0) } } ?? []
                var gr: [String: Double] = [:]
                for (k, v) in (m["gainReduction"] as? [String: Any] ?? [:]) { if let d = dbl(v) { gr[k] = d } }
                let mom = dbl(m["momentary"]) ?? -120, sht = dbl(m["shortTerm"]) ?? -120, tpk = dbl(m["truePeak"]) ?? -120
                DispatchQueue.main.async {
                    self.playhead = head; self.liveLevel = pk; self.playing = pl
                    self.masterL = pL; self.masterR = pR; self.trackLevels = levels; self.busLevels = bLevels
                    if !spec.isEmpty {
                        self.liveSpectrum = spec
                        self.spectrogram.append(spec); if self.spectrogram.count > self.spectrogramMax { self.spectrogram.removeFirst(self.spectrogram.count - self.spectrogramMax) }
                    }
                    self.gainReduction = gr
                    self.momentary = mom; self.shortTerm = sht; self.truePeak = tpk
                    if !pl { self.liveSpectrum = [] }   // arrêt → on éteint le spectre live
                    if pl {                                  // « le mix accumulé » : on remplit le bucket de temps courant
                        let idx = Int(max(0, head) / self.masterWaveBucket)
                        if self.masterWave.count <= idx {
                            self.masterWave.append(contentsOf: repeatElement(0, count: idx - self.masterWave.count + 1))
                        }
                        self.masterWave[idx] = Float(max(pL, pR))   // overwrite → un replay rafraîchit la zone
                    }
                }
                return
            default: break
            }
        }
        if let id = m["id"] as? Int {
            if (m["ok"] as? Bool) == false { showToast(m["error"] as? String ?? "échec de la commande", isError: true) }
            lock.lock(); let d = pending[id]; pending[id] = nil; lock.unlock()
            d?(m)
        }
    }

    private func refresh() {
        call("getState") { [weak self] r in if let s = r["state"] as? [String: Any] { self?.applySnapshot(s) } }
    }

    /// Catalogue des AU effets Apple (pour le menu +FX), lu dans le schéma auto-décrit.
    private func fetchDescribe() {
        call("describe") { [weak self] r in
            guard let self, let schema = r["schema"] as? [String: Any] else { return }
            let opts: [AUOption] = (((schema["inserts"] as? [String: Any])?["au"] as? [String: Any])?["catalog"] as? [[String: Any]] ?? []).compactMap { e in
                guard let st = e["subType"] as? String, let nm = e["name"] as? String else { return nil }
                return AUOption(subType: st, name: nm)
            }
            let recs: [RecipeVM] = (schema["recipes"] as? [[String: Any]] ?? []).compactMap { e in
                guard let id = e["id"] as? String, let nm = e["name"] as? String else { return nil }
                return RecipeVM(id: id, name: nm, group: e["group"] as? String ?? "", target: e["target"] as? String ?? "",
                                description: e["description"] as? String ?? "", expands: e["expands"] as? String ?? "")
            }
            DispatchQueue.main.async { self.auCatalog = opts; self.recipes = recs }
        }
    }

    // --- recettes / mastering / A-B (les nouveaux verbes « wow ») ---
    /// applique une recette nommée sur le canal courant (ou source→target pour ambience-duck).
    func applyRecipe(_ id: String, source: String? = nil) {
        var a: [String: Any] = ["preset": id]
        if id == "ambience-duck" {
            guard let src = source, let tgt = selectedTrackId else { return }
            a["source"] = src; a["target"] = tgt
        } else {
            switch selectedChannel { case .track(let t): a["trackId"] = t; case .bus(let b): a["busId"] = b }
        }
        let name = recipes.first { $0.id == id }?.name ?? id
        call("fx.apply", a) { [weak self] r in if (r["ok"] as? Bool) == true { self?.showToast("Recette « \(name) » appliquée", isError: false) } }
    }
    /// ducking direct (UI rack) : la cible (canal courant) baisse sous la source.
    func duck(source: String, target: String, threshold: Double = -35, depth: Double = -12) {
        call("duck", ["source": source, "target": target, "threshold": threshold, "depth": depth]) { [weak self] r in
            if (r["ok"] as? Bool) == true { self?.showToast("Ducking posé", isError: false) }
        }
    }
    func normalizeMaster(to target: Double = -16) {
        call("normalize", ["target": target]) { [weak self] r in
            if (r["ok"] as? Bool) == true { self?.showToast(String(format: "Normalisé → %.0f LUFS", target), isError: false) }
        }
    }
    func matchRef(path: String, mode: String) {
        call("match", ["refPath": path, "mode": mode]) { [weak self] r in
            if (r["ok"] as? Bool) == true { self?.showToast(mode == "tone" ? "Timbre calé sur la réf" : "Niveau calé sur la réf", isError: false) }
        }
    }
    func abCapture(_ slot: String) { call("ab.capture", ["slot": slot]) }
    func abRecall(_ slot: String) { call("ab.recall", ["slot": slot]) }
    /// suite loudness R128 à la demande (integrated + LRA = programme entier).
    func fetchLoudness() {
        DispatchQueue.main.async { self.loudnessLoading = true }
        call("loudness") { [weak self] r in
            guard let self else { return }
            DispatchQueue.main.async {
                self.loudness = LoudnessVM(integrated: dbl(r["integrated"]) ?? -120, momentary: dbl(r["momentary"]) ?? -120,
                                           shortTerm: dbl(r["shortTerm"]) ?? -120, truePeak: dbl(r["truePeak"]) ?? -120, lra: dbl(r["lra"]) ?? 0)
                self.loudnessLoading = false
            }
        }
    }

    private func applyDeltaEvent(_ m: [String: Any]) {
        if let r = m["rev"] as? Int { DispatchQueue.main.async { self.rev = r } }
        DispatchQueue.main.async { if !self.masterOffline.isEmpty { self.masterOffline = [] } }   // rendu offline périmé après une édition
        let who = m["who"] as? String ?? "?"
        let op = m["op"] as? String ?? ""
        let detail: String
        if op == "set", let path = m["path"] as? String, let value = m["value"] {
            detail = "\(path) = \(fmtVal(value))"
            DispatchQueue.main.async { self.lastDelta = "\(who) · \(path)" }
            applyLocal(path: path, value: value, animated: who != self.who)   // distant (IA/autre client) → glisse
        } else {
            // structurel (clip.add, track.add, insert.*, import, undo…) → re-snapshot, c'est simple et correct
            detail = [op, m["preset"] as? String, m["id"] as? String].compactMap { $0 }.joined(separator: " ")
            DispatchQueue.main.async { self.lastDelta = "\(who) · \(op)" }
            refresh()
        }
        // feed d'activité attribué (la signature « je regarde l'IA bosser ») + conscience de sauvegarde
        let entry = ActivityEntry(who: who, op: op, detail: detail, date: Date(), mine: who == self.who)
        func ctrl(_ s: String) -> Substring { s.prefix { $0 != "=" } }   // path avant le " = " (identifie le contrôle)
        DispatchQueue.main.async {
            // un même contrôle qui bouge en continu (drag) → on MET À JOUR la dernière entrée au lieu d'empiler
            if op == "set", let last = self.activity.last, last.op == "set", last.who == who,
               ctrl(last.detail) == ctrl(detail) {
                self.activity[self.activity.count - 1] = entry
            } else {
                self.activity.append(entry)
            }
            if self.activity.count > 120 { self.activity.removeFirst(self.activity.count - 120) }
            if op != "project.load" { self.dirty = true }
        }
        // NB : plus d'auto-analyse LUFS à chaque edit (mesure coûteuse) — c'est désormais à la demande (bouton master).
    }

    // --- snapshot ---
    /// Inserts d'une piste OU d'un bus (même forme JSON : fx + fxOrder + schema "au").
    private static func parseInserts(_ fxMap: [String: [String: Any]], _ order: [String]) -> [InsertVM] {
        order.compactMap { iid in
            guard let ins = fxMap[iid] else { return nil }
            var pm: [String: Double] = [:]
            for (k, v) in (ins["params"] as? [String: Any] ?? [:]) { if let d = dbl(v) { pm[k] = d } }
            let schema: [InsertParamSpec] = (ins["schema"] as? [[String: Any]] ?? []).map { sp in
                InsertParamSpec(id: sp["id"] as? String ?? "", name: sp["name"] as? String ?? "",
                                unit: sp["unit"] as? String ?? "", min: dbl(sp["min"]) ?? 0,
                                max: dbl(sp["max"]) ?? 1, def: dbl(sp["default"]) ?? 0)
            }
            return InsertVM(id: iid, type: ins["type"] as? String ?? "eq",
                            bypass: ins["bypass"] as? Bool ?? false, params: pm,
                            subType: ins["subType"] as? String, schema: schema)
        }
    }

    private static func parseSends(_ v: Any?) -> [SendVM] {
        (v as? [[String: Any]] ?? []).map {
            SendVM(id: $0["id"] as? String ?? "?", dest: $0["dest"] as? String ?? "master",
                   level: dbl($0["level"]) ?? 1, pre: $0["pre"] as? Bool ?? false)
        }
    }

    private func applySnapshot(_ s: [String: Any]) {
        var newTracks: [TrackVM] = []
        for t in (s["tracks"] as? [[String: Any]] ?? []) {
            let ctrl = t["controls"] as? [String: Any] ?? [:]
            let fxMap = t["fx"] as? [String: [String: Any]] ?? [:]
            let order = t["fxOrder"] as? [String] ?? Array(fxMap.keys)
            let inserts = Self.parseInserts(fxMap, order)
            let clips: [ClipVM] = (t["clips"] as? [[String: Any]] ?? []).map { c in
                ClipVM(id: c["id"] as? String ?? "?", asset: c["asset"] as? String ?? "",
                       start: dbl(c["start"]) ?? 0, offset: dbl(c["offset"]) ?? 0, duration: dbl(c["duration"]) ?? 0,
                       fadeIn: dbl(c["fadeIn"]) ?? 0, fadeOut: dbl(c["fadeOut"]) ?? 0, gain: dbl(c["gain"]) ?? 1,
                       fadeShape: c["fadeShape"] as? String ?? "linear")
            }
            newTracks.append(TrackVM(id: t["id"] as? String ?? "?", name: t["name"] as? String ?? "?",
                                     gain: dbl(ctrl["gain"]) ?? 1, pan: dbl(ctrl["pan"]) ?? 0,
                                     mute: ctrl["mute"] as? Bool ?? false, solo: ctrl["solo"] as? Bool ?? false,
                                     output: t["output"] as? String ?? "master",
                                     inserts: inserts, sends: Self.parseSends(t["sends"]), clips: clips))
        }
        var assetMap: [String: AssetVM] = [:]
        for (id, a) in (s["assets"] as? [String: [String: Any]] ?? [:]) {
            assetMap[id] = AssetVM(path: a["path"] as? String ?? "", duration: dbl(a["duration"]) ?? 0)
        }
        var autoMap: [String: AutoLaneVM] = [:]
        for (path, lr) in (s["automation"] as? [String: [String: Any]] ?? [:]) {
            let pts = (lr["points"] as? [[String: Any]] ?? []).map {
                AutoPointVM(id: $0["id"] as? String ?? "?", t: dbl($0["t"]) ?? 0, v: dbl($0["v"]) ?? 0, curve: $0["curve"] as? String ?? "linear")
            }
            autoMap[path] = AutoLaneVM(on: lr["on"] as? Bool ?? false, points: pts)
        }
        var busList: [BusVM] = []
        let busDict = s["buses"] as? [String: [String: Any]] ?? [:]
        let busOrderArr = s["busOrder"] as? [String] ?? Array(busDict.keys)
        for bid in busOrderArr {
            guard let b = busDict[bid] else { continue }
            let ctrl = b["controls"] as? [String: Any] ?? [:]
            let fxMap = b["fx"] as? [String: [String: Any]] ?? [:]
            let order = b["fxOrder"] as? [String] ?? Array(fxMap.keys)
            busList.append(BusVM(id: bid, name: b["name"] as? String ?? bid,
                                 gain: dbl(ctrl["gain"]) ?? 1, mute: ctrl["mute"] as? Bool ?? false,
                                 output: b["output"] as? String ?? "master",
                                 inserts: Self.parseInserts(fxMap, order), sends: Self.parseSends(b["sends"])))
        }
        let sr = dbl((s["project"] as? [String: Any])?["sampleRate"]) ?? 48_000
        DispatchQueue.main.async {
            self.tracks = newTracks; self.assets = assetMap; self.sampleRate = sr; self.automation = autoMap
            self.buses = busList
            // canal courant : si la cible sélectionnée a disparu, repli sur le master
            if case .track(let id) = self.selectedChannel, !newTracks.contains(where: { $0.id == id }) { self.selectedChannel = .bus("master") }
            if case .bus(let id) = self.selectedChannel, !busList.contains(where: { $0.id == id }) { self.selectedChannel = .bus("master") }
            // LUFS = à la demande (pas d'analyse auto).
        }
    }

    // --- application optimiste d'un set scalaire (émission + écho delta) ---
    /// Applique un `set` à la réplique. `animated` = la valeur GLISSE jusqu'à sa cible (mutation distante :
    /// l'IA ou un autre client pousse → le fader/knob se déplace sous nos yeux). Mes propres gestes (drag,
    /// saisie, console) sont `animated:false` → réaction instantanée, sans latence perçue.
    private func applyLocal(path: String, value: Any, animated: Bool = false) {
        let c = path.split(separator: "/").map(String.init)
        // exécute la mutation, éventuellement enveloppée d'une animation (la géométrie des contrôles suit la valeur).
        func run(_ mutate: @escaping () -> Void) {
            DispatchQueue.main.async {
                if animated { withAnimation(.easeOut(duration: 0.28)) { mutate() } } else { mutate() }
            }
        }
        if c.count >= 3, c[0] == "bus" {                          // bus (master inclus) : gain/mute + params + niveau de send
            let bid = c[1]; let p = Array(c.dropFirst(2))
            run {
                guard let bi = self.buses.firstIndex(where: { $0.id == bid }) else { return }
                if p == ["controls", "gain"], let d = dbl(value) { self.buses[bi].gain = d }
                else if p == ["controls", "mute"], let b = value as? Bool { self.buses[bi].mute = b }
                else if p.count == 4, p[0] == "fx", p[2] == "params",
                        let j = self.buses[bi].inserts.firstIndex(where: { $0.id == p[1] }), let d = dbl(value) {
                    self.buses[bi].inserts[j].params[p[3]] = d
                } else if p.count == 3, p[0] == "sends", p[2] == "level",
                          let j = self.buses[bi].sends.firstIndex(where: { $0.id == p[1] }), let d = dbl(value) {
                    self.buses[bi].sends[j].level = d
                } else if p.count == 3, p[0] == "sends", p[2] == "pre",
                          let j = self.buses[bi].sends.firstIndex(where: { $0.id == p[1] }), let b = value as? Bool {
                    self.buses[bi].sends[j].pre = b
                }
            }
            return
        }
        guard c.count >= 3, c[0] == "track" else { return }
        let tid = c[1]; let p = Array(c.dropFirst(2))
        run {
            guard let i = self.tracks.firstIndex(where: { $0.id == tid }) else { return }
            if p == ["controls", "gain"], let d = dbl(value) { self.tracks[i].gain = d }
            else if p == ["controls", "pan"], let d = dbl(value) { self.tracks[i].pan = d }
            else if p == ["controls", "mute"], let b = value as? Bool { self.tracks[i].mute = b }
            else if p == ["controls", "solo"], let b = value as? Bool { self.tracks[i].solo = b }
            else if p.count == 4, p[0] == "fx", p[2] == "params",
                    let j = self.tracks[i].inserts.firstIndex(where: { $0.id == p[1] }), let d = dbl(value) {
                self.tracks[i].inserts[j].params[p[3]] = d
            } else if p.count == 3, p[0] == "clips", p[2] == "gain",
                      let j = self.tracks[i].clips.firstIndex(where: { $0.id == p[1] }), let d = dbl(value) {
                self.tracks[i].clips[j].gain = d
            } else if p.count == 3, p[0] == "sends", p[2] == "level",
                      let j = self.tracks[i].sends.firstIndex(where: { $0.id == p[1] }), let d = dbl(value) {
                self.tracks[i].sends[j].level = d
            } else if p.count == 3, p[0] == "sends", p[2] == "pre",
                      let j = self.tracks[i].sends.firstIndex(where: { $0.id == p[1] }), let b = value as? Bool {
                self.tracks[i].sends[j].pre = b
            }
        }
    }
}

private func dbl(_ v: Any?) -> Double? { (v as? Double) ?? (v as? NSNumber)?.doubleValue }
/// Format court d'une valeur de delta `set` pour le feed d'activité.
private func fmtVal(_ v: Any) -> String {
    if let b = v as? Bool { return b ? "on" : "off" }
    if let d = dbl(v) { return abs(d) >= 100 ? String(format: "%.0f", d) : String(format: "%.2f", d) }
    return "\(v)"
}
