// Nuedeface — suite de conformité PROTOCOLE (client socket réel, zéro dépendance, swiftc only).
//
// Contrairement à tests/main.swift (qui exerce les fonctions DSP pures), ce test lance le VRAI
// serveur headless (`./nuedeface --headless <sock>`) et le pilote comme n'importe quel client :
// il envoie du JSON ligne-par-ligne et asserte chaque réponse. C'est la couche que les tests DSP
// ne touchent pas — dispatch `handle()`, canonisation secondes→samples, deltas multi-clients,
// chemins d'erreur explicites ({ok:false}). Sort en code ≠ 0 au premier échec → exploitable en CI.
//
//   swiftc -O tests/protocol.swift -o /tmp/proto && /tmp/proto ./nuedeface
//
// argv[1] (optionnel) = chemin du binaire serveur (défaut ./nuedeface). Le test crée son propre
// socket temporaire et un WAV jetable (pour import/normalize/export), puis arrête le serveur.

import Foundation
import Darwin
import AVFoundation

// ----------------------------------------------------------------------------- assertions
var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "  ok   " : "  FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !cond { failures += 1 }
}
func fatal(_ msg: String) -> Never {
    FileHandle.standardError.write("protocol: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

// ----------------------------------------------------------------------------- client socket
/// Une connexion cliente : write ligne-JSON, read ligne-JSON bufferisé avec timeout (poll).
final class Conn {
    let fd: Int32
    private var acc = Data()
    init(path: String, timeoutSec: Double = 5) {
        // retry : le serveur met un instant à bind() après le spawn.
        let deadline = Date().addingTimeInterval(timeoutSec)
        var f: Int32 = -1
        while Date() < deadline {
            f = socket(AF_UNIX, SOCK_STREAM, 0)
            if f < 0 { usleep(20_000); continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let cap = MemoryLayout.size(ofValue: addr.sun_path)
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in _ = path.withCString { strncpy(dst, $0, cap - 1) } }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(f, $0, len) == 0 }
            }
            if ok { fd = f; return }
            close(f); usleep(20_000)
        }
        fatal("connexion au socket \(path) impossible (serveur démarré ?)")
    }

    func send(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { fatal("encodage JSON") }
        data.append(0x0A)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < data.count {
                let n = write(fd, base + off, data.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    /// Lit la prochaine ligne JSON (objet), ou nil si timeout/EOF.
    func nextLine(timeoutSec: Double = 3) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeoutSec)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = acc.firstIndex(of: 0x0A) {
                let line = acc.subdata(in: acc.startIndex..<nl)
                acc.removeSubrange(acc.startIndex...nl)
                if line.isEmpty { continue }
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            let remain = deadline.timeIntervalSinceNow
            if remain <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, Int32(remain * 1000))
            if pr <= 0 { return nil }                       // timeout ou erreur
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }                         // EOF
            acc.append(contentsOf: buf[0..<n])
        }
    }

    /// Envoie une commande avec un `id` et renvoie la RÉPONSE appariée (saute hello/delta/telemetry).
    func request(_ obj: [String: Any], id: Int, timeoutSec: Double = 5) -> [String: Any] {
        var o = obj; o["id"] = id
        send(o)
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            guard let m = nextLine(timeoutSec: deadline.timeIntervalSinceNow) else { break }
            if (m["id"] as? Int) == id { return m }         // réponse appariée
            // sinon : event (hello/delta/telemetry) d'avant — on continue
        }
        fatal("pas de réponse pour id \(id) (cmd \(obj["cmd"] ?? "?"))")
    }

    /// Attend un event `delta` correspondant (op donné), en sautant le reste. nil si timeout.
    func waitDelta(op: String, timeoutSec: Double = 5) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            guard let m = nextLine(timeoutSec: deadline.timeIntervalSinceNow) else { return nil }
            if (m["event"] as? String) == "delta", (m["op"] as? String) == op { return m }
        }
        return nil
    }

    func close_() { close(fd) }
}

// id de requête monotone partagé
var reqSeq = 0
func nextId() -> Int { reqSeq += 1; return reqSeq }

// ----------------------------------------------------------------------------- helpers d'assertion haut niveau
extension Conn {
    @discardableResult
    func ok(_ obj: [String: Any], _ label: String) -> [String: Any] {
        let r = request(obj, id: nextId())
        check(label, (r["ok"] as? Bool) == true, "réponse: \(r)")
        return r
    }
    func fail(_ obj: [String: Any], _ label: String) {
        let r = request(obj, id: nextId())
        let isFail = (r["ok"] as? Bool) == false && (r["error"] is String)
        check(label, isFail, "attendu {ok:false,error}, reçu: \(r)")
    }
}

// ----------------------------------------------------------------------------- génère un WAV jetable
func makeTestWav(_ path: String, seconds: Double = 0.5) {
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    let frames = AVAudioFrameCount(44_100 * seconds)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { fatal("alloc WAV") }
    buf.frameLength = frames
    for i in 0..<Int(frames) {
        let v = Float(0.4 * sin(2 * Double.pi * 440 * Double(i) / 44_100))
        buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v
    }
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                   AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    guard let f = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false),
          (try? f.write(from: buf)) != nil else { fatal("écriture WAV") }
}

// ----------------------------------------------------------------------------- lancement du serveur
let serverBin = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./nuedeface"
let binURL = URL(fileURLWithPath: serverBin).standardizedFileURL
guard FileManager.default.isExecutableFile(atPath: binURL.path) else {
    fatal("binaire serveur introuvable: \(binURL.path) — lance ./build.sh d'abord")
}
let tmp = NSTemporaryDirectory()
let sock = (tmp as NSString).appendingPathComponent("nuedeface-proto-\(getpid()).sock")
let wav = (tmp as NSString).appendingPathComponent("nuedeface-proto-\(getpid()).wav")
let longWav = (tmp as NSString).appendingPathComponent("nuedeface-proto-long-\(getpid()).wav")
let outWav = (tmp as NSString).appendingPathComponent("nuedeface-proto-out-\(getpid()).wav")
let proj = (tmp as NSString).appendingPathComponent("nuedeface-proto-\(getpid()).json")
try? FileManager.default.removeItem(atPath: sock)
makeTestWav(wav)
makeTestWav(longWav, seconds: 30)        // mix long → un render dure assez pour observer qu'il NE bloque PAS les mutations

let server = Process()
server.executableURL = binURL
server.arguments = ["--headless", sock]
server.standardError = FileHandle.nullDevice
do { try server.run() } catch { fatal("spawn serveur: \(error)") }

func teardown() {
    server.terminate()                                        // SIGTERM → arrêt propre (unlink du socket)
    server.waitUntilExit()
    for p in [sock, wav, longWav, outWav, proj] { try? FileManager.default.removeItem(atPath: p) }
}

// ============================================================================= LES TESTS
print("• handshake & découverte")
let a = Conn(path: sock)
// hello est poussé spontanément à la connexion
let hello = a.nextLine(timeoutSec: 3)
check("hello à la connexion", (hello?["event"] as? String) == "hello" && hello?["who"] is String,
      "reçu: \(hello ?? [:])")

let desc = a.ok(["cmd": "describe"], "describe → ok")
if let schema = desc["schema"] as? [String: Any], let verbs = schema["verbs"] as? [String] {
    check("describe expose les verbes", verbs.contains("import") && verbs.contains("clip.add") && verbs.contains("normalize"),
          "\(verbs.count) verbes")
} else { check("describe expose les verbes", false, "pas de schema.verbs") }

let st0 = a.ok(["cmd": "getState"], "getState → ok")
let state0 = st0["state"] as? [String: Any]
check("getState a tracks + buses", state0?["tracks"] is [Any] && state0?["buses"] is [String: Any])

print("• chemins d'erreur explicites (la promesse {ok:false})")
a.fail(["cmd": "nexistepas"], "commande inconnue → ok:false")
a.fail(["cmd": "set", "path": "track/zzz/controls/gain", "value": 0.5], "set sur path inconnu → ok:false")
a.fail(["cmd": "normalize"], "normalize sans target → ok:false")
a.fail(["cmd": "import", "path": "/nexiste/pas.wav"], "import fichier absent → ok:false")
a.fail(["cmd": "clip.add", "trackId": "t1"], "clip.add sans asset → ok:false")

print("• mutation structurelle + rev monotone + newId")
let rev0 = (st0["rev"] as? Int) ?? -1
let tAdd = a.ok(["cmd": "track.add", "name": "Voix test"], "track.add → ok")
// l'ID d'entité passe par `newId` ; `id` dans la réponse n'est QUE l'echo de l'id de requête (corrélation).
let newTrack = tAdd["newId"] as? String
check("track.add renvoie newId", newTrack != nil, "newId=\(newTrack ?? "nil")")
check("rev a augmenté", (tAdd["rev"] as? Int ?? -1) > rev0, "rev \(rev0) → \(tAdd["rev"] ?? "?")")

let setR = a.ok(["cmd": "set", "path": "track/t1/controls/gain", "value": 0.5], "set gain → ok")
let revAfterSet = setR["rev"] as? Int ?? -1

print("• undo / redo")
let undoR = a.ok(["cmd": "undo"], "undo → ok")
check("undo fait reculer rev", (undoR["rev"] as? Int ?? -1) != revAfterSet)
a.ok(["cmd": "redo"], "redo → ok")
a.send(["cmd": "undo"]); _ = a.waitDelta(op: "undo", timeoutSec: 1)   // revenir à un état propre (drainé)

print("• bus & anti-cycle")
let bAdd = a.ok(["cmd": "bus.add", "name": "Reverb aux"], "bus.add → ok")
let busId = bAdd["newId"] as? String ?? ""
a.ok(["cmd": "track.setOutput", "trackId": "t1", "output": busId], "track.setOutput vers le bus → ok")
// un send de bus qui reboucle doit être refusé (anti-cycle)
a.fail(["cmd": "bus.setOutput", "busId": busId, "output": busId], "bus.setOutput sur soi-même → ok:false")

print("• clip : import → add → split → duplicate")
let imp = a.ok(["cmd": "import", "path": wav], "import WAV → ok")
let assetId = imp["assetId"] as? String ?? ""
check("import renvoie assetId", !assetId.isEmpty)
let cAdd = a.ok(["cmd": "clip.add", "trackId": "t1", "asset": assetId, "start": 0], "clip.add → ok")
let clipId = cAdd["newId"] as? String ?? ""
check("clip.add renvoie newId", !clipId.isEmpty)
let split = a.ok(["cmd": "clip.split", "clipId": clipId, "at": 0.2], "clip.split à 0.2s → ok")
check("split renvoie la pièce droite", split["newId"] is String)
a.fail(["cmd": "clip.split", "clipId": clipId, "at": 999], "split hors clip → ok:false")
a.ok(["cmd": "clip.duplicate", "clipId": clipId], "clip.duplicate → ok")

print("• mesure & boucle muter→mesurer")
let an = a.ok(["cmd": "analyze"], "analyze → ok")
check("analyze renvoie lufs/peak/clipping", an["lufs"] is Double && an["peakDBFS"] is Double && an["clipping"] is Bool,
      "lufs=\(an["lufs"] ?? "?")")
let norm = a.ok(["cmd": "normalize", "target": -16], "normalize -16 → ok")
check("normalize renvoie masterGain", norm["masterGain"] is Double)
a.ok(["cmd": "loudness"], "loudness → ok")
a.ok(["cmd": "detectSilence", "assetId": assetId], "detectSilence → ok")

print("• automation")
a.ok(["cmd": "automation.enable", "path": "track/t1/controls/gain"], "automation.enable → ok")
let p1 = a.ok(["cmd": "automation.point.add", "path": "track/t1/controls/gain", "t": 0, "v": 1.0], "point.add → ok")
let pid = p1["newId"] as? String ?? ""
check("point.add renvoie newId", !pid.isEmpty)
// changer le galbe d'un point (linear → bezier) via point.move : le getState doit refléter curve:"bezier"
a.ok(["cmd": "automation.point.move", "path": "track/t1/controls/gain", "pointId": pid, "curve": "bezier"], "point.move curve:bezier → ok")
let stAuto = a.ok(["cmd": "getState"], "getState (vérif courbe)")
let autoLanes = (stAuto["state"] as? [String: Any])?["automation"] as? [String: Any]
let lane = autoLanes?["track/t1/controls/gain"] as? [String: Any]
let curve = (lane?["points"] as? [[String: Any]])?.first(where: { $0["id"] as? String == pid })?["curve"] as? String
check("le galbe bezier est persisté dans le modèle", curve == "bezier", "curve=\(curve ?? "nil")")

print("• projet : save → load roundtrip")
a.ok(["cmd": "project.save", "path": proj], "project.save → ok")
a.ok(["cmd": "project.load", "path": proj], "project.load → ok")

print("• export audio")
let exp = a.ok(["cmd": "export", "path": outWav, "format": "wav"], "export WAV → ok")
check("export a écrit le fichier", FileManager.default.fileExists(atPath: (exp["wrote"] as? String) ?? outWav))

print("• lecture lourde ⇏ blocage des mutations (le gain de la queue de lecture)")
// on monte un mix LONG (30 s) puis on tire une lecture lourde (analyze) ET, juste après, une mutation (set).
// Si les lectures partageaient la queue d'apply (ancien comportement), la mutation ferait la queue DERRIÈRE le
// render → sa réponse arriverait APRÈS celle d'analyze. Avec la queue de lecture concurrente, la mutation
// répond tout de suite, pendant que le render tourne encore. On asserte donc l'ORDRE des réponses.
let impL = a.ok(["cmd": "import", "path": longWav], "import WAV long → ok")
let assetL = impL["assetId"] as? String ?? ""
a.ok(["cmd": "clip.add", "trackId": "t1", "asset": assetL, "start": 0], "clip.add du mix long → ok")
let idHeavy = nextId(), idMut = nextId()
a.send(["cmd": "analyze", "id": idHeavy])                      // lecture lourde (render ~30 s offline)
a.send(["cmd": "set", "path": "track/t1/controls/gain", "value": 0.7, "id": idMut])   // mutation triviale
var firstResponder: Int? = nil
let probeDeadline = Date().addingTimeInterval(20)
while Date() < probeDeadline, firstResponder == nil {
    if let m = a.nextLine(timeoutSec: probeDeadline.timeIntervalSinceNow),
       let mid = m["id"] as? Int, mid == idHeavy || mid == idMut { firstResponder = mid }
}
check("la mutation répond AVANT la lecture lourde (pas de blocage de queue)", firstResponder == idMut,
      firstResponder == nil ? "aucune réponse (timeout)"
        : firstResponder == idHeavy ? "analyze a répondu en premier → mutation bloquée derrière le render" : "")
// on draine la réponse restante (l'autre id) avant de continuer
if firstResponder != nil { _ = a.request(["cmd": "getState"], id: nextId()) }

print("• deltas multi-clients (attribués)")
let b = Conn(path: sock)
_ = b.nextLine(timeoutSec: 2)                                  // son propre hello
// une mutation émise par A doit parvenir à B sous forme de delta attribué
a.send(["cmd": "set", "path": "track/t1/controls/pan", "value": -0.5, "id": nextId()])
let delta = b.waitDelta(op: "set", timeoutSec: 4)
check("B reçoit le delta de la mutation de A", delta != nil)
check("le delta est attribué (champ who)", (delta?["who"] as? String) != nil, "who=\(delta?["who"] ?? "nil")")
check("le delta porte une rev", delta?["rev"] is Int)
b.close_()
a.close_()

// ============================================================================= verdict
teardown()
print(failures == 0 ? "\n✅ conformité protocole : tous les tests passent" : "\n❌ \(failures) test(s) protocole en échec")
exit(failures == 0 ? 0 : 1)
