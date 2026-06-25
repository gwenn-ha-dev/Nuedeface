// Nuedeface — proof moteur : scheduling de clip (trim + position) + fades.
//
// Le cas d'usage central du concept : "trim les blancs, fade in/out". On vérifie :
//   1. placement SAMPLE-ACCURATE d'un clip sur la timeline (silence avant/après) ;
//   2. un clip trimé qui tombe en plein milieu d'une onde => coupé sec, ça CLIQUE ;
//   3. un court fade (baké dans le buffer) règle le clic, à l'attaque ET à la coda.
//
// Tourne en manual rendering offline => déterministe, pas de device audio.
//
//   swiftc proofs/clip_fades.swift -o /tmp/clip_fades && /tmp/clip_fades

import AVFoundation

let sr = 48_000.0
let block: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// --- source : 1 s de sinus 220 Hz écrite en fichier (= un "asset" importé) ---
let assetURL = URL(fileURLWithPath: "/tmp/nuedeface_asset.wav")
do {
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr))!
    buf.frameLength = AVAudioFrameCount(sr)
    for ch in 0..<2 {
        let p = buf.floatChannelData![ch]
        for i in 0..<Int(sr) { p[i] = Float(0.5 * sin(2.0 * .pi * 220.0 * Double(i) / sr)) }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    ]
    let f = try! AVAudioFile(forWriting: assetURL, settings: settings,
                             commonFormat: .pcmFormatFloat32, interleaved: false)
    try! f.write(from: buf)
}

// Trim : on démarre le clip à un offset où le sinus est NON nul (près d'un pic) =>
// un cut sec saute de 0 (silence) à ~0.5 => clic franc. offset = ~1/4 période.
let startSample = 24_000          // le clip apparaît à 0,5 s sur la timeline
let offsetFrames: AVAudioFramePosition = 55     // trim tête, tombe près d'un pic
let durationFrames: AVAudioFrameCount = 12_000  // 0,25 s de clip

func maxStep(_ a: ArraySlice<Float>) -> Float {
    var m: Float = 0; var prev: Float? = nil
    for v in a { if let p = prev { m = max(m, abs(v - p)) }; prev = v }
    return m
}

// Rend la timeline avec le clip placé ; `faded` => fade baké dans le buffer.
func renderClip(faded: Bool) -> [Float] {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: fmt)
    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
    try! engine.start()

    let file = try! AVAudioFile(forReading: assetURL)
    let at = AVAudioTime(sampleTime: AVAudioFramePosition(startSample), atRate: sr)

    if faded {
        // Lire le segment trimé dans un buffer, baker un fade in/out (raised-cosine, 5 ms).
        file.framePosition = offsetFrames
        let seg = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: durationFrames)!
        try! file.read(into: seg, frameCount: durationFrames)
        let n = Int(seg.frameLength)
        let fade = Int(0.005 * sr)            // 5 ms
        for ch in 0..<2 {
            let p = seg.floatChannelData![ch]
            for i in 0..<fade {
                let g = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(fade)))  // 0→1
                p[i] *= g
                p[n - 1 - i] *= g             // symétrique en coda
            }
        }
        player.scheduleBuffer(seg, at: at, options: [], completionHandler: nil)
    } else {
        // Cut sec : segment joué direct depuis le fichier, sans fade.
        player.scheduleSegment(file, startingFrame: offsetFrames, frameCount: durationFrames,
                               at: at, completionHandler: nil)
    }
    player.play()

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
    var left = [Float]()
    let total = startSample + Int(durationFrames) + 6_000
    while left.count < total {
        guard (try? engine.renderOffline(block, to: out)) == .success else { break }
        let l = out.floatChannelData![0]
        for i in 0..<Int(out.frameLength) { left.append(l[i]) }
    }
    engine.stop()
    return left
}

func report(_ name: String, _ s: [Float]) {
    let endSample = startSample + Int(durationFrames)
    // bruit de fond hors clip (doit être ~0 => placement correct)
    let preMax = s[(startSample - 2000)..<(startSample - 200)].map { abs($0) }.max() ?? 0
    let postMax = s[(endSample + 200)..<(endSample + 2000)].map { abs($0) }.max() ?? 0
    // clics à l'attaque et à la coda
    let onset = maxStep(s[(startSample - 8)..<(startSample + 8)])
    let coda  = maxStep(s[(endSample - 8)..<(endSample + 8)])
    let body  = maxStep(s[(startSample + 1000)..<(startSample + 1256)])   // baseline intra-clip
    print("--- \(name) ---")
    print(String(format: "  silence avant clip  : %.6f  %@", preMax, preMax < 1e-4 ? "(placé juste)" : "(FUITE)"))
    print(String(format: "  silence après clip  : %.6f  %@", postMax, postMax < 1e-4 ? "(placé juste)" : "(FUITE)"))
    print(String(format: "  step intra-clip     : %.6f", body))
    print(String(format: "  step à l'attaque    : %.6f  (%.1fx) %@", onset, onset/body,
                 onset > body*8 ? "CLIC" : "propre"))
    print(String(format: "  step à la coda      : %.6f  (%.1fx) %@", coda, coda/body,
                 coda > body*8 ? "CLIC" : "propre"))
}

print("=== Nuedeface — proof : scheduling de clip + fades ===")
print(String(format: "clip : start=%d (%.2fs), trim offset=%d, durée=%d (%.2fs)\n",
             startSample, Double(startSample)/sr, offsetFrames, durationFrames, Double(durationFrames)/sr))
report("A. Clip coupé SEC (trim sans fade)", renderClip(faded: false))
print("")
report("B. Clip avec FADE in/out baké (5 ms)", renderClip(faded: true))
