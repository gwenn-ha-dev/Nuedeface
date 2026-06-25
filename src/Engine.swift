// Nuedeface — moteur (tranche verticale, audio réel).
//
// Builder OFFLINE depuis le document : construit un graphe AVAudioEngine reflétant le doc,
// rend hors-ligne, et expose analyze (LUFS/peak/clipping) + export (WAV/AAC natif).
// Supporte sources tons ET fichiers (conversion SR + fades bakés). Le reconcile-live
// reste prouvé à part (proofs/reconcile.swift) — c'est le chemin preview, hors slice.

import Foundation
import AVFoundation
import Accelerate

enum Engine {
    static let sr = 48_000.0
    static let block: AVAudioFrameCount = 512
    // Format de travail canonique, source unique (LiveEngine y réfère). Le `!` est sûr par contrat :
    // standardFormatWithSampleRate(_:channels:) ne renvoie nil que pour des paramètres invalides
    // (SR ≤ 0, canaux hors plage) ; 48 kHz / stéréo float est toujours constructible.
    static let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

    /// Diagnostic non fatal : un render qui échoue ne doit JAMAIS tuer le daemon (il emporterait
    /// l'UI + tous les clients). On loggue sur stderr et on renvoie un mix vide, que le serveur
    /// traduit en réponse explicite ({ok:false} pour export, -120 dB pour les mesures).
    static func warn(_ msg: String) {
        FileHandle.standardError.write("nuedeface: \(msg)\n".data(using: .utf8)!)
    }

    // --- inserts : fabrique + application des params (partagé offline ET live) ---
    /// Crée le nœud AVAudioUnit pour un type d'insert (nil = type inconnu).
    /// `subType` n'est lu que pour le type générique "au" (n'importe quelle AU effet Apple).
    static func makeInsert(_ type: String, subType: String? = nil) -> AVAudioUnit? {
        switch type {
        case "eq":
            let e = AVAudioUnitEQ(numberOfBands: 4)        // 4 bandes fixes : low-shelf · 2 peaks · high-shelf
            e.bands[0].filterType = .lowShelf
            e.bands[1].filterType = .parametric; e.bands[1].bandwidth = 1.0
            e.bands[2].filterType = .parametric; e.bands[2].bandwidth = 1.0
            e.bands[3].filterType = .highShelf
            for b in e.bands { b.bypass = false }
            return e
        case "reverb":     return AVAudioUnitReverb()
        case "delay":      return AVAudioUnitDelay()
        case "distortion": return AVAudioUnitDistortion()
        case "au":         return subType.flatMap { AU.make($0) }
        default:           return nil
        }
    }

    /// Applique les params (et le bypass) à un nœud déjà créé du bon type. Utilisé au build ET en live.
    static func applyInsertParams(_ node: AVAudioUnit, _ type: String, _ p: [String: Double], bypass: Bool) {
        switch type {
        case "eq":
            guard let e = node as? AVAudioUnitEQ, e.bands.count >= 4 else { return }
            let defF: [Double] = [100, 500, 3_000, 8_000]               // params par bande : b<i>_freq / b<i>_gain / b<i>_bw
            for i in 0..<4 {
                e.bands[i].frequency = Float(p["b\(i)_freq"] ?? defF[i])
                e.bands[i].gain = Float(p["b\(i)_gain"] ?? 0)
                if e.bands[i].filterType == .parametric {               // peaks (1,2) : largeur réglable (octaves)
                    e.bands[i].bandwidth = Float(min(5, max(0.05, p["b\(i)_bw"] ?? 1.0)))
                }
                e.bands[i].bypass = bypass
            }
            e.bypass = bypass
        case "reverb":
            guard let r = node as? AVAudioUnitReverb else { return }
            r.loadFactoryPreset(AVAudioUnitReverbPreset(rawValue: Int(p["preset"] ?? 6)) ?? .largeHall)
            r.wetDryMix = Float(p["mix"] ?? 30); r.bypass = bypass
        case "delay":
            guard let d = node as? AVAudioUnitDelay else { return }
            d.delayTime = TimeInterval(p["time"] ?? 0.25); d.feedback = Float(p["feedback"] ?? 30)
            d.wetDryMix = Float(p["mix"] ?? 25); d.bypass = bypass
        case "distortion":
            guard let ds = node as? AVAudioUnitDistortion else { return }
            ds.loadFactoryPreset(AVAudioUnitDistortionPreset(rawValue: Int(p["preset"] ?? 0)) ?? .drumsBitBrush)
            ds.preGain = Float(p["drive"] ?? -6); ds.wetDryMix = Float(p["mix"] ?? 40); ds.bypass = bypass
        case "au":
            // générique : on adresse les params de l'AU par leur identifier (clé du dict).
            if let tree = node.auAudioUnit.parameterTree {
                for param in tree.allParameters { if let v = p[param.identifier] { param.value = Float(v) } }
            }
            (node as? AVAudioUnitEffect)?.bypass = bypass
        default: break
        }
    }

    /// Règle UN seul param d'un insert (pour l'automation : ramps par bloc offline / par tick live).
    static func setOneParam(_ node: AVAudioUnit, _ type: String, _ name: String, _ v: Double) {
        switch type {
        case "eq":
            guard let e = node as? AVAudioUnitEQ, e.bands.count >= 4,
                  name.hasPrefix("b"), let us = name.firstIndex(of: "_"),
                  let i = Int(name[name.index(after: name.startIndex)..<us]), i >= 0, i < 4 else { return }
            let field = name[name.index(after: us)...]
            if field == "gain" { e.bands[i].gain = Float(v) }
            else if field == "freq" { e.bands[i].frequency = Float(v) }
            else if field == "bw", e.bands[i].filterType == .parametric { e.bands[i].bandwidth = Float(min(5, max(0.05, v))) }
        case "reverb":
            if let r = node as? AVAudioUnitReverb, name == "mix" { r.wetDryMix = Float(v) }
        case "delay":
            guard let d = node as? AVAudioUnitDelay else { return }
            switch name { case "time": d.delayTime = TimeInterval(v); case "feedback": d.feedback = Float(v); case "mix": d.wetDryMix = Float(v); default: break }
        case "distortion":
            guard let ds = node as? AVAudioUnitDistortion else { return }
            if name == "drive" { ds.preGain = Float(v) } else if name == "mix" { ds.wetDryMix = Float(v) }
        case "au":
            if let tree = node.auAudioUnit.parameterTree { for param in tree.allParameters where param.identifier == name { param.value = Float(v) } }
        default: break
        }
    }

    // --- projection PARTAGÉE doc → nœuds (utilisée par le render offline ET le graphe live) ---
    // Ces helpers tiennent les décisions qui DOIVENT rester identiques entre les deux moteurs ; les avoir en
    // double (c'était le cas) = risque de divergence silencieuse (une loi de gain ou un chemin d'automation qui
    // change d'un côté seulement). Le câblage spécifique (scheduling, taps, suivi des nœuds attachés) reste, lui,
    // propre à chaque moteur. `onAttach` permet au live d'enregistrer chaque nœud créé (pour son teardown).

    /// Volume du mixer de piste : mute/solo coupent ; gain automatisé → 1 (le gain est baké dans le buffer).
    static func trackMixVolume(_ t: Document.Track, anySolo: Bool, autoGain: Bool) -> Float {
        let silenced = t.mute || (anySolo && !t.solo)
        return silenced ? 0 : (autoGain ? 1 : Float(t.gain))
    }

    /// Un insert instancié et câblé dans une chaîne (rendu au live pour son suivi GR/MAJ ; ignoré offline).
    struct BuiltInsert { let id: String; let node: AVAudioUnit; let type: String; let ins: Document.Insert }

    /// Construit la chaîne d'inserts série depuis `input` (attache + applique params + connecte), et collecte les
    /// params automatisés sous `pathPrefix` ("track/<id>" ou "bus/<id>"). Renvoie le dernier nœud (= sortie de la
    /// chaîne), les inserts bâtis, et les params automatisés — tout ce dont les deux moteurs ont besoin.
    static func buildInserts(_ engine: AVAudioEngine, from input: AVAudioNode,
                             fx: [String: Document.Insert], order: [String], pathPrefix: String, doc: Document,
                             onAttach: ((AVAudioNode) -> Void)? = nil)
        -> (output: AVAudioNode, built: [BuiltInsert],
            autoParams: [(node: AVAudioUnit, type: String, name: String, path: String)]) {
        var up = input
        var built: [BuiltInsert] = []
        var autos: [(node: AVAudioUnit, type: String, name: String, path: String)] = []
        for iid in order {
            guard let ins = fx[iid], let node = makeInsert(ins.type, subType: ins.subType) else { continue }
            engine.attach(node); onAttach?(node)
            applyInsertParams(node, ins.type, ins.params, bypass: ins.bypass)
            engine.connect(up, to: node, format: fmt); up = node
            built.append(BuiltInsert(id: iid, node: node, type: ins.type, ins: ins))
            for (pname, _) in ins.params {
                let path = "\(pathPrefix)/fx/\(iid)/params/\(pname)"
                if doc.isAutomated(path) { autos.append((node, ins.type, pname, path)) }
            }
        }
        return (up, built, autos)
    }

    /// Connecte `source` à sa destination principale + des taps de send (chacun via un nœud de gain), en un seul
    /// fan-out (connexion multi-points d'AVAudioEngine). Renvoie les nœuds de gain (pour MAJ live des niveaux).
    /// Le fan-out vise des nœuds DÉDIÉS (bus d'entrée 0 sûr) : un mixer-tap pour la destination principale +
    /// un mixer de gain par send. Ces nœuds dédiés se connectent ensuite aux mixers PARTAGÉS (bus, aux) en
    /// auto-assignation → pas de collision d'input bus (le bug qu'on aurait en forçant le bus 0 sur un mixer partagé).
    /// `onAttach` reçoit chaque nœud créé (mainTap + gains) → le live les suit pour son teardown.
    @discardableResult
    static func fanout(_ engine: AVAudioEngine, _ source: AVAudioNode, main: AVAudioMixerNode,
                       sends: [(dest: AVAudioMixerNode, level: Float)],
                       onAttach: ((AVAudioNode) -> Void)? = nil) -> [AVAudioMixerNode] {
        if sends.isEmpty { engine.connect(source, to: main, format: fmt); return [] }
        let mainTap = AVAudioMixerNode(); engine.attach(mainTap); onAttach?(mainTap)
        var points = [AVAudioConnectionPoint(node: mainTap, bus: 0)]
        var gains: [AVAudioMixerNode] = []
        for snd in sends {
            let g = AVAudioMixerNode(); engine.attach(g); onAttach?(g); g.outputVolume = snd.level
            engine.connect(g, to: snd.dest, format: fmt)
            points.append(AVAudioConnectionPoint(node: g, bus: 0)); gains.append(g)
        }
        engine.connect(source, to: points, fromBus: 0, format: fmt)
        engine.connect(mainTap, to: main, format: fmt)
        return gains
    }

    // Décode un asset entier en 48k stéréo float, avec cache.
    //
    // CONCURRENCE : les lectures lourdes (analyze/loudness/meters/spectrum/detectSilence/export) tournent
    // désormais sur une queue de LECTURE concurrente (Server.readQ), pas sur applyQ — chacune sur un CLONE
    // immuable du document (Document.cloneForRead) → le doc autoritaire n'est jamais lu pendant qu'une
    // mutation l'écrit. Mais les caches (decode/render) sont PARTAGÉS entre ces lectures concurrentes ET les
    // gestes mutants qui rendent sur applyQ (normalize/match, live.updateMix) → ils sont protégés par
    // `cacheLock`. Le verrou ne couvre QUE les accès aux structures de cache (lookup/store/LRU) ; le décodage
    // et le render eux-mêmes se font HORS verrou (sinon on sérialiserait tout le travail lourd). Deux threads
    // peuvent donc décoder/rendre la même chose en double (résultat identique, content-addressed) — coût rare,
    // jamais une corruption.
    //
    // Clé = (chemin, mtime, taille) : un fichier ré-enregistré au MÊME chemin invalide son entrée (sinon
    // on rendait l'ancien audio sans le savoir — faux dans la boucle muter→mesurer). Borné en mémoire par
    // LRU sur un plafond de samples (sinon chaque import restait en RAM pour la vie du daemon).
    private static let cacheLock = NSLock()                     // protège decode* ET render* (accès concurrents)
    private static var decodeCache: [String: (l: [Float], r: [Float])] = [:]
    private static var decodePathKey: [String: String] = [:]    // chemin -> empreinte courante (1 entrée/chemin)
    private static var decodeOrder: [String] = []               // LRU des empreintes : tête = plus ancien
    private static var decodeFrames = 0                          // total de samples (par canal) en cache
    private static let decodeFrameCap = Int(sr) * 600           // ≈ 10 min mono-équivalent ⇒ ~230 Mo plafond

    private static func fileStamp(_ path: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a?[.size] as? NSNumber)?.intValue ?? 0
        return "\(path)|\(m)|\(s)"
    }
    private static func cacheStore(_ path: String, _ key: String, _ v: (l: [Float], r: [Float])) {
        decodeCache[key] = v; decodePathKey[path] = key; decodeFrames += v.l.count
        decodeOrder.removeAll { $0 == key }; decodeOrder.append(key)
        while decodeFrames > decodeFrameCap, decodeOrder.count > 1 {   // évince les plus anciens (jamais la dernière)
            let victim = decodeOrder.removeFirst()
            if let old = decodeCache.removeValue(forKey: victim) { decodeFrames -= old.l.count }
            if let p = decodePathKey.first(where: { $0.value == victim })?.key { decodePathKey[p] = nil }
        }
    }
    static func decode48k(_ path: String) -> (l: [Float], r: [Float])? {
        let key = fileStamp(path)
        cacheLock.lock()
        if let prev = decodePathKey[path], prev != key {            // fichier modifié → empreinte obsolète, on la jette
            if let old = decodeCache.removeValue(forKey: prev) { decodeFrames -= old.l.count }
            decodeOrder.removeAll { $0 == prev }; decodePathKey[path] = nil
        }
        if let c = decodeCache[key] {
            decodeOrder.removeAll { $0 == key }; decodeOrder.append(key)   // touch LRU
            cacheLock.unlock(); return c
        }
        cacheLock.unlock()                                          // décodage HORS verrou (travail lourd)
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        // fichier vide (length 0) → frameCapacity 0 → init nil : on renvoie nil au lieu de crasher.
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        guard (try? file.read(into: src)) != nil, let conv = AVAudioConverter(from: file.processingFormat, to: fmt) else { return nil }
        let ratio = fmt.sampleRate / file.processingFormat.sampleRate
        let cap = AVAudioFrameCount(Double(src.frameLength) * ratio) + 4096
        guard let dst = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var fed = false; var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return src
        }
        if err != nil { return nil }
        let n = Int(dst.frameLength)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        guard let cd = dst.floatChannelData else { return nil }   // jamais nil pour un format float, mais on ne crashe pas le daemon
        let lp = cd[0], rp = cd[1]
        for i in 0..<n { l[i] = lp[i]; r[i] = rp[i] }
        let out = (l, r)
        cacheLock.lock(); cacheStore(path, key, out); cacheLock.unlock()
        return out
    }

    /// Galbe d'un fade : `x`∈[0,1] (0 = silence, 1 = plein) → gain. Partagé fade-in et fade-out.
    /// linear = rampe droite ; exp = convexe (démarrage lent, naturel à l'oreille) ; scurve = raised-cosine (transition douce).
    static func fadeGain(_ x: Double, _ shape: String) -> Double {
        let t = min(1, max(0, x))
        switch shape {
        case "exp":    return t * t
        case "scurve": return 0.5 - 0.5 * cos(Double.pi * t)
        default:       return t            // "linear"
        }
    }

    // Construit le buffer d'une piste : somme ses clips (positionnés start, tronqués offset/duration,
    // fades (galbe linéaire/exp/scurve) + gain bakés). Renvoie L/R + la longueur en samples.
    static func trackBuffer(_ t: Document.Track, _ doc: Document) -> (l: [Float], r: [Float])? {
        let clips = t.clipOrder.compactMap { t.clips[$0] }
        let length = clips.map { $0.start + $0.duration }.max() ?? 0
        guard length > 0 else { return nil }
        var l = [Float](repeating: 0, count: length), r = [Float](repeating: 0, count: length)
        for clip in clips {
            guard let info = doc.assets[clip.asset], let src = decode48k(info.path) else { continue }
            let avail = src.l.count
            let gd = clip.gain
            let cgpath = "track/\(t.id)/clips/\(clip.id)/gain"   // automation du gain de clip (sinon constante)
            let cgAuto = doc.isAutomated(cgpath)
            let dur = clip.duration
            let fi = min(clip.fadeIn, dur), fo = min(clip.fadeOut, dur)
            // la plage valide en j (offset+j ∈ source, start+j ∈ timeline) est CONTIGUË (from/to monotones en j) :
            // un préfixe et un suffixe sont hors-bornes, le milieu est plein → on calcule [jlo, jhi[ d'un coup.
            let jlo = max(0, -clip.offset, -clip.start)
            let jhi = min(dur, avail - clip.offset, length - clip.start)
            guard jlo < jhi else { continue }
            let m = jhi - jlo
            // enveloppe par sample (gain de clip ± automation, × galbe de fade aux bords) puis multiply-add vectorisé.
            var env = [Float](repeating: Float(gd), count: m)
            if cgAuto || fi > 0 || fo > 0 {
                for k in 0..<m {
                    let j = jlo + k
                    var e: Double = cgAuto ? (doc.laneValue(cgpath, atSample: clip.start + j) ?? gd) : gd
                    if fi > 0 && j < fi { e *= fadeGain(Double(j) / Double(fi), clip.fadeShape) }
                    if fo > 0 && j >= dur - fo { e *= fadeGain(Double(dur - 1 - j) / Double(fo), clip.fadeShape) }
                    env[k] = Float(e)
                }
            }
            let srcOff = clip.offset + jlo, dstOff = clip.start + jlo   // l[dst..] += src[src..] · env  (vDSP_vma : D = A·B + C)
            env.withUnsafeBufferPointer { ep in
                src.l.withUnsafeBufferPointer { sl in
                    l.withUnsafeMutableBufferPointer { lp in
                        vDSP_vma(sl.baseAddress! + srcOff, 1, ep.baseAddress!, 1, lp.baseAddress! + dstOff, 1, lp.baseAddress! + dstOff, 1, vDSP_Length(m))
                    }
                }
                src.r.withUnsafeBufferPointer { sr in
                    r.withUnsafeMutableBufferPointer { rp in
                        vDSP_vma(sr.baseAddress! + srcOff, 1, ep.baseAddress!, 1, rp.baseAddress! + dstOff, 1, rp.baseAddress! + dstOff, 1, vDSP_Length(m))
                    }
                }
            }
        }
        // automation de volume (track gain) bakée dans le buffer → audible offline ET live (gain = facteur linéaire,
        // identique à outputVolume → pas de divergence de loi). Le PAN, lui, n'est PAS baké : il est appliqué par
        // le nœud mixer (offline par bloc, live par tick) avec UNE SEULE loi — statique comme automatisé. Cela
        // supprime le saut de niveau qu'on avait en activant l'automation de pan (deux lois différentes).
        let gpath = "track/\(t.id)/controls/gain"
        if doc.isAutomated(gpath) {
            var gain = [Float](repeating: 1, count: length)
            for i in 0..<length { gain[i] = Float(doc.laneValue(gpath, atSample: i) ?? 1) }
            vDSP_vmul(l, 1, gain, 1, &l, 1, vDSP_Length(length))
            vDSP_vmul(r, 1, gain, 1, &r, 1, vDSP_Length(length))
        }
        return (l, r)
    }

    // Mémoïsation du render, content-addressed par (rev, fenêtre). Le doc est autoritaire et `rev` monotone :
    // un mix rendu pour une rev est valable tant que cette rev existe. La boucle muter→mesurer enchaîne souvent
    // plusieurs mesures sur la MÊME rev (analyze + loudness + spectrum + export du même mix) → on évite N renders
    // intégraux identiques. La clé inclut la rev (au lieu d'un flush global) : des lectures CONCURRENTES sur des
    // revs différentes (un clone pris juste avant une mutation) coexistent sans s'invalider mutuellement. Borné
    // par LRU sur un plafond de samples (un mix complet ~218 s ≈ 84 Mo) protégé par `cacheLock` (cf. decodeCache).
    private static var renderCache: [String: (l: [Float], r: [Float])] = [:]
    private static var renderOrder: [String] = []               // LRU des clés : tête = plus ancien
    private static var renderFrames = 0
    private static let renderFrameCap = Int(sr) * 1_200          // ≈ quelques mix complets retenus

    /// Rend le mix complet, ou seulement la fenêtre [from, to[ en samples (to=nil → jusqu'à la fin).
    /// La fenêtre slice les buffers de piste déjà bakés (automation/fades aux bonnes positions absolues).
    static func render(_ doc: Document, from: Int = 0, to: Int? = nil) -> (l: [Float], r: [Float]) {
        let key = "\(doc.rev)|\(max(0, from))|\(to.map(String.init) ?? "end")"
        cacheLock.lock()
        if let c = renderCache[key] {
            renderOrder.removeAll { $0 == key }; renderOrder.append(key)   // touch LRU
            cacheLock.unlock(); return c
        }
        cacheLock.unlock()                                          // render HORS verrou (travail lourd)
        let out = renderRaw(doc, from: from, to: to)
        cacheLock.lock()
        if renderCache[key] == nil {                                // un autre thread a pu rendre la même clé entre-temps
            renderCache[key] = out; renderFrames += out.l.count
            renderOrder.append(key)
            while renderFrames > renderFrameCap, renderOrder.count > 1 {   // évince les plus anciens (jamais le dernier)
                let victim = renderOrder.removeFirst()
                if let old = renderCache.removeValue(forKey: victim) { renderFrames -= old.l.count }
            }
        }
        cacheLock.unlock()
        return out
    }

    // Rend le document complet en offline. Renvoie le master stéréo.
    private static func renderRaw(_ doc: Document, from: Int = 0, to: Int? = nil) -> (l: [Float], r: [Float]) {
        let engine = AVAudioEngine()
        var scheduled: [(player: AVAudioPlayerNode, buf: AVAudioPCMBuffer)] = []
        var maxFrames = 0
        let ws = max(0, from)

        // params d'inserts automatisés : (nœud, type, nom, path) → réglés par bloc dans la boucle de render
        var autoParams: [(node: AVAudioUnit, type: String, name: String, path: String)] = []
        var autoPans: [(mix: AVAudioMixerNode, path: String)] = []   // pan automatisé → node.pan réglé par bloc
        let anySolo = doc.anySolo()

        // GRAPHE DE BUS : un mixer + chaîne d'inserts par bus ; chaque bus route vers son output
        // (master → sortie physique). Les pistes se connecteront ensuite à busInput[track.output].
        var busInput: [String: AVAudioMixerNode] = [:]   // entrée d'un bus (où l'on somme tracks/bus amont)
        var busOut: [String: AVAudioNode] = [:]          // sortie d'un bus (post-fx)
        for bid in doc.busOrder {
            guard let b = doc.buses[bid] else { continue }
            let mix = AVAudioMixerNode(); engine.attach(mix); busInput[bid] = mix
            let chain = Engine.buildInserts(engine, from: mix, fx: b.fx, order: b.fxOrder, pathPrefix: "bus/\(bid)", doc: doc)
            autoParams.append(contentsOf: chain.autoParams)
            busOut[bid] = chain.output
            mix.outputVolume = b.mute ? 0 : Float(b.gain)
        }
        // le bus master est le seed du document ; absent = projet corrompu → on échoue proprement.
        guard let masterInput = busInput["master"] else { warn("render: bus master absent"); return ([], []) }
        // chaîne inter-bus : sortie de chaque bus → entrée de son output (master → mainMixer) + sends de bus (post-fader)
        for bid in doc.busOrder {
            guard let outNode = busOut[bid], let b = doc.buses[bid] else { continue }
            let mainDest: AVAudioMixerNode = (bid == "master") ? engine.mainMixerNode : (busInput[b.output] ?? masterInput)
            let busSends = b.sends.compactMap { snd in busInput[snd.dest].map { (dest: $0, level: Float(snd.level)) } }
            Engine.fanout(engine, outNode, main: mainDest, sends: busSends)
        }
        engine.mainMixerNode.outputVolume = 1

        for tid in doc.trackOrder {
            guard let t = doc.tracks[tid], let tb = trackBuffer(t, doc) else { continue }
            let full = tb.l.count
            let we = min(to ?? full, full)
            guard ws < we else { continue }                 // cette piste finit avant la fenêtre
            let n = we - ws; maxFrames = max(maxFrames, n)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let bd = buf.floatChannelData else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { bd[0][i] = tb.l[ws + i]; bd[1][i] = tb.r[ws + i] }

            let player = AVAudioPlayerNode(), tmix = AVAudioMixerNode()
            engine.attach(player); engine.attach(tmix)
            // chaîne d'inserts (fxOrder), en série player → eq…→ tmix
            let chain = Engine.buildInserts(engine, from: player, fx: t.fx, order: t.fxOrder, pathPrefix: "track/\(tid)", doc: doc)
            autoParams.append(contentsOf: chain.autoParams)
            let upstream = chain.output
            // sends pré-fader : tap post-inserts (upstream) ; post-fader : tap post-fader (tmix)
            let preSends = t.sends.filter { $0.pre }.compactMap { snd in busInput[snd.dest].map { (dest: $0, level: Float(snd.level)) } }
            let postSends = t.sends.filter { !$0.pre }.compactMap { snd in busInput[snd.dest].map { (dest: $0, level: Float(snd.level)) } }
            Engine.fanout(engine, upstream, main: tmix, sends: preSends)
            Engine.fanout(engine, tmix, main: busInput[t.output] ?? masterInput, sends: postSends)   // → bus de sortie
            let autoGain = doc.isAutomated("track/\(tid)/controls/gain")   // gain/pan bakés si automatisés
            let autoPan = doc.isAutomated("track/\(tid)/controls/pan")
            tmix.outputVolume = Engine.trackMixVolume(t, anySolo: anySolo, autoGain: autoGain)   // mute/solo/gain : loi partagée
            tmix.pan = Float(t.pan)                                         // pan via le nœud (même loi partout)
            if autoPan { autoPans.append((tmix, "track/\(tid)/controls/pan")) }   // automatisé : réglé par bloc
            scheduled.append((player, buf))
        }

        do {
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
            try engine.start()
        } catch {
            warn("render: démarrage du graphe échoué (\(error))"); return ([], [])
        }
        for s in scheduled { s.player.scheduleBuffer(s.buf, at: nil, completionHandler: nil); s.player.play() }

        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else {
            engine.stop(); warn("render: allocation du buffer de sortie échouée"); return ([], [])
        }
        var left = [Float](), right = [Float]()
        // traîne : on rend tout le matériel PUIS on suit la queue des effets (reverb/delay) jusqu'au silence,
        // au lieu de couper à 50 ms (qui tronquait réverbs et échos). Garde-fou : 10 s de traîne max.
        let hardCap = maxFrames + Int(10.0 * sr)
        let silenceThresh: Float = 3.2e-5              // ≈ -90 dBFS
        var silentBlocks = 0
        left.reserveCapacity(maxFrames + Int(0.5 * sr)); right.reserveCapacity(maxFrames + Int(0.5 * sr))
        while left.count < hardCap {
            if !autoParams.isEmpty || !autoPans.isEmpty {  // ramps d'automation (params d'inserts + pan), par bloc
                let pos = ws + left.count                  // position ABSOLUE dans la timeline (fenêtre décalée)
                for ap in autoParams { Engine.setOneParam(ap.node, ap.type, ap.name, doc.laneValue(ap.path, atSample: pos) ?? 0) }
                for ap in autoPans { ap.mix.pan = Float(doc.laneValue(ap.path, atSample: pos) ?? 0) }
            }
            guard (try? engine.renderOffline(block, to: out)) == .success, let od = out.floatChannelData else { break }
            let l = od[0], r = od[1]
            var blockPeak: Float = 0
            for i in 0..<Int(out.frameLength) {
                left.append(l[i]); right.append(r[i])
                let a = max(abs(l[i]), abs(r[i])); if a > blockPeak { blockPeak = a }
            }
            if left.count >= maxFrames {                   // matériel entièrement rendu → on suit la traîne
                if blockPeak < silenceThresh { silentBlocks += 1 } else { silentBlocks = 0 }
                if silentBlocks >= 8 { break }             // ≈ 85 ms de silence continu → fin de traîne
            }
        }
        engine.stop()
        return (left, right)
    }

    static func analyze(_ doc: Document, from: Int = 0, to: Int? = nil) -> (lufs: Double, peak: Double, clipping: Bool) {
        return measure(render(doc, from: from, to: to))
    }

    /// Enveloppe de CRÊTE du mix complet (rendu offline), downsamplée par bucket de temps (défaut 50 ms) :
    /// le « tout le mix sans jouer » de la lane master v2. Crête = max(|L|,|R|) par bucket.
    static func masterEnvelope(_ doc: Document, bucketSec: Double = 0.05) -> (bucket: Double, peaks: [Float]) {
        let (l, r) = render(doc)
        let n = l.count
        guard n > 0 else { return (bucketSec, []) }
        let bs = max(1, Int(bucketSec * sr))
        var peaks: [Float] = []; peaks.reserveCapacity(n / bs + 1)
        var i = 0
        while i < n {
            let e = min(n, i + bs); var pk: Float = 0
            for j in i..<e { let a = max(abs(l[j]), abs(r[j])); if a > pk { pk = a } }
            peaks.append(pk); i = e
        }
        return (bucketSec, peaks)
    }

    private static func measure(_ mix: (l: [Float], r: [Float])) -> (lufs: Double, peak: Double, clipping: Bool) {
        let (l, r) = mix
        guard !l.isEmpty else { return (-.infinity, -.infinity, false) }
        var pk: Float = 0; for v in l { pk = max(pk, abs(v)) }; for v in r { pk = max(pk, abs(v)) }
        let peakDb = 20 * log10(Double(max(pk, 1e-9)))
        return (lufsIntegrated(l, r, sr: sr), peakDb, pk >= 1.0)
    }

    /// Mètre par PISTE : chaque piste rendue isolée (ses clips + sa chaîne d'inserts, sans master ni autres pistes),
    /// mute/solo ignorés (on mesure le signal de la piste). Renvoie [tid: (lufs, peak, clipping)].
    static func trackMeters(_ doc: Document) -> [(id: String, lufs: Double, peak: Double, clipping: Bool)] {
        var out: [(id: String, lufs: Double, peak: Double, clipping: Bool)] = []
        for tid in doc.trackOrder {
            guard let t = doc.tracks[tid], let tb = trackBuffer(t, doc) else {
                out.append((tid, -.infinity, -.infinity, false)); continue
            }
            let engine = AVAudioEngine(); let player = AVAudioPlayerNode(); let mix = AVAudioMixerNode()
            engine.attach(player); engine.attach(mix)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(tb.l.count)) else {
                out.append((tid, -.infinity, -.infinity, false)); continue
            }
            buf.frameLength = AVAudioFrameCount(tb.l.count)
            guard let bd = buf.floatChannelData else { out.append((tid, -.infinity, -.infinity, false)); continue }
            for i in 0..<tb.l.count { bd[0][i] = tb.l[i]; bd[1][i] = tb.r[i] }
            var upstream: AVAudioNode = player
            for iid in t.fxOrder {
                guard let ins = t.fx[iid], let node = Engine.makeInsert(ins.type, subType: ins.subType) else { continue }
                engine.attach(node); Engine.applyInsertParams(node, ins.type, ins.params, bypass: ins.bypass)
                engine.connect(upstream, to: node, format: fmt); upstream = node
            }
            engine.connect(upstream, to: mix, format: fmt)
            engine.connect(mix, to: engine.mainMixerNode, format: fmt)
            do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block); try engine.start() }
            catch { out.append((tid, -.infinity, -.infinity, false)); continue }
            player.scheduleBuffer(buf, at: nil, completionHandler: nil); player.play()
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else {
                engine.stop(); out.append((tid, -.infinity, -.infinity, false)); continue
            }
            var l = [Float](), r = [Float](); let total = tb.l.count + Int(0.05 * sr)
            while l.count < total {
                guard (try? engine.renderOffline(block, to: outBuf)) == .success, let od = outBuf.floatChannelData else { break }
                let lp = od[0], rp = od[1]
                for i in 0..<Int(outBuf.frameLength) { l.append(lp[i]); r.append(rp[i]) }
            }
            engine.stop()
            let m = measure((l, r))
            out.append((tid, m.lufs, m.peak, m.clipping))
        }
        return out
    }

    static func export(_ doc: Document, to url: URL, aac: Bool) -> Bool {
        let (l, r) = render(doc)
        guard !l.isEmpty else { return false }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count)), let bd = buf.floatChannelData else { return false }
        buf.frameLength = AVAudioFrameCount(l.count)
        for i in 0..<l.count { bd[0][i] = l[i]; bd[1][i] = r[i] }
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
               AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return false }
        return (try? f.write(from: buf)) != nil
    }

    // --- BS.1770 / EBU R128 (mètre validé par proofs/bounce_lufs.swift) ---
    private static func biquad(_ x: [Float], _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) -> [Float] {
        var y = [Float](repeating: 0, count: x.count); var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for n in 0..<x.count { let xn = Double(x[n]); let yn = b0*xn + b1*x1 + b2*x2 - a1*y1 - a2*y2
            y[n] = Float(yn); x2 = x1; x1 = xn; y2 = y1; y1 = yn }
        return y
    }
    private static func kWeight(_ x: [Float]) -> [Float] {
        let s1 = biquad(x, 1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
        return biquad(s1, 1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)
    }
    static func lufsIntegrated(_ left: [Float], _ right: [Float], sr: Double) -> Double {
        let kl = kWeight(left), kr = kWeight(right)
        let bs = Int(0.400 * sr), hop = Int(0.100 * sr)
        func ms(_ a: [Float], _ lo: Int, _ hi: Int) -> Double {
            var s = 0.0; for i in lo..<hi { s += Double(a[i]) * Double(a[i]) }; return s / Double(hi - lo) }
        var loud = [Double](), z = [Double](); var i = 0
        while i + bs <= kl.count { let zb = ms(kl, i, i + bs) + ms(kr, i, i + bs)
            if zb > 0 { z.append(zb); loud.append(-0.691 + 10 * log10(zb)) }; i += hop }
        guard !z.isEmpty else { return -.infinity }
        var absIdx = [Int](); for k in 0..<loud.count where loud[k] >= -70.0 { absIdx.append(k) }
        guard !absIdx.isEmpty else { return -.infinity }
        let meanZabs = absIdx.map { z[$0] }.reduce(0, +) / Double(absIdx.count)
        let gammaR = -0.691 + 10 * log10(meanZabs) - 10.0
        let keep = absIdx.filter { loud[$0] >= gammaR }
        guard !keep.isEmpty else { return -.infinity }
        return -0.691 + 10 * log10(keep.map { z[$0] }.reduce(0, +) / Double(keep.count))
    }

    // --- suite loudness pro (P3) : momentary / short-term / true-peak / LRA (EBU R128) ---
    struct Loudness { let integrated: Double; let momentaryMax: Double; let shortTermMax: Double; let truePeak: Double; let lra: Double }

    /// Mesure complète du mix rendu (fenêtre optionnelle). Integrated + LRA = programme entier (à la demande).
    static func loudnessMetrics(_ doc: Document, from: Int = 0, to: Int? = nil) -> Loudness {
        return loudnessOf(render(doc, from: from, to: to), sr: sr)
    }

    /// Loudness d'un couple de buffers. momentary=400 ms, short-term=3 s (max sur le programme),
    /// LRA=P10–P95 des fenêtres short-term gatées (porte abs −70, porte relative −20 LU), true-peak ×4.
    static func loudnessOf(_ mix: (l: [Float], r: [Float]), sr: Double) -> Loudness {
        let (left, right) = mix
        guard !left.isEmpty else { return Loudness(integrated: -.infinity, momentaryMax: -.infinity, shortTermMax: -.infinity, truePeak: -.infinity, lra: 0) }
        let kl = kWeight(left), kr = kWeight(right)
        func ms(_ a: [Float], _ lo: Int, _ hi: Int) -> Double { var s = 0.0; for i in lo..<hi { s += Double(a[i]) * Double(a[i]) }; return s / Double(hi - lo) }
        func windows(_ winSec: Double, _ hopSec: Double) -> [Double] {
            let bs = Int(winSec * sr), hop = max(1, Int(hopSec * sr)); guard bs > 0, bs <= kl.count else { return [] }
            var out = [Double](); var i = 0
            while i + bs <= kl.count { let z = ms(kl, i, i + bs) + ms(kr, i, i + bs); if z > 0 { out.append(-0.691 + 10 * log10(z)) }; i += hop }
            return out
        }
        let mom = windows(0.400, 0.100), short = windows(3.0, 0.100)
        // LRA : sur les fenêtres short-term, porte absolue puis relative (−20 LU), étendue P10→P95.
        var lra = 0.0
        let absKept = short.filter { $0 >= -70 }
        if absKept.count >= 2 {
            let meanLin = absKept.map { pow(10.0, $0 / 10.0) }.reduce(0, +) / Double(absKept.count)
            let relGate = 10 * log10(meanLin) - 20.0
            let kept = absKept.filter { $0 >= relGate }.sorted()
            if kept.count >= 2 {
                let p10 = kept[Int(Double(kept.count - 1) * 0.10)]
                let p95 = kept[Int(Double(kept.count - 1) * 0.95)]
                lra = max(0, p95 - p10)
            }
        }
        return Loudness(integrated: lufsIntegrated(left, right, sr: sr),
                        momentaryMax: mom.max() ?? -.infinity, shortTermMax: short.max() ?? -.infinity,
                        truePeak: truePeakDB(left, right), lra: lra)
    }

    // --- True-peak (dBTP) par sur-échantillonnage ×4 polyphase (méthode BS.1770-4) ---
    // FIR passe-bas windowed-sinc (fenêtre de Kaiser) décomposé en 4 phases. Chaque phase est normalisée à
    // gain DC unité → un échantillon plein-échelle lit exactement 0 dBTP, et les crêtes inter-échantillon
    // (que le pic-échantillon rate) sont reconstruites. Remplace l'ancienne interpolation linéaire (qui
    // sous-estimait de plusieurs dB) par un vrai mètre de crête reconstruite.
    static let tpPhases = 4
    private static let tpFIR: [[Float]] = buildTPFIR(phases: tpPhases, tapsPerPhase: 16, beta: 9.0)
    private static func buildTPFIR(phases: Int, tapsPerPhase: Int, beta: Double) -> [[Float]] {
        let n = phases * tapsPerPhase
        func i0(_ x: Double) -> Double {              // Bessel I0 (série) pour la fenêtre de Kaiser
            var sum = 1.0, term = 1.0, k = 1.0
            while true { let h = x / (2 * k); term *= h * h; sum += term; if term < 1e-12 * sum { break }; k += 1 }
            return sum
        }
        let denom = i0(beta), mid = Double(n - 1) / 2, fc = 1.0 / Double(phases)   // coupure = Nyquist d'origine
        var proto = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let m = Double(i) - mid
            let sinc = m == 0 ? fc : sin(Double.pi * fc * m) / (Double.pi * m)
            let r = mid > 0 ? (Double(i) - mid) / mid : 0
            proto[i] = sinc * i0(beta * sqrt(max(0, 1 - r * r))) / denom
        }
        var fir = [[Float]](repeating: [], count: phases)
        for p in 0..<phases {
            var c = [Float](); var i = p
            while i < n { c.append(Float(proto[i])); i += phases }
            let s = c.reduce(0, +); if s != 0 { for j in c.indices { c[j] /= s } }   // gain DC unité par phase
            fir[p] = c
        }
        return fir
    }
    static func truePeakDB(_ l: [Float], _ r: [Float]) -> Double {
        func tp(_ a: [Float]) -> Float {
            let n = a.count; guard n > 0 else { return 0 }
            var pk: Float = 0
            for i in 0..<n {
                if abs(a[i]) > pk { pk = abs(a[i]) }              // les échantillons d'origine (phase 0)
                for p in 1..<tpPhases {                           // les sous-échantillons reconstruits
                    let coeffs = tpFIR[p]; var acc: Float = 0
                    for k in 0..<coeffs.count { let idx = i - k; if idx >= 0 { acc += coeffs[k] * a[idx] } }
                    if abs(acc) > pk { pk = abs(acc) }
                }
            }
            return pk
        }
        return 20 * log10(Double(max(max(tp(l), tp(r)), 1e-9)))
    }

    // --- détection de silences / régions (P8) : « trim les blancs » devient pilotable par l'IA ---
    /// Régions (start,end en samples) sous `thresholdDb` (RMS) durant ≥ `minDurSamples`. Fenêtre glissante 50 ms.
    static func detectSilence(_ l: [Float], _ r: [Float], thresholdDb: Double, minDurSamples: Int, winSamples: Int = 2_400) -> [(start: Int, end: Int)] {
        let n = min(l.count, r.count); guard n > 0 else { return [] }
        let thr = pow(10.0, thresholdDb / 20.0)
        let hop = max(1, winSamples / 2)
        func rms(_ lo: Int) -> Double {
            let e = min(lo + winSamples, n); var s = 0.0
            for i in lo..<e { let a = Double(l[i]), b = Double(r[i]); s += (a * a + b * b) * 0.5 }
            return sqrt(s / Double(max(1, e - lo)))
        }
        var regions: [(Int, Int)] = []; var inSil = false; var silStart = 0; var i = 0
        while i < n {
            let quiet = rms(i) < thr
            if quiet && !inSil { inSil = true; silStart = i }
            else if !quiet && inSil { inSil = false; if i - silStart >= minDurSamples { regions.append((silStart, i)) } }
            i += hop
        }
        if inSil && n - silStart >= minDurSamples { regions.append((silStart, n)) }
        return regions
    }

    // --- ducking par automation (P9) : enveloppe de gain pour l'ambiance, pilotée par le RMS de la voix ---
    /// Suit le niveau de la source (voix). Quand elle dépasse `thresholdDb`, la cible descend à `depthDb`
    /// (négatif) avec attaque ; sinon remonte à 0 dB avec release. Points décimés (|Δ|>0.02) pour une lane légère.
    static func duckEnvelope(_ srcL: [Float], _ srcR: [Float], thresholdDb: Double, depthDb: Double,
                             attackMs: Double, releaseMs: Double, hopMs: Double = 20) -> [(t: Int, v: Double)] {
        let n = min(srcL.count, srcR.count); guard n > 0 else { return [] }
        let hop = max(1, Int(hopMs / 1000 * sr))
        let thr = pow(10.0, thresholdDb / 20.0)
        let depthLin = pow(10.0, depthDb / 20.0)
        let aCoef = exp(-Double(hop) / max(1, attackMs / 1000 * sr))   // lissage par hop
        let rCoef = exp(-Double(hop) / max(1, releaseMs / 1000 * sr))
        var raw: [(Int, Double)] = []; var gain = 1.0; var i = 0
        while i < n {
            let e = min(n, i + hop); var s = 0.0
            for j in i..<e { let a = Double(srcL[j]), b = Double(srcR[j]); s += (a * a + b * b) * 0.5 }
            let rms = sqrt(s / Double(max(1, e - i)))
            let target = rms > thr ? depthLin : 1.0
            let coef = target < gain ? aCoef : rCoef                   // attaque en descente, release en montée
            gain = target + (gain - target) * coef
            raw.append((i, gain)); i += hop
        }
        // décimation : on garde le 1er, le dernier, et tout point qui s'écarte de >0.02 du dernier gardé.
        var out: [(t: Int, v: Double)] = []
        for (k, pt) in raw.enumerated() {
            if k == 0 || k == raw.count - 1 || abs(pt.1 - (out.last?.v ?? 1)) > 0.02 { out.append((pt.0, pt.1)) }
        }
        return out
    }
}
