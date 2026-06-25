// Nuedeface — proof moteur : coût du changement d'insert à chaud.
//
// But : mesurer objectivement, sans carte son, ce que coûtent DEUX stratégies pour
// modifier la chaîne d'inserts pendant la lecture, sur un graphe AVAudioEngine.
//   A. DETACH    — re-câblage structurel : on retire le nœud EQ du graphe.
//   B. BYPASS    — slot pré-alloué : l'EQ reste câblé, on toggle .bypass (= delta de param).
// Pour chacune : temps wall-clock + discontinuité d'échantillon (clic) au splice vs baseline.
//
// Tourne en manual rendering offline => déterministe, pas de device audio.
//
//   swiftc proofs/hot_swap.swift -o /tmp/hot_swap && /tmp/hot_swap

import AVFoundation

let sr = 48_000.0
let block: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// --- buffer de sinus en boucle (source synthétique, aucun fichier requis) ---
func tone(_ hz: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
    buf.frameLength = frames
    for ch in 0..<2 {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(frames) {
            p[i] = Float(0.2 * sin(2.0 * .pi * hz * Double(i) / sr))
        }
    }
    return buf
}

func maxStep(_ a: ArraySlice<Float>) -> Float {
    var m: Float = 0
    var prev: Float? = nil
    for v in a {
        if let pv = prev { m = max(m, abs(v - pv)) }
        prev = v
    }
    return m
}

enum Mode { case detach, bypass, bypassActive, bypassActiveRamped }

struct Result { var reconfigMs: Double; var baseline: Float; var atSwap: Float; var err: String? }

func run(_ mode: Mode) -> Result {
    let engine = AVAudioEngine()
    let p1 = AVAudioPlayerNode()
    let p2 = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    let tmix = AVAudioMixerNode()        // mixer de piste 1 : porte le gain qu'on peut ramper
    let mixer = engine.mainMixerNode
    let active = (mode == .bypassActive || mode == .bypassActiveRamped)

    // EQ actif : +12 dB à 220 Hz, pile sur le ton de la piste 1 → le bypass fait vraiment chuter le signal.
    if active {
        let band = eq.bands[0]
        band.filterType = .parametric
        band.frequency = 220
        band.bandwidth = 1.0
        band.gain = 12.0
        band.bypass = false
        eq.bypass = false
    }

    engine.attach(p1); engine.attach(p2); engine.attach(eq); engine.attach(tmix)
    engine.connect(p1, to: eq, format: fmt)
    engine.connect(eq, to: tmix, format: fmt)
    engine.connect(tmix, to: mixer, format: fmt)
    engine.connect(p2, to: mixer, format: fmt)

    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
    try! engine.start()

    p1.scheduleBuffer(tone(220, frames: AVAudioFrameCount(sr)), at: nil, options: .loops)
    p2.scheduleBuffer(tone(330, frames: AVAudioFrameCount(sr)), at: nil, options: .loops)
    p1.play(); p2.play()

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
    let totalBlocks = 200, swapAtBlock = 100
    var samples = [Float](); var swapIdx = 0
    var reconfigNanos: UInt64 = 0; var err: String? = nil

    for b in 0..<totalBlocks {
        if mode == .bypassActiveRamped {
            // On enveloppe le toggle d'un fade de gain : silence avant, bypass dans le creux, remontée.
            if b == swapAtBlock - 3 { tmix.outputVolume = 0 }        // le mixer ramp en interne
            if b == swapAtBlock {
                swapIdx = samples.count
                let t0 = DispatchTime.now().uptimeNanoseconds
                eq.bypass = true
                reconfigNanos = DispatchTime.now().uptimeNanoseconds - t0
            }
            if b == swapAtBlock + 3 { tmix.outputVolume = 1 }
        } else if b == swapAtBlock {
            swapIdx = samples.count
            let t0 = DispatchTime.now().uptimeNanoseconds
            switch mode {
            case .detach:                       // re-câblage structurel
                engine.disconnectNodeInput(eq)
                engine.disconnectNodeOutput(eq)
                engine.connect(p1, to: tmix, format: fmt)
                engine.detach(eq)
            case .bypass, .bypassActive:        // slot pré-alloué : juste un flag
                eq.bypass = true
            case .bypassActiveRamped: break
            }
            reconfigNanos = DispatchTime.now().uptimeNanoseconds - t0
        }
        do {
            if try engine.renderOffline(block, to: out) != .success { err = "render != success" }
        } catch { err = "\(error)"; break }
        let p = out.floatChannelData![0]
        for i in 0..<Int(out.frameLength) { samples.append(p[i]) }
    }

    // fenêtre large (±4 blocs) : capture un clic n'importe où dans la transition, y compris le fade.
    let baseline = maxStep(samples[(swapIdx/4)..<(swapIdx/4 + 256)])
    let span = 4 * Int(block)
    let lo = max(0, swapIdx - span), hi = min(samples.count, swapIdx + span)
    return Result(reconfigMs: Double(reconfigNanos) / 1_000_000.0,
                  baseline: baseline, atSwap: maxStep(samples[lo..<hi]), err: err)
}

func report(_ name: String, _ r: Result) {
    print("--- \(name) ---")
    if let e = r.err { print("  ERREUR            : \(e)") }
    print(String(format: "  reconfig          : %.3f ms", r.reconfigMs))
    print(String(format: "  step baseline     : %.6f", r.baseline))
    print(String(format: "  step au swap      : %.6f", r.atSwap))
    let ratio = r.baseline > 0 ? r.atSwap / r.baseline : 0
    print(String(format: "  ratio (clic)      : %.1fx", ratio))
    print("  verdict           : " + (ratio > 8 ? "GLITCH audible probable" : "splice propre"))
}

print("=== Nuedeface — proof : changement d'insert à chaud ===\n")
report("A. DETACH (re-câblage structurel)", run(.detach))
print("")
report("B. BYPASS (slot pré-alloué, EQ à plat)", run(.bypass))
print("")
report("C. BYPASS d'un EQ ACTIF (+12 dB à 220 Hz, coupé sec)", run(.bypassActive))
print("")
report("D. BYPASS d'un EQ ACTIF, enveloppé d'un fade de gain (~6 blocs)", run(.bypassActiveRamped))
