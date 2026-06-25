// Nuedeface — masterer réel : la boucle muter→render→mesurer→corriger sur un vrai fichier.
//
// 1. charge un m4a/wav dans le moteur (AVAudioEngine fait la conversion SR),
// 2. mesure son LUFS intégré (BS.1770 / EBU R128),
// 3. calcule le gain pour viser une cible de loudness, l'applique, RE-RENDER, RE-MESURE,
// 4. détecte le clipping (trade-off nommé, pas de dégradation silencieuse),
// 5. exporte WAV (PCM) + M4A (AAC natif macOS).
//
//   swiftc -O tools/master.swift -o /tmp/master
//   /tmp/master assets/coca-sans-bulles.m4a -16

import Foundation
import AVFoundation

let sr = 48_000.0
let block: AVAudioFrameCount = 512
let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

// --- LUFS intégré (BS.1770 / EBU R128), mètre validé par proofs/bounce_lufs.swift ---
func biquad(_ x: [Float], _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for n in 0..<x.count {
        let xn = Double(x[n]); let yn = b0*xn + b1*x1 + b2*x2 - a1*y1 - a2*y2
        y[n] = Float(yn); x2 = x1; x1 = xn; y2 = y1; y1 = yn
    }
    return y
}
func kWeight(_ x: [Float]) -> [Float] {
    let s1 = biquad(x, 1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
    return biquad(s1, 1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)
}
func lufsIntegrated(_ left: [Float], _ right: [Float]) -> Double {
    let kl = kWeight(left), kr = kWeight(right)
    let bs = Int(0.400 * sr), hop = Int(0.100 * sr)
    func ms(_ a: [Float], _ lo: Int, _ hi: Int) -> Double {
        var s = 0.0; for i in lo..<hi { s += Double(a[i]) * Double(a[i]) }; return s / Double(hi - lo)
    }
    var loud = [Double](), z = [Double](); var i = 0
    while i + bs <= kl.count {
        let zb = ms(kl, i, i + bs) + ms(kr, i, i + bs)
        if zb > 0 { z.append(zb); loud.append(-0.691 + 10 * log10(zb)) }
        i += hop
    }
    guard !z.isEmpty else { return -.infinity }
    var absIdx = [Int](); for k in 0..<loud.count where loud[k] >= -70.0 { absIdx.append(k) }
    guard !absIdx.isEmpty else { return -.infinity }
    let meanZabs = absIdx.map { z[$0] }.reduce(0, +) / Double(absIdx.count)
    let gammaR = -0.691 + 10 * log10(meanZabs) - 10.0
    let keep = absIdx.filter { loud[$0] >= gammaR }
    guard !keep.isEmpty else { return -.infinity }
    return -0.691 + 10 * log10(keep.map { z[$0] }.reduce(0, +) / Double(keep.count))
}

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: master <fichier> [cibleLUFS=-16]\n".data(using: .utf8)!)
    exit(2)
}
let inURL = URL(fileURLWithPath: CommandLine.arguments[1])
let target = CommandLine.arguments.count >= 3 ? Double(CommandLine.arguments[2]) ?? -16 : -16

// Rend le fichier complet à travers le graphe, avec un gain de piste, en offline 48k.
func render(_ url: URL, gainDb: Double) -> (l: [Float], r: [Float], seconds: Double) {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let tmix = AVAudioMixerNode()
    engine.attach(player); engine.attach(tmix)
    engine.connect(player, to: tmix, format: fmt)
    engine.connect(tmix, to: engine.mainMixerNode, format: fmt)
    tmix.outputVolume = Float(pow(10.0, gainDb / 20.0))

    let file = try! AVAudioFile(forReading: url)
    let durSec = Double(file.length) / file.fileFormat.sampleRate
    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
    try! engine.start()
    player.scheduleFile(file, at: nil, completionHandler: nil)
    player.play()

    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
    var left = [Float](), right = [Float]()
    let total = Int((durSec + 0.05) * sr)
    left.reserveCapacity(total); right.reserveCapacity(total)
    while left.count < total {
        guard (try? engine.renderOffline(block, to: out)) == .success else { break }
        let l = out.floatChannelData![0], r = out.floatChannelData![1]
        for i in 0..<Int(out.frameLength) { left.append(l[i]); right.append(r[i]) }
    }
    engine.stop()
    return (left, right, durSec)
}

func fadeInOut(_ s: inout [Float], ms: Double) {
    let n = Int(ms / 1000.0 * sr); guard n > 0, s.count > 2 * n else { return }
    for i in 0..<n {
        let g = Float(0.5 - 0.5 * cos(.pi * Double(i) / Double(n)))
        s[i] *= g; s[s.count - 1 - i] *= g
    }
}
func peakDBFS(_ l: [Float], _ r: [Float]) -> Double {
    var p: Float = 0; for v in l { p = max(p, abs(v)) }; for v in r { p = max(p, abs(v)) }
    return 20 * log10(Double(max(p, 1e-9)))
}
func write(_ l: [Float], _ r: [Float], to url: URL, aac: Bool) {
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count))!
    buf.frameLength = AVAudioFrameCount(l.count)
    for i in 0..<l.count { buf.floatChannelData![0][i] = l[i]; buf.floatChannelData![1][i] = r[i] }
    let settings: [String: Any] = aac
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
           AVEncoderBitRateKey: 256_000]
        : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
           AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false]
    let f = try! AVAudioFile(forWriting: url, settings: settings,
                             commonFormat: .pcmFormatFloat32, interleaved: false)
    try! f.write(from: buf)
}

print("=== Nuedeface — master réel : \(inURL.lastPathComponent) → cible \(Int(target)) LUFS ===\n")

// 1. render + mesure à l'unité
print("muter(gain=0 dB) → render → mesurer…")
let pass0 = render(inURL, gainDb: 0)
let lufs0 = lufsIntegrated(pass0.l, pass0.r)
let peak0 = peakDBFS(pass0.l, pass0.r)
print(String(format: "  durée            : %.1f s", pass0.seconds))
print(String(format: "  loudness mesuré  : %.2f LUFS", lufs0))
print(String(format: "  peak             : %.2f dBFS", peak0))

// 2. correction
let gainDb = target - lufs0
print(String(format: "\ncorriger → gain = cible - mesuré = %.2f dB → re-render → re-mesurer…", gainDb))
var pass1 = render(inURL, gainDb: gainDb)
let lufs1 = lufsIntegrated(pass1.l, pass1.r)
let peak1 = peakDBFS(pass1.l, pass1.r)
print(String(format: "  loudness obtenu  : %.2f LUFS  (erreur %+.2f LU)", lufs1, lufs1 - target))

// 3. clipping = trade-off nommé
let clips = peak1 >= 0.0
print(String(format: "  peak après gain  : %.2f dBFS  %@", peak1,
             clips ? "⚠️  CLIPPING — la cible sature ce master, il faudrait un limiteur (phase DSP)"
                   : "(pas de clipping)"))

// 4. fade in/out + export
fadeInOut(&pass1.l, ms: 30); fadeInOut(&pass1.r, ms: 30)
let stem = inURL.deletingPathExtension().lastPathComponent
let wav = inURL.deletingLastPathComponent().appendingPathComponent("\(stem)-mastered.wav")
let m4a = inURL.deletingLastPathComponent().appendingPathComponent("\(stem)-mastered.m4a")
write(pass1.l, pass1.r, to: wav, aac: false)
write(pass1.l, pass1.r, to: m4a, aac: true)
func kb(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int ?? 0) / 1024 }
print("\nexport :")
print("  \(wav.lastPathComponent)  (\(kb(wav)) Ko, WAV 24-bit)")
print("  \(m4a.lastPathComponent)  (\(kb(m4a)) Ko, AAC natif)")
