// Nuedeface — suite de tests assertés (zéro dépendance, swiftc only).
//
// Compilée AVEC le vrai cœur (cf. test.sh) : ces tests exercent le code de production, pas une copie.
// Chaque invariant DSP/modèle est vérifié ; le process sort en code ≠ 0 au premier échec → exploitable en CI.
//
//   ./test.sh            # build + run
//
// Couvre : true-peak (BS.1770), invariance LUFS (+6 dB ⇒ +6 LU), galbes de fade, interpolation
// d'automation (laneValue), détection de silence. Tout est offline et déterministe (aucun périphérique audio).

import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "  ok   " : "  FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !cond { failures += 1 }
}
func approx(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

print("• true-peak (BS.1770, sur-échantillonnage ×4 polyphase)")
do {
    // sinus 1 kHz plein-échelle (front propre) → gain exact 0 dBFS
    var lf = [Float](repeating: 0, count: 4800)
    for i in 0..<lf.count { lf[i] = Float(sin(2 * Double.pi * 1000 * Double(i) / 48000)) }
    check("gain 0 dBFS exact", approx(Engine.truePeakDB(lf, lf), 0, 0.3), String(format: "%.3f dBTP", Engine.truePeakDB(lf, lf)))
    // sinus fs/4 échantillonné sur les ±0.707 → pic-échantillon -3 dB mais vraie crête ≈ 0 dB
    var s = [Float](repeating: 0, count: 4096)
    for i in 0..<s.count { s[i] = Float(sin(Double.pi * Double(i) / 2.0 + Double.pi / 4.0)) }
    let tp = Engine.truePeakDB(s, s)
    check("récupère la crête inter-échantillon", tp > -1.0, String(format: "%.2f dBTP (pic-échantillon ≈ -3 dB)", tp))
    // silence → plancher
    check("silence → plancher", Engine.truePeakDB([0,0,0,0], [0,0,0,0]) < -100)
}

print("• LUFS intégré (invariance d'échelle)")
do {
    var x = [Float](repeating: 0, count: 96000)            // 2 s @ 48k
    for i in 0..<x.count { x[i] = 0.25 * Float(sin(2 * Double.pi * 1000 * Double(i) / 48000)) }
    let l1 = Engine.lufsIntegrated(x, x, sr: 48000)
    let x2 = x.map { $0 * 2 }                                // +6.02 dB
    let l2 = Engine.lufsIntegrated(x2, x2, sr: 48000)
    check("+6 dB ⇒ +6 LU", approx(l2 - l1, 6.02, 0.1), String(format: "Δ = %.3f LU", l2 - l1))
    check("LUFS fini sur signal réel", l1.isFinite, String(format: "%.2f LUFS", l1))
}

print("• galbes de fade")
do {
    check("linear(0.5)=0.5", approx(Engine.fadeGain(0.5, "linear"), 0.5, 1e-9))
    check("exp(0.5)=0.25",   approx(Engine.fadeGain(0.5, "exp"), 0.25, 1e-9))
    check("scurve(0.5)=0.5", approx(Engine.fadeGain(0.5, "scurve"), 0.5, 1e-9))
    check("bornes 0→0, 1→1", Engine.fadeGain(0, "scurve") == 0 && approx(Engine.fadeGain(1, "exp"), 1, 1e-9))
}

print("• automation : interpolation de lane (laneValue)")
do {
    let lane = Document.Lane(on: true, points: [
        Document.AutoPoint(id: "a", t: 0, v: 0, curve: "linear"),
        Document.AutoPoint(id: "b", t: 100, v: 1, curve: "linear"),
        Document.AutoPoint(id: "c", t: 200, v: 1, curve: "hold"),
    ])
    check("interpolation linéaire au milieu", approx(Document.laneValue(lane, atSample: 50) ?? -1, 0.5, 1e-9))
    check("hold avant le 1er point", approx(Document.laneValue(lane, atSample: -10) ?? -1, 0, 1e-9))
    check("hold après le dernier", approx(Document.laneValue(lane, atSample: 999) ?? -1, 1, 1e-9))
    let off = Document.Lane(on: false, points: lane.points)
    check("lane désactivée → nil", Document.laneValue(off, atSample: 50) == nil)
    // bezier = smootherstep (S-curve) : symétrique (milieu = 0.5) mais ease-in marqué (au quart, bien < linéaire)
    let bz = Document.Lane(on: true, points: [
        Document.AutoPoint(id: "a", t: 0, v: 0, curve: "bezier"),
        Document.AutoPoint(id: "b", t: 100, v: 1, curve: "linear"),
    ])
    check("bezier: milieu = 0.5 (symétrique)", approx(Document.laneValue(bz, atSample: 50) ?? -1, 0.5, 1e-9))
    check("bezier: ease-in au quart (≪ linéaire 0.25)", (Document.laneValue(bz, atSample: 25) ?? 1) < 0.15,
          String(format: "%.4f", Document.laneValue(bz, atSample: 25) ?? -1))
}

print("• détection de silence")
do {
    let sr = 48000
    var sig = [Float](repeating: 0, count: 3 * sr)          // [bruit | silence | bruit], 1 s chacun
    for i in 0..<sr { sig[i] = 0.5; sig[2 * sr + i] = 0.5 }
    let regions = Engine.detectSilence(sig, sig, thresholdDb: -40, minDurSamples: sr / 2)
    check("trouve exactement 1 région de silence", regions.count == 1, "trouvées: \(regions.count)")
    if let r = regions.first {
        check("région ≈ au milieu [1s, 2s]", abs(r.start - sr) < sr / 5 && abs(r.end - 2 * sr) < sr / 5,
              "[\(r.start), \(r.end)]")
    }
}

print(failures == 0 ? "\n✅ tous les tests passent" : "\n❌ \(failures) test(s) en échec")
exit(failures == 0 ? 0 : 1)
