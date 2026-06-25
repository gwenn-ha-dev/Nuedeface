// Nuedeface — contrôles custom « à l'ancienne » (fader vertical, knob de pan) + maths EQ.
//
// Dessin SwiftUI/Canvas. La courbe d'EQ est la VRAIE réponse du biquad peaking (RBJ cookbook),
// avec le même Q que l'AVAudioUnitEQ du moteur (bandwidth = 1 octave) → ce que l'œil voit = ce
// que l'oreille aura. C'est le grief d'origine du concept : un EQ enfin lisible.

import SwiftUI
import AppKit

// MARK: - Fader vertical

struct VFader: View {
    @Binding var gain: Double            // linéaire (valeur du modèle)
    var minDb: Double = -60
    var maxDb: Double = 12

    // mapping course<->dB : l'unité (0 dB) tombe vers le haut, comme une vraie tranche de console.
    private func pos(_ g: Double) -> Double {
        guard g > 0 else { return 0 }
        return min(1, max(0, (20 * log10(g) - minDb) / (maxDb - minDb)))
    }
    private func gainAt(_ p: Double) -> Double {
        p <= 0.001 ? 0 : pow(10, (minDb + p * (maxDb - minDb)) / 20)
    }
    private var unityFrac: Double { (0 - minDb) / (maxDb - minDb) }   // repère 0 dB
    @State private var grabbed = false

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let frac = pos(gain)
            let knobY = (1 - frac) * (h - 22) + 11
            ZStack(alignment: .top) {
                Capsule().fill(Palette.well)
                    .frame(width: 5).frame(maxWidth: .infinity)
                Capsule().fill(LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 5, height: max(0, h - knobY)).frame(maxWidth: .infinity)
                    .offset(y: knobY)
                    .shadow(color: Palette.accent.opacity(grabbed ? 0.7 : 0), radius: 4)
                // repère 0 dB (unité)
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: 16, height: 1)
                    .position(x: w / 2, y: (1 - unityFrac) * (h - 22) + 11)
                // cap de fader « métal », reflet spéculaire en haut
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4)))
                    .overlay(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.6)).frame(height: 2).padding(.horizontal, 3).offset(y: -5))  // reflet
                    .overlay(Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1))   // rainure centrale
                    .frame(width: w * 0.82, height: 18)
                    .position(x: w / 2, y: knobY)
                    .shadow(color: .black.opacity(0.5), radius: grabbed ? 3 : 1.5, y: 1)
                    .scaleEffect(grabbed ? 1.06 : 1, anchor: .center)
            }
            .animation(Ballistics.fast, value: grabbed)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    grabbed = true
                    let f = 1 - Double((g.location.y - 11) / (h - 22))
                    gain = gainAt(min(1, max(0, f)))
                }
                .onEnded { _ in grabbed = false })
            .onTapGesture(count: 2) { gain = 1 }   // double-clic = retour à 0 dB (unité)
        }
        .frame(width: 34)
        .frame(minHeight: 110, maxHeight: .infinity)   // prend l'espace vertical dispo
    }
}

// MARK: - Knob (pan)

struct Dial: View {
    @Binding var value: Double          // dans range
    var range: ClosedRange<Double>
    var size: CGFloat = 38
    @State private var startFrac: Double?   // valeur au début du drag (sinon ça part en vrille)

    private var grabbed: Bool { startFrac != nil }
    private var frac: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var angle: Angle { .degrees(-135 + frac * 270) }   // -135°..+135°
    private let sweep = 0.75                                    // 270° / 360°

    var body: some View {
        ZStack {
            // arc de COURSE (rail) — gap de 90° en bas
            Circle().trim(from: 0, to: sweep)
                .stroke(Palette.well, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            // arc de VALEUR (accent) qui se remplit — c'est lui qui « dit » la valeur d'un coup d'œil
            Circle().trim(from: 0, to: sweep * frac)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: Palette.accent.opacity(grabbed ? 0.8 : 0.35), radius: grabbed ? 5 : 2)
            // corps du bouton, matériel (éclairé d'en haut)
            Circle().fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.15)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).blur(radius: 0.5).padding(1))
                .padding(size * 0.18)
            // index
            Capsule().fill(grabbed ? Color.white : Palette.accent)
                .frame(width: 3, height: size * 0.26)
                .offset(y: -size * 0.24)
                .rotationEffect(angle)
        }
        .frame(width: size, height: size)
        .scaleEffect(grabbed ? 1.07 : 1)
        .animation(Ballistics.fast, value: grabbed)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let base = startFrac ?? frac
                if startFrac == nil { startFrac = base }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 6.0 : 1.0          // shift = réglage fin (×6 plus lent)
                let f = min(1, max(0, base + Double(-g.translation.height) / (200 * fine)))   // plage complète ~200px
                value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            }
            .onEnded { _ in startFrac = nil })
        .onTapGesture(count: 2) { value = (range.lowerBound + range.upperBound) / 2 }   // double-clic = centre
    }
}

// MARK: - Réponse EQ (biquad peaking, RBJ)

enum EQBandKind { case lowShelf, peak, highShelf }
/// Une bande d'EQ évaluée (type + fréquence + gain + largeur en octaves) — pour la courbe et les nœuds.
/// `bw` (octaves) ne joue que sur les bandes peak (les shelves de l'AVAudioUnitEQ ont une pente fixe).
struct EQBandVal { var kind: EQBandKind; var freq: Double; var gain: Double; var bw: Double = 1.0 }

enum EQResponse {
    /// |H(e^jw)| en dB d'un biquad (coeffs RBJ) à la fréquence f.
    static func biquadDB(_ f: Double, _ b0: Double, _ b1: Double, _ b2: Double,
                         _ a0: Double, _ a1: Double, _ a2: Double, _ sr: Double) -> Double {
        let w = 2 * .pi * f / sr
        let cosw = cos(w), cos2w = cos(2 * w), sinw = sin(w), sin2w = sin(2 * w)
        let numRe = b0 + b1 * cosw + b2 * cos2w, numIm = -(b1 * sinw + b2 * sin2w)
        let denRe = a0 + a1 * cosw + a2 * cos2w, denIm = -(a1 * sinw + a2 * sin2w)
        let mag = sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        return 20 * log10(max(mag, 1e-9))
    }
    static func peakingDB(_ f: Double, _ f0: Double, _ gainDB: Double, _ q: Double, _ sr: Double) -> Double {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / sr, alpha = sin(w0) / (2 * q), cw = cos(w0)
        return biquadDB(f, 1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A, sr)
    }
    static func lowShelfDB(_ f: Double, _ f0: Double, _ gainDB: Double, _ sr: Double) -> Double {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / sr, cw = cos(w0), ts = 2 * sqrt(A) * (sin(w0) / 2 * sqrt(2))
        return biquadDB(f, A * ((A + 1) - (A - 1) * cw + ts), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - ts),
                        (A + 1) + (A - 1) * cw + ts, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - ts, sr)
    }
    static func highShelfDB(_ f: Double, _ f0: Double, _ gainDB: Double, _ sr: Double) -> Double {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f0 / sr, cw = cos(w0), ts = 2 * sqrt(A) * (sin(w0) / 2 * sqrt(2))
        return biquadDB(f, A * ((A + 1) + (A - 1) * cw + ts), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - ts),
                        (A + 1) - (A - 1) * cw + ts, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - ts, sr)
    }
    static func bandDB(_ f: Double, _ b: EQBandVal, _ sr: Double) -> Double {
        switch b.kind {
        case .lowShelf:  return lowShelfDB(f, b.freq, b.gain, sr)
        case .peak:      return peakingDB(f, b.freq, b.gain, qFromBW(b.bw), sr)
        case .highShelf: return highShelfDB(f, b.freq, b.gain, sr)
        }
    }
    /// somme des bandes (les filtres en série s'additionnent en dB) à la fréquence f.
    static func totalDB(_ f: Double, _ bands: [EQBandVal], _ sr: Double) -> Double {
        bands.reduce(0) { $0 + bandDB(f, $1, sr) }
    }
    /// Q d'une bande peak à partir de sa largeur en octaves (la convention `bandwidth` de l'AVAudioUnitEQ).
    static func qFromBW(_ bw: Double) -> Double {
        let b = max(0.05, bw); let p = pow(2.0, b)
        return sqrt(p) / (p - 1)
    }
    /// Q correspondant à l'AVAudioUnitEQ paramétrique du moteur (bandwidth = 1 octave).
    static let engineQ: Double = sqrt(2)   // BW=1 → Q = sqrt(2^BW)/(2^BW-1) ≈ 1.414
}

/// Libellé éditable en place : double-clic (ou menu « Renommer ») → champ texte ; Entrée/perte de focus = commit.
/// Mutualise le renommage piste/bus (touch-first : aussi déclenchable depuis le menu long-press du parent).
struct EditableLabel: View {
    let text: String
    @Binding var editing: Bool
    var font: Font = .system(size: 9, weight: .medium)
    var align: TextAlignment = .center
    var onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(font)
                    .multilineTextAlignment(align).foregroundColor(Palette.text)
                    .focused($focused)
                    .onAppear { draft = text; focused = true }
                    .onSubmit { commit() }
                    .onChange(of: focused) { f in if !f { commit() } }
            } else {
                Text(text).font(font).lineLimit(1).truncationMode(.tail)
            }
        }
    }
    private func commit() { onCommit(draft); editing = false }
}

/// Valeur numérique éditable en place : affiche `display(value)` (avec unité) ; double-clic → champ de saisie
/// prérempli par `toField(value)` (nombre nu). Entrée/perte de focus = parse via `fromField`, clamp à `range`,
/// puis `commit`. Donne la PRÉCISION clavier aux faders/knobs sans toucher au geste de réglage à la souris.
struct EditableNumber: View {
    let value: Double
    var range: ClosedRange<Double>? = nil
    var display: (Double) -> String         // texte affiché (avec unité)
    var toField: (Double) -> String         // valeur éditable (nombre nu, sans unité)
    var fromField: (String) -> Double?      // parse texte → valeur modèle (clampée ensuite à `range`)
    var commit: (Double) -> Void
    var font: Font = .system(size: 8)
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(font).monospacedDigit()
                    .multilineTextAlignment(.center).foregroundColor(Palette.text)
                    .frame(width: 46)
                    .focused($focused)
                    .onAppear { draft = toField(value); focused = true }
                    .onSubmit { commitDraft() }
                    .onChange(of: focused) { f in if !f { commitDraft() } }
            } else {
                Text(display(value)).font(font).monospacedDigit().foregroundColor(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = true }
                    .help("double-clic : saisir une valeur au clavier")
            }
        }
    }
    private func commitDraft() {
        // virgule décimale tolérée (clavier FR) ; valeur hors-bornes ramenée dans [min, max].
        if var v = fromField(draft.replacingOccurrences(of: ",", with: ".")), v.isFinite {
            if let r = range { v = min(r.upperBound, max(r.lowerBound, v)) }
            commit(v)
        }
        editing = false
    }
}

// MARK: - mètres « wow » (GR mesurée, loudness pro, spectrogramme)

/// Mètre de RÉDUCTION DE GAIN d'un insert dynamique — barre horizontale 0→−24 dB. La GR est MESURÉE
/// (différence RMS pré/post le nœud) faute d'API Apple : honnête, on l'annonce « GR mesurée ».
struct GRMeterView: View {
    var gr: Double          // dB ≥ 0 (atténuation)
    var body: some View {
        HStack(spacing: 4) {
            Text("GR").font(Typo.micro).foregroundColor(.secondary)
            GeometryReader { geo in
                let frac = min(1, max(0, gr / 24))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.well)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LinearGradient(colors: Palette.reduction, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(frac))
                }
            }.frame(height: 7)
            Text(gr > 0.1 ? String(format: "-%.1f", gr) : "0").font(Typo.micro).monospacedDigit().foregroundColor(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
        .help("réduction de gain mesurée (pré/post insert) — live")
    }
}

/// Radar loudness EBU R128 : barres momentary + short-term (live), true-peak + LRA + integrated (à la demande).
struct ProLoudnessMeter: View {
    var momentary: Double, shortTerm: Double, truePeak: Double
    var integrated: Double = -120, lra: Double = 0
    private func frac(_ v: Double) -> CGFloat { CGFloat(min(1, max(0, (v + 40) / 40))) }   // -40..0 LUFS

    private func bar(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Typo.micro).foregroundColor(.secondary).frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Palette.well)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(LinearGradient(colors: Palette.meter, startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * frac(v))
                }
            }.frame(height: 5)
            Text(v.isFinite && v > -120 ? String(format: "%.1f", v) : "—").font(Typo.micro).monospacedDigit()
                .foregroundColor(.secondary).frame(width: 30, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            bar("M", momentary); bar("S", shortTerm)
            HStack(spacing: 6) {
                Text("TP").font(Typo.micro).foregroundColor(.secondary)
                Text(truePeak.isFinite && truePeak > -120 ? String(format: "%.1f", truePeak) : "—")
                    .font(Typo.micro).monospacedDigit().foregroundColor(truePeak > -1 ? Palette.clip : .secondary)
                Text("LRA").font(Typo.micro).foregroundColor(.secondary)
                Text(lra > 0 ? String(format: "%.1f", lra) : "—").font(Typo.micro).monospacedDigit().foregroundColor(.secondary)
                Spacer()
                Text("I").font(Typo.micro).foregroundColor(.secondary)
                Text(integrated.isFinite && integrated > -120 ? String(format: "%.1f", integrated) : "—")
                    .font(Typo.micro).monospacedDigit().foregroundColor(.secondary)
            }
        }
    }
}

/// Spectrogramme live : pile de trames FFT (temps × fréq) en heatmap (sombre→accent). Repère sifflantes/ronflette.
struct SpectrogramView: View {
    let frames: [[Float]]       // chaque trame = bins log (dB)
    var body: some View {
        Canvas { ctx, size in
            guard !frames.isEmpty, let bins = frames.first?.count, bins > 0 else { return }
            let w = size.width, h = size.height
            let colW = w / CGFloat(max(1, frames.count))
            let rowH = h / CGFloat(bins)
            for (t, frame) in frames.enumerated() {
                let x = CGFloat(t) * colW
                for b in 0..<min(bins, frame.count) {
                    let mag = max(0.0, min(1.0, (Double(frame[b]) + 90) / 90))
                    guard mag > 0.04 else { continue }
                    let y = h - CGFloat(b + 1) * rowH      // grave en bas, aigu en haut
                    ctx.fill(Path(CGRect(x: x, y: y, width: colW + 0.5, height: rowH + 0.5)),
                             with: .color(Palette.accent.opacity(mag)))
                }
            }
        }
        .background(Palette.bg)
        .clipShape(RoundedRectangle(cornerRadius: Dims.radiusS))
    }
}

/// VU de crête vertical à BALLISTIQUE (attaque rapide / release lente) + maintien de crête qui retombe.
struct BallisticVU: View {
    var level: Double            // crête linéaire 0..1
    @State private var shown = 0.0
    @State private var hold = 0.0
    private static func fr(_ lin: Double) -> CGFloat {
        let db = lin > 0.0001 ? 20 * log10(lin) : -120
        return CGFloat(min(1, max(0, (db + 60) / 60)))
    }
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let f = Self.fr(shown)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.well)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: Palette.meter, startPoint: .bottom, endPoint: .top))
                    .frame(height: h * f)
                    .shadow(color: Palette.clip.opacity(f > 0.85 ? Double((f - 0.85) / 0.15) * 0.8 : 0), radius: 4)  // glow quand ça tape le rouge
                Rectangle().fill(Color.white.opacity(0.85)).frame(height: 1)            // maintien de crête
                    .padding(.bottom, h * Self.fr(hold))
            }
        }
        .frame(width: 5)
        .onChange(of: level) { v in
            shown = Ballistics.smoothed(shown, towards: v)
            if v >= hold { hold = v } else { hold = max(v, hold - 0.01) }   // la crête retombe lentement
        }
    }
}

/// Courbe d'EQ multi-bandes (axe log 20 Hz–20 kHz, ±24 dB) : somme des bandes.
struct EQCurve: View {
    var bands: [EQBandVal]
    var bypass: Bool
    var sr: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let fLo = 20.0, fHi = 20_000.0, dbMax = 24.0
            func x(_ f: Double) -> Double { (log10(f) - log10(fLo)) / (log10(fHi) - log10(fLo)) * w }
            func y(_ db: Double) -> Double { h / 2 - db / dbMax * (h / 2 - 4) }

            for f in [100.0, 1_000.0, 10_000.0] {
                var g = Path(); g.move(to: CGPoint(x: x(f), y: 0)); g.addLine(to: CGPoint(x: x(f), y: h))
                ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            for db in [12.0, -12.0] {
                var g = Path(); g.move(to: CGPoint(x: 0, y: y(db))); g.addLine(to: CGPoint(x: w, y: y(db)))
                ctx.stroke(g, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: h / 2)); zero.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(zero, with: .color(.white.opacity(0.15)), lineWidth: 1)

            var p = Path()
            let n = 120
            for i in 0...n {
                let f = pow(10, log10(fLo) + Double(i) / Double(n) * (log10(fHi) - log10(fLo)))
                let db = bypass ? 0 : EQResponse.totalDB(f, bands, sr)
                let pt = CGPoint(x: x(f), y: y(max(-dbMax, min(dbMax, db))))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(bypass ? .gray : .accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
