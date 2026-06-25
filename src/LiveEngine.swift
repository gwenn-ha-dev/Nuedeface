// Nuedeface — moteur de PREVIEW LIVE (persistant, temps réel) — distinct du render offline.
//
// Le concept impose deux classes d'état : le DOCUMENT (versionné, fiable) et le TRANSPORT/TÉLÉMÉTRIE
// (éphémère, best-effort, jetable). Ici on tient le second : un AVAudioEngine qui joue à travers la
// sortie audio, piloté par transport.play/stop/seek, et qui crache playhead + niveau master throttlés.
//
// Périmètre v1 : play depuis un instant, stop, seek, mises à jour LIVE de gain/pan/mute/eq pendant la
// lecture. Déféré : reconcile structurel pendant la lecture (ajout/déplacement de clip → au prochain play),
// boucle. Le graphe est (re)construit depuis le document à chaque play (le reconcile fin est prouvé à part).

import Foundation
import AVFoundation

/// Niveaux live (jetables, hors document) : playhead, crêtes master L/R, crête par piste,
/// + spectre FFT (derrière l'EQ), GR mesurée par insert dynamique, loudness momentary/short-term/true-peak.
struct LiveTelemetry {
    let playhead: Double; let peakL: Float; let peakR: Float
    let tracks: [String: Float]; let buses: [String: Float]; let playing: Bool
    var spectrum: [Float] = []                 // bins log-espacés (dB), pour le FFT derrière la courbe d'EQ
    var gainReduction: [String: Float] = [:]   // insertId → atténuation mesurée pré/post (dB ≥ 0)
    var momentary: Double = -120               // R128 live (fenêtre récente ~3 s)
    var shortTerm: Double = -120
    var truePeak: Double = -120
}

final class LiveEngine {
    static let fmt = Engine.fmt        // même format canonique que le render offline (pas de duplication)
    let sr = Engine.sr

    private let engine = AVAudioEngine()
    private var attached: [AVAudioNode] = []
    private struct TrackNodes { let id: String; let mix: AVAudioMixerNode; let players: [AVAudioPlayerNode]; let inserts: [(id: String, node: AVAudioUnit, type: String)] }
    private var trackNodes: [TrackNodes] = []
    private var busMixers: [String: AVAudioMixerNode] = [:]                        // entrée de chaque bus (gain/mute)
    private var busInserts: [(bus: String, id: String, node: AVAudioUnit, type: String)] = []  // inserts de bus (MAJ live)
    private var sendGains: [(track: String?, bus: String?, sendId: String, node: AVAudioMixerNode)] = []  // niveaux de sends (MAJ live)
    private var autoParams: [(node: AVAudioUnit, type: String, name: String, path: String)] = []  // params d'inserts automatisés (sous lock)
    private var autoPanNodes: [(mix: AVAudioMixerNode, path: String)] = []         // pan automatisé → node.pan par tick (sous lock)
    private var autoLanes: [String: Document.Lane] = [:]                           // snapshot IMMUABLE des lanes au build (sous lock)
    private var currentDoc: Document?                                              // touché UNIQUEMENT sur controlQueue (jamais sur telemetryQ)

    private let lock = NSLock()
    private(set) var playing = false
    private var ending = false                       // garde : fin de lecture déjà dispatchée sur la control queue
    private var startFrom = 0.0
    private var startUptimeNs: UInt64 = 0
    private var duration = 0.0
    private var stopAt: Double?
    private var loopOn = false
    private var loopStart = 0.0
    private var meterPeakL: Float = 0
    private var meterPeakR: Float = 0
    private var trackPeaks: [String: Float] = [:]   // crête live par piste (tap sur son mix node)
    private var busPeaks: [String: Float] = [:]     // crête live par bus aux (tap sur son mixer)

    // ring 3 s du master (L/R) → FFT live + loudness live (momentary/short-term/true-peak)
    private static let ringCap = 144_000
    private var ringL = [Float](repeating: 0, count: ringCap)
    private var ringR = [Float](repeating: 0, count: ringCap)
    private var ringW = 0, ringN = 0
    // GR mesurée : RMS post-node par nœud (clé = identité) + chaîne (insertId, pré, post) des inserts dynamiques
    private var nodeRMS: [ObjectIdentifier: Float] = [:]
    private var grChain: [(insertId: String, pre: ObjectIdentifier, post: ObjectIdentifier)] = []
    private var grTapNodes: [AVAudioNode] = []
    private var tappedIds = Set<ObjectIdentifier>()
    private var loudnessTick = 0

    private var lastMom = -120.0, lastShort = -120.0, lastTP = -120.0   // loudness live, recalculé moins souvent

    private var timer: DispatchSourceTimer?
    private let telemetryQ = DispatchQueue(label: "nuedeface.telemetry")

    /// Queue sur laquelle TOUTES les mutations de graphe (play/stop/seek/updateMix/buildGraph/teardown) sont
    /// sérialisées. Le serveur la fixe à `applyQ` ; la tick télémétrie y route loop-replay et auto-stop pour
    /// ne pas muter le graphe en concurrence d'`applyQ`. Invariant : le graphe ne change que sur cette queue.
    var controlQueue: DispatchQueue?
    private func onControl(_ work: @escaping () -> Void) { (controlQueue ?? telemetryQ).async(execute: work) }

    /// Insert dynamique (compresseur/limiteur/multibande) dont on mesure la réduction de gain.
    private static let dynamicSubtypes: Set<String> = ["dcmp", "lmtr", "mcmp", "dynp", "mcph"]
    private func isDynamics(_ ins: Document.Insert) -> Bool { ins.subType.map { LiveEngine.dynamicSubtypes.contains($0) } ?? false }

    /// Installe un tap RMS sur la sortie d'un nœud (une seule fois) → nodeRMS[node]. Pour la GR mesurée.
    private func ensureRMSTap(_ n: AVAudioNode) {
        let id = ObjectIdentifier(n)
        if tappedIds.contains(id) { return }
        tappedIds.insert(id); grTapNodes.append(n)
        n.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let nfr = Int(buf.frameLength), nc = Int(buf.format.channelCount); var s = 0.0
            for c in 0..<nc { let p = ch[c]; for i in 0..<nfr { s += Double(p[i]) * Double(p[i]) } }
            let rms = Float(sqrt(s / Double(max(1, nfr * nc))))
            self.lock.lock(); self.nodeRMS[id] = rms; self.lock.unlock()
        }
    }

    /// Pose les taps GR sur une chaîne d'inserts : pour chaque insert dynamique, on tape son entrée et sa sortie.
    private func wireGR(_ chain: [Engine.BuiltInsert], input: AVAudioNode) {
        var pre: AVAudioNode = input
        for link in chain {
            if isDynamics(link.ins) {
                ensureRMSTap(pre); ensureRMSTap(link.node)
                grChain.append((link.id, ObjectIdentifier(pre), ObjectIdentifier(link.node)))
            }
            pre = link.node
        }
    }

    /// télémétrie best-effort throttlée ~33 ms (playhead + crêtes master L/R + crête par piste).
    var onTelemetry: ((LiveTelemetry) -> Void)?

    // MARK: transport

    func play(_ doc: Document, from: Double, to: Double?, loop: Bool) {
        teardown()
        buildGraph(doc)
        engine.prepare()
        do { try engine.start() } catch {
            FileHandle.standardError.write("LiveEngine: start a échoué: \(error)\n".data(using: .utf8)!)
            return
        }
        let fromS = Int(max(0, from) * sr)
        for tn in trackNodes {
            for p in tn.players {
                guard let full = scheduledBuffers[p] else { continue }
                let n = Int(full.frameLength)
                guard fromS < n else { continue }       // ce buffer se termine avant `from`
                let count = n - fromS
                guard let seg = AVAudioPCMBuffer(pcmFormat: LiveEngine.fmt, frameCapacity: AVAudioFrameCount(count)) else { continue }
                seg.frameLength = AVAudioFrameCount(count)
                guard let fcd = full.floatChannelData, let scd = seg.floatChannelData else { continue }
                for ch in 0..<2 {
                    let src = fcd[ch], dst = scd[ch]
                    for i in 0..<count { dst[i] = src[fromS + i] }
                }
                p.scheduleBuffer(seg, at: nil, completionHandler: nil)
                p.play()
            }
        }
        lock.lock()
        playing = true; startFrom = max(0, from); startUptimeNs = DispatchTime.now().uptimeNanoseconds
        stopAt = to; loopOn = loop; loopStart = max(0, from)
        meterPeakL = 0; meterPeakR = 0; trackPeaks = [:]; busPeaks = [:]
        lock.unlock()
        startTimer()
    }

    func stop() {
        let head = playhead()
        teardown()
        onTelemetry?(LiveTelemetry(playhead: head, peakL: 0, peakR: 0, tracks: [:], buses: [:], playing: false))
    }

    func seek(_ doc: Document, to t: Double) {
        if playing {
            lock.lock(); let lp = loopOn; lock.unlock()   // un seek pendant une lecture en boucle reste en boucle
            play(doc, from: t, to: stopAt, loop: lp)
        }
        else {
            lock.lock(); startFrom = max(0, t); lock.unlock()
            onTelemetry?(LiveTelemetry(playhead: max(0, t), peakL: 0, peakR: 0, tracks: [:], buses: [:], playing: false))
        }
    }

    /// MAJ live et bon marché des paramètres de mix (sans reconstruire le graphe).
    func updateMix(_ doc: Document) {
        guard playing else { return }
        let anySolo = doc.anySolo()
        for tn in trackNodes {
            guard let t = doc.tracks[tn.id] else { continue }
            let autoGain = doc.isAutomated("track/\(t.id)/controls/gain")   // cohérent avec buildGraph (gain baké)
            let autoPan = doc.isAutomated("track/\(t.id)/controls/pan")
            tn.mix.outputVolume = Engine.trackMixVolume(t, anySolo: anySolo, autoGain: autoGain)
            if !autoPan { tn.mix.pan = Float(t.pan) }   // pan automatisé : laissé à la tick (ne pas écraser)
            for ins in tn.inserts {
                guard let model = t.fx[ins.id] else { continue }
                Engine.applyInsertParams(ins.node, ins.type, model.params, bypass: model.bypass)
            }
        }
        for (bid, mix) in busMixers {                          // gain/mute de chaque bus, en direct
            guard let b = doc.buses[bid] else { continue }
            mix.outputVolume = b.mute ? 0 : Float(b.gain)
        }
        for bi in busInserts {                                  // params des inserts de bus, en direct
            guard let model = doc.buses[bi.bus]?.fx[bi.id] else { continue }
            Engine.applyInsertParams(bi.node, bi.type, model.params, bypass: model.bypass)
        }
        for sg in sendGains {                                   // niveaux de sends, en direct
            if let t = sg.track, let snd = doc.tracks[t]?.sends.first(where: { $0.id == sg.sendId }) { sg.node.outputVolume = Float(snd.level) }
            else if let b = sg.bus, let snd = doc.buses[b]?.sends.first(where: { $0.id == sg.sendId }) { sg.node.outputVolume = Float(snd.level) }
        }
    }

    // MARK: graphe

    private var scheduledBuffers: [AVAudioPlayerNode: AVAudioPCMBuffer] = [:]

    /// Fan-out live : adaptateur sur `Engine.fanout` (même algo partagé avec l'offline), qui en plus enregistre
    /// chaque nœud créé pour le teardown (`onAttach`) et garde les nœuds de gain par send (MAJ live des niveaux).
    private func liveFanout(_ source: AVAudioNode, main: AVAudioMixerNode, sends: [Document.Send], track: String?, bus: String?) {
        let resolved = sends.compactMap { snd -> (Document.Send, AVAudioMixerNode)? in busMixers[snd.dest].map { (snd, $0) } }
        let gains = Engine.fanout(engine, source, main: main,
                                  sends: resolved.map { (dest: $0.1, level: Float($0.0.level)) },
                                  onAttach: { [self] n in attached.append(n) })
        for (i, pair) in resolved.enumerated() { sendGains.append((track, bus, pair.0.id, gains[i])) }
    }

    private func buildGraph(_ doc: Document) {
        var maxFrames = 0
        currentDoc = doc
        let anySolo = doc.anySolo()
        // GRAPHE DE BUS : un mixer + chaîne d'inserts par bus, chacun routé vers son output (master → sortie)
        var busOut: [String: AVAudioNode] = [:]
        for bid in doc.busOrder {
            guard let b = doc.buses[bid] else { continue }
            let mix = AVAudioMixerNode(); engine.attach(mix); attached.append(mix); busMixers[bid] = mix
            let chain = Engine.buildInserts(engine, from: mix, fx: b.fx, order: b.fxOrder, pathPrefix: "bus/\(bid)",
                                            doc: doc, onAttach: { [self] n in attached.append(n) })
            autoParams.append(contentsOf: chain.autoParams)
            for bi in chain.built { busInserts.append((bid, bi.id, bi.node, bi.type)) }
            wireGR(chain.built, input: mix)   // GR mesurée sur les inserts dynamiques du bus (ex. comp/limiteur master)
            busOut[bid] = chain.output
            mix.outputVolume = b.mute ? 0 : Float(b.gain)
            if bid != "master" {                            // VU live par bus aux (le master a son tap stéréo dédié)
                mix.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
                    guard let self, let ch = buf.floatChannelData else { return }
                    var pk: Float = 0
                    for c in 0..<Int(buf.format.channelCount) {
                        let p = ch[c]; for i in 0..<Int(buf.frameLength) { let a = abs(p[i]); if a > pk { pk = a } }
                    }
                    self.lock.lock(); self.busPeaks[bid] = pk; self.lock.unlock()
                }
            }
        }
        // bus master = seed du document ; absent = doc corrompu → on n'érige pas un graphe partiel qui crasherait.
        guard let masterInput = busMixers["master"] else {
            FileHandle.standardError.write("LiveEngine: bus master absent, graphe live abandonné\n".data(using: .utf8)!)
            return
        }
        for bid in doc.busOrder {
            guard let outNode = busOut[bid], let b = doc.buses[bid] else { continue }
            let mainDest = (bid == "master") ? engine.mainMixerNode : (busMixers[b.output] ?? masterInput)
            liveFanout(outNode, main: mainDest, sends: b.sends, track: nil, bus: bid)
        }
        engine.mainMixerNode.outputVolume = 1
        for tid in doc.trackOrder {
            guard let t = doc.tracks[tid], let tb = Engine.trackBuffer(t, doc) else { continue }
            let n = tb.l.count; maxFrames = max(maxFrames, n)
            guard let buf = AVAudioPCMBuffer(pcmFormat: LiveEngine.fmt, frameCapacity: AVAudioFrameCount(n)), let bd = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { bd[0][i] = tb.l[i]; bd[1][i] = tb.r[i] }

            let player = AVAudioPlayerNode(), mix = AVAudioMixerNode()
            engine.attach(player); engine.attach(mix); attached += [player, mix]
            let chain = Engine.buildInserts(engine, from: player, fx: t.fx, order: t.fxOrder, pathPrefix: "track/\(tid)",
                                            doc: doc, onAttach: { [self] n in attached.append(n) })
            autoParams.append(contentsOf: chain.autoParams)
            let upstream = chain.output
            let inserts: [(id: String, node: AVAudioUnit, type: String)] = chain.built.map { (id: $0.id, node: $0.node, type: $0.type) }
            wireGR(chain.built, input: player)   // GR mesurée sur les inserts dynamiques de la piste
            liveFanout(upstream, main: mix, sends: t.sends.filter { $0.pre }, track: tid, bus: nil)             // pré-fader
            liveFanout(mix, main: busMixers[t.output] ?? masterInput, sends: t.sends.filter { !$0.pre }, track: tid, bus: nil)  // post-fader → bus de sortie
            let autoGain = doc.isAutomated("track/\(tid)/controls/gain")   // gain baké dans le buffer si automatisé
            let autoPan = doc.isAutomated("track/\(tid)/controls/pan")     // pan : via le nœud (par tick si automatisé)
            mix.outputVolume = Engine.trackMixVolume(t, anySolo: anySolo, autoGain: autoGain); mix.pan = Float(t.pan)
            if autoPan { autoPanNodes.append((mix, "track/\(tid)/controls/pan")) }
            scheduledBuffers[player] = buf
            trackNodes.append(TrackNodes(id: tid, mix: mix, players: [player], inserts: inserts))
            // tap VU par piste (post-fader/pan) → crête live de ce canal
            mix.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
                guard let self, let ch = buf.floatChannelData else { return }
                var pk: Float = 0
                for c in 0..<Int(buf.format.channelCount) {
                    let p = ch[c]; for i in 0..<Int(buf.frameLength) { let a = abs(p[i]); if a > pk { pk = a } }
                }
                self.lock.lock(); self.trackPeaks[tid] = pk; self.lock.unlock()
            }
        }
        duration = Double(maxFrames) / sr

        // tap mètre master, STÉRÉO (crêtes L et R séparées) + alimente le ring 3 s (FFT + loudness live)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let nc = Int(buf.format.channelCount), n = Int(buf.frameLength)
            var l: Float = 0, r: Float = 0
            let pl = ch[0], pr = ch[min(1, nc - 1)]
            for i in 0..<n { let a = abs(pl[i]); if a > l { l = a }; let b = abs(pr[i]); if b > r { r = b } }
            self.lock.lock()
            self.meterPeakL = l; self.meterPeakR = r
            var w = self.ringW
            for i in 0..<n { self.ringL[w] = pl[i]; self.ringR[w] = pr[i]; w += 1; if w >= LiveEngine.ringCap { w = 0 } }
            self.ringW = w; self.ringN = min(LiveEngine.ringCap, self.ringN + n)
            self.lock.unlock()
        }
        // snapshot IMMUABLE des lanes automatisées (Lane = value type → deep copy) : la tick télémétrie lira ce
        // snapshot, jamais `doc.automation` vivant → fin de la data race avec les mutations d'automation sur applyQ.
        let lanes = doc.automationSnapshot(paths: Set(autoParams.map { $0.path } + autoPanNodes.map { $0.path }))
        lock.lock(); autoLanes = lanes; lock.unlock()
    }

    /// Copie linéaire (ordre chronologique) des `count` derniers samples du ring → pour FFT/loudness hors lock.
    private func ringSnapshot(_ count: Int) -> (l: [Float], r: [Float]) {
        let n = min(count, ringN); guard n > 0 else { return ([], []) }
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var idx = (ringW - n + LiveEngine.ringCap * 2) % LiveEngine.ringCap
        for i in 0..<n { l[i] = ringL[idx]; r[i] = ringR[idx]; idx += 1; if idx >= LiveEngine.ringCap { idx = 0 } }
        return (l, r)
    }

    private func teardown() {
        timer?.cancel(); timer = nil
        if engine.isRunning {
            engine.mainMixerNode.removeTap(onBus: 0)
            for tn in trackNodes { tn.mix.removeTap(onBus: 0) }
            for (bid, m) in busMixers where bid != "master" { m.removeTap(onBus: 0) }
            for n in grTapNodes { n.removeTap(onBus: 0) }
        }
        for tn in trackNodes { for p in tn.players { p.stop() } }
        engine.stop()
        for n in attached { engine.detach(n) }
        attached = []; trackNodes = []; scheduledBuffers = [:]; busMixers = [:]; busInserts = []; sendGains = []
        busPeaks = [:]; currentDoc = nil
        ringW = 0; ringN = 0; nodeRMS = [:]; grChain = []; grTapNodes = []; tappedIds = []; loudnessTick = 0
        lastMom = -120; lastShort = -120; lastTP = -120
        lock.lock(); autoParams = []; autoPanNodes = []; autoLanes = [:]; playing = false; ending = false; lock.unlock()
    }

    // MARK: télémétrie

    private func playhead() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard playing else { return startFrom }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startUptimeNs) / 1e9
        return startFrom + elapsed
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: telemetryQ)
        t.schedule(deadline: .now() + 0.033, repeating: 0.033)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let head = self.playhead()
            self.lock.lock()
            let l = self.meterPeakL, r = self.meterPeakR, tp = self.trackPeaks, bp = self.busPeaks
            let rms = self.nodeRMS, chain = self.grChain
            let end = self.stopAt ?? self.duration
            self.lock.unlock()
            if head >= end {                       // fin atteinte → la mutation de graphe se fait sur la CONTROL QUEUE
                self.lock.lock(); let already = self.ending; self.ending = true; self.lock.unlock()
                if !already {                      // garde anti-double-dispatch (la tick refire toutes les 33 ms)
                    self.onControl {
                        if self.loopOn, let d = self.currentDoc { self.play(d, from: self.loopStart, to: self.stopAt, loop: true) }
                        else { self.stop() }
                    }
                }
                return
            }
            // automation live des params d'inserts (best-effort) — lue sur le SNAPSHOT immuable, jamais le doc vivant
            self.lock.lock(); let aps = self.autoParams; let pans = self.autoPanNodes; let lanes = self.autoLanes; self.lock.unlock()
            if !aps.isEmpty || !pans.isEmpty {
                let pos = Int(head * self.sr)
                for ap in aps {
                    let v = lanes[ap.path].flatMap { Document.laneValue($0, atSample: pos) } ?? 0
                    Engine.setOneParam(ap.node, ap.type, ap.name, v)
                }
                for pn in pans {                          // pan automatisé : node.pan (même loi que le statique)
                    pn.mix.pan = Float(lanes[pn.path].flatMap { Document.laneValue($0, atSample: pos) } ?? 0)
                }
            }
            // FFT live (chaque tick, léger) — bins log derrière la courbe d'EQ
            let win = self.ringSnapshot(1024)
            var spectrum: [Float] = []
            if win.l.count >= 1024 {
                var mono = [Float](repeating: 0, count: win.l.count)
                for i in 0..<win.l.count { mono[i] = (win.l[i] + win.r[i]) * 0.5 }
                spectrum = Spectrum.liveBins(mono, sr: self.sr)
            }
            // GR mesurée (chaque tick) — atténuation pré/post de chaque insert dynamique
            var gr: [String: Float] = [:]
            for g in chain {
                let pre = rms[g.pre] ?? 0, post = rms[g.post] ?? 0
                let preDb = pre > 1e-6 ? 20 * log10(pre) : -120, postDb = post > 1e-6 ? 20 * log10(post) : -120
                gr[g.insertId] = max(0, Float(preDb - postDb))
            }
            // loudness live (1 tick sur 3, plus lourd) — fenêtre récente 3 s
            self.loudnessTick += 1
            if self.loudnessTick % 3 == 0 {
                let snap = self.ringSnapshot(LiveEngine.ringCap)
                if snap.l.count > 4096 {
                    let m = Engine.loudnessOf(snap, sr: self.sr)
                    self.lastMom = m.momentaryMax; self.lastShort = m.shortTermMax; self.lastTP = m.truePeak
                }
            }
            var t = LiveTelemetry(playhead: head, peakL: l, peakR: r, tracks: tp, buses: bp, playing: true)
            t.spectrum = spectrum; t.gainReduction = gr
            t.momentary = self.lastMom; t.shortTerm = self.lastShort; t.truePeak = self.lastTP
            self.onTelemetry?(t)
        }
        timer = t; t.resume()
    }
}
