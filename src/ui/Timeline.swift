// Nuedeface — la timeline (coquille honnête).
//
// Ce qui est RÉEL ici : la waveform de la source réellement posée sur chaque piste (décodée
// du fichier importé) et l'enveloppe de fade in/out (tirée du modèle, fadeIn/fadeOut en s).
// Ce qui est STUBBÉ (assumé) : clips multiples, positions/déplacements, transport/playhead mobile
// — tout ça attend les verbes structurels (piste 3) + le moteur live (piste 2). On ne dessine
// aucune donnée inventée : une piste sans fichier affiche « source tone », pas un faux clip.

import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - cache de waveforms (décodage off-main, downsample en buckets)

final class WaveformCache: ObservableObject {
    struct WF { var peaks: [Float]; var duration: Double }
    @Published private(set) var byPath: [String: WF] = [:]
    private var loading = Set<String>()

    func waveform(for path: String) -> WF? { byPath[path] }

    func ensure(_ path: String) {
        if byPath[path] != nil || loading.contains(path) { return }
        loading.insert(path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let wf = WaveformCache.decode(path)
            DispatchQueue.main.async {
                self?.loading.remove(path)
                if let wf { self?.byPath[path] = wf }
            }
        }
    }

    private static func decode(_ path: String, buckets: Int = 2000) -> WF? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              (try? file.read(into: buf)) != nil, let chans = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
        let per = max(1, n / buckets)
        var peaks = [Float](); peaks.reserveCapacity(n / per + 1)
        var i = 0
        while i < n {
            var pk: Float = 0
            let end = min(i + per, n)
            for c in 0..<ch {
                let p = chans[c]
                for s in i..<end { let a = abs(p[s]); if a > pk { pk = a } }
            }
            peaks.append(pk); i = end
        }
        return WF(peaks: peaks, duration: Double(n) / fmt.sampleRate)
    }
}

// MARK: - vue timeline

/// État de VUE de la timeline (zoom px/s + défilement), DÉTENU par le workspace → survit au démontage de la
/// timeline quand la zone Waves se replie (sinon le zoom/scroll se réinitialisait à chaque bascule de focus).
final class TimelineViewState: ObservableObject {
    @Published var pps: CGFloat = 30
    @Published var offsetX: CGFloat = 0
}

struct TimelineView: View {
    @EnvironmentObject var store: SocketClient
    // cache INJECTÉ (détenu par le workspace) : il survit au démontage de la timeline quand la zone se replie
    // → plus de re-décodage des waveforms à chaque bascule de focus (la cause du lag du 1er jet).
    @ObservedObject var cache: WaveformCache
    @ObservedObject var view: TimelineViewState
    // pps/offsetX vivent dans `view` (persistants) ; on les expose en propriétés calculées pour ne rien changer
    // au reste de la vue (set non-mutant → écrit dans l'ObservableObject).
    private var pps: CGFloat { get { view.pps } nonmutating set { view.pps = newValue } }
    private var offsetX: CGFloat { get { view.offsetX } nonmutating set { view.offsetX = newValue } }

    private let headerW: CGFloat = 140
    private let rulerH: CGFloat = 24
    private let laneH: CGFloat = 84
    private let autoH: CGFloat = 42
    private let masterH: CGFloat = 60        // lane master read-only en bas
    // zoom TEMPS uniquement (px/seconde). Indispensable au travail fin des fades/cuts ; à 30 px/s un
    // fade de 20 ms = 0,6 px. Pas de zoom d'amplitude (il fausserait la lecture de puissance).
    @State private var zoomBase: CGFloat?
    @State private var panBase: CGFloat?
    @State private var focalX: CGFloat?             // dernière position curseur = point focal du zoom
    @State private var viewportW: CGFloat = 600      // largeur visible de la zone temporelle
    @State private var lastClipCount = 0             // pour caler la waveform sur la fenêtre à chaque import
    private let ppsMin: CGFloat = 6
    private let ppsMax: CGFloat = 600

    private var clipCount: Int { store.tracks.reduce(0) { $0 + $1.clips.count } }

    private var maxOff: CGFloat { max(0, contentW - viewportW) }
    private var clampedOff: CGFloat { min(max(0, offsetX), maxOff) }

    /// zoom relatif (boutons/pincement) ancré sur le curseur, ou le centre à défaut.
    private func zoom(_ factor: CGFloat) { applyZoom(pps * factor, anchor: focalX ?? viewportW / 2) }
    /// zoom absolu vers `target` px/s en gardant immobile le temps sous `anchor` (x en px viewport).
    private func applyZoom(_ target: CGFloat, anchor: CGFloat) {
        let clamped = min(ppsMax, max(ppsMin, target))
        guard clamped != pps else { return }
        let tFocal = Double(clampedOff + anchor) / Double(pps)    // temps sous le point focal AVANT
        pps = clamped                                            // contentW se recalcule sur le nouveau pps
        offsetX = min(max(0, contentW - viewportW), max(0, CGFloat(tFocal) * clamped - anchor))
    }

    /// Cale le zoom pour que TOUT le contenu (jusqu'à maxDuration) tienne dans la largeur visible. Appelé à
    /// l'import (la waveform se met à l'échelle de la fenêtre) et au bouton « ajuster ».
    private func fitToWindow() {
        guard viewportW > 60, maxDuration > 0.1 else { return }
        pps = min(ppsMax, max(ppsMin, (viewportW - 40) / CGFloat(maxDuration)))
        offsetX = 0
    }

    private func autoOn(_ t: TrackVM) -> Bool { store.automation[store.autoFullPath(t.id)]?.on ?? false }

    private var maxDuration: Double {
        let ends = store.tracks.flatMap { $0.clips.map { $0.start + $0.duration } }
        return max(ends.max() ?? 8, 8)
    }
    // largeur de la timeline : AU MOINS la fenêtre visible (sinon, projet court/vide → la timeline « s'arrête »
    // au bout du contenu et laisse du vide à droite) ; sinon la durée du contenu.
    private var contentW: CGFloat { max(viewportW, CGFloat(maxDuration) * pps + 40) }

    var body: some View {
        VStack(spacing: 0) {
            banner
            HStack(alignment: .top, spacing: 0) {       // .top : la colonne d'entêtes s'aligne sur les lanes (sinon centrée)
                // colonne d'entêtes fixe
                VStack(spacing: 0) {
                    Palette.rail.frame(height: rulerH)
                    ForEach(store.tracks) { t in
                        TrackHeaderCell(track: t, laneH: laneH).frame(height: laneH)
                        if autoOn(t) {
                            HStack(spacing: 4) { Image(systemName: "function").font(.system(size: 8)); Text(store.autoName(t.id, store.autoRel(t.id))).lineLimit(1) }
                                .font(.system(size: 8)).foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                                .frame(height: autoH).background(Palette.panel)
                        }
                        Divider()
                    }
                    // entête de la lane MASTER (destination = en bas, comme à droite dans la console)
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                        Text("MASTER").font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button { store.fetchMasterEnvelope() } label: {     // rendu complet offline (sans jouer)
                            Image(systemName: store.masterRendering ? "hourglass" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain).disabled(store.masterRendering)
                        .help("rendu complet du mix master (offline, à la demande)")
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    .frame(height: masterH).background(Palette.surface)
                }
                .frame(width: headerW)

                // zone temporelle : scroller maison à offset piloté (zoom focal sur le curseur + pan)
                GeometryReader { geo in
                    let vw = geo.size.width
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Ruler(seconds: maxDuration, pps: pps, onSeek: { store.seek(to: $0) }, onLoop: { store.setLoopRange($0, $1) })
                                .frame(width: contentW, height: rulerH)
                            ForEach(store.tracks) { t in
                                Lane(track: t, pps: pps, height: laneH, cache: cache, assets: store.assets)
                                    .frame(width: contentW, height: laneH)
                                if autoOn(t) {
                                    AutomationLane(path: store.autoFullPath(t.id),
                                                   lo: store.autoRange(t.id, store.autoRel(t.id)).lo,
                                                   hi: store.autoRange(t.id, store.autoRel(t.id)).hi,
                                                   unit: store.autoRange(t.id, store.autoRel(t.id)).unit,
                                                   pps: pps, height: autoH, contentW: contentW)
                                        .frame(width: contentW, height: autoH)
                                }
                                Divider()
                            }
                            // lane MASTER read-only : le mix, dessiné en live par la télémétrie (crêtes + clips rouges)
                            MasterLane(wave: store.masterWave, bucket: store.masterWaveBucket, pps: pps,
                                       offline: store.masterOffline, offlineBucket: store.masterOfflineBucket)
                                .frame(width: contentW, height: masterH)
                        }
                        .frame(width: contentW, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            // zone de boucle : bande accent translucide [loopStart, loopEnd] (sous le playhead)
                            if store.loopOn && store.loopEnd > store.loopStart {
                                Rectangle().fill(Palette.accent.opacity(0.10))
                                    .overlay(Rectangle().stroke(Palette.accent.opacity(0.5), lineWidth: 1))
                                    .frame(width: max(1, CGFloat(store.loopEnd - store.loopStart) * pps))
                                    .frame(maxHeight: .infinity)
                                    .offset(x: CGFloat(store.loopStart) * pps)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            // playhead mobile (télémétrie live) — trait fin + halo doux (vivant pendant la lecture)
                            Rectangle().fill(Color.red).frame(width: 1.5)
                                .shadow(color: Color.red.opacity(store.playing ? 0.9 : 0.3), radius: store.playing ? 5 : 1.5)
                                .overlay(alignment: .top) {
                                    Circle().fill(Color.red).frame(width: 7, height: 7)
                                        .shadow(color: .red.opacity(0.9), radius: 4).offset(y: -2)
                                }
                                .offset(x: CGFloat(store.playhead) * pps)
                                .animation(.linear(duration: 0.033), value: store.playhead)
                                .allowsHitTesting(false)
                        }
                        .offset(x: -clampedOff)

                        if maxOff > 0 {
                            ScrollThumb(off: clampedOff, maxOff: maxOff, viewportW: vw, contentW: contentW) {
                                offsetX = min(maxOff, max(0, $0))
                            }
                        }
                    }
                    .frame(width: vw, height: geo.size.height, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { focalX = p.x } else { focalX = nil }
                    }
                    .onAppear { viewportW = vw }
                    .onChange(of: vw) { _, n in viewportW = n }
                    // pan : drag sur le fond (clips/ruler/auto captent leur propre geste en priorité)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { g in
                            let b = panBase ?? clampedOff; if panBase == nil { panBase = b }
                            offsetX = min(maxOff, max(0, b - g.translation.width))
                        }
                        .onEnded { _ in panBase = nil })
                    // pincement = zoom temps, ancré sur le curseur (point focal)
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { scale in
                            let b = zoomBase ?? pps; if zoomBase == nil { zoomBase = b }
                            applyZoom(b * scale, anchor: focalX ?? vw / 2)
                        }
                        .onEnded { _ in zoomBase = nil })
                }
            }
        }
        .background(Palette.panel)
        .onAppear { ensureWaveforms(); lastClipCount = clipCount }
        .onChange(of: store.tracks.flatMap { $0.clips.map { $0.asset } }.joined()) { ensureWaveforms() }
        .onChange(of: clipCount) { _, n in
            if n > lastClipCount { fitToWindow() }   // un clip ajouté (import) → cale la waveform sur la fenêtre
            lastClipCount = n
        }
    }

    private func ensureWaveforms() {
        for t in store.tracks { for c in t.clips { if let p = store.assets[c.asset]?.path { cache.ensure(p) } } }
    }

    /// le clip actuellement sélectionné (avec sa piste), s'il existe.
    private var selectedClip: (track: TrackVM, clip: ClipVM)? {
        guard let id = store.selectedClipId else { return nil }
        for t in store.tracks { if let c = t.clips.first(where: { $0.id == id }) { return (t, c) } }
        return nil
    }

    private var banner: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
            if let sel = selectedClip {
                clipActions(sel.clip)
            } else {
                Text("Clic = sélectionner · glisser = déplacer · pincer ou ± = zoom temps")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 3) {
                Button { zoom(1 / 1.5) } label: {
                    Image(systemName: "minus.magnifyingglass").frame(width: 30, height: 24).contentShape(Rectangle())
                }
                Button { zoom(1.5) } label: {
                    Image(systemName: "plus.magnifyingglass").frame(width: 30, height: 24).contentShape(Rectangle())
                }
                Button { fitToWindow() } label: {
                    Image(systemName: "arrow.left.and.right.square").frame(width: 30, height: 24).contentShape(Rectangle())
                }.help("ajuster : cale tout le contenu sur la largeur de la fenêtre")
                Button { applyZoom(30, anchor: focalX ?? viewportW / 2) } label: {
                    Text("100%").font(.system(size: 9)).frame(height: 24).padding(.horizontal, 4).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
            Text("\(Int(pps)) px/s").font(.system(size: 9)).foregroundColor(.secondary).monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Palette.surface2)
    }

    /// actions sur le clip sélectionné : couper au playhead (S), dupliquer (⌘D), supprimer (⌫).
    @ViewBuilder private func clipActions(_ c: ClipVM) -> some View {
        let canSplit = store.playhead > c.start + 0.001 && store.playhead < c.start + c.duration - 0.001
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor).font(.system(size: 10))
            Button { store.splitClip(clipId: c.id, at: store.playhead) } label: {
                Label("couper", systemImage: "scissors")
            }.disabled(!canSplit).keyboardShortcut("s", modifiers: []).help("couper au playhead (S)")
            Button { store.duplicateClip(clipId: c.id) } label: {
                Label("dupliquer", systemImage: "plus.square.on.square")
            }.keyboardShortcut("d", modifiers: [.command])
            Button(role: .destructive) { store.removeClip(clipId: c.id) } label: {
                Label("supprimer", systemImage: "trash")
            }.keyboardShortcut(.delete, modifiers: [])
            Divider().frame(height: 14)
            fadeShapePicker(c)                        // galbe des fades (in+out) du clip
        }
        .font(.system(size: 10)).buttonStyle(.bordered).controlSize(.small).labelStyle(.titleAndIcon)
    }

    /// galbe des fades du clip sélectionné : linéaire / exponentiel / S (raised-cosine). Une seule métaphore (boutons).
    @ViewBuilder private func fadeShapePicker(_ c: ClipVM) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "alternatingcurrent").font(.system(size: 9)).foregroundColor(.secondary)
            ForEach([(l: "lin", v: "linear"), (l: "exp", v: "exp"), (l: "S", v: "scurve")], id: \.v) { opt in
                Button(opt.l) { store.setFadeShape(clipId: c.id, opt.v) }
                    .tint(c.fadeShape == opt.v ? .accentColor : .gray)
            }
        }
        .help("galbe des fondus du clip (in + out)")
    }
}

/// Barre de défilement horizontale du scroller maison (le swipe deux-doigts natif n'existe plus ici).
struct ScrollThumb: View {
    let off: CGFloat
    let maxOff: CGFloat
    let viewportW: CGFloat
    let contentW: CGFloat
    var onScroll: (CGFloat) -> Void
    @State private var base: CGFloat?

    var body: some View {
        let visibleFrac = min(1, viewportW / max(1, contentW))
        let thumbW = max(36, viewportW * visibleFrac)
        let travel = max(1, viewportW - thumbW)
        let thumbX = maxOff > 0 ? off / maxOff * travel : 0
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(base == nil ? 0.22 : 0.4))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.1)))
            .frame(width: thumbW, height: 8)
            .offset(x: thumbX)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let b = base ?? off; if base == nil { base = b }
                    onScroll(b + g.translation.width / travel * maxOff)
                }
                .onEnded { _ in base = nil })
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 2)
    }
}

struct TrackHeaderCell: View {
    let track: TrackVM
    var laneH: CGFloat = 84
    @EnvironmentObject var store: SocketClient
    @State private var dragY: CGFloat = 0
    @State private var renaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EditableLabel(text: track.name, editing: $renaming, font: .system(size: 12, weight: .semibold), align: .leading) { store.renameTrack(track.id, $0) }
                .onTapGesture(count: 2) { renaming = true }
            HStack(spacing: 6) {
                if track.mute { Text("M").font(.system(size: 9, weight: .bold)).foregroundColor(.red) }
                Text(track.clips.isEmpty ? "vide" : "\(track.clips.count) clip\(track.clips.count > 1 ? "s" : "")")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button("+ clip…") { pickFile() }
                    .buttonStyle(.bordered).controlSize(.small).font(.system(size: 10))
                Spacer()
                autoMenu
                Toggle("", isOn: Binding(
                    get: { store.automation[store.autoFullPath(track.id)]?.on ?? false },
                    set: { store.enableAuto(store.autoFullPath(track.id), $0) }))
                    .toggleStyle(.checkbox).labelsHidden().font(.system(size: 9)).help("activer l'automation")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(store.selectedTrackId == track.id ? Palette.selection : Palette.header)
        .contentShape(Rectangle())
        .offset(y: dragY).zIndex(dragY != 0 ? 5 : 0)
        .onTapGesture { store.selectTrack(track.id) }       // sélection unifiée : pilote le rack de la console
        .contextMenu {                                       // geste uniforme : renommer · supprimer (comme bus/mini-fader)
            Button { renaming = true } label: { Label("Renommer", systemImage: "pencil") }
            Button { pickFile() } label: { Label("Ajouter un clip…", systemImage: "waveform.badge.plus") }
            Button(role: .destructive) { store.removeTrack(track.id) } label: { Label("Supprimer la piste", systemImage: "trash") }
        }
        .gesture(DragGesture(minimumDistance: 8)            // glisser l'entête ↕ = réordonner les pistes
            .onChanged { g in dragY = g.translation.height }
            .onEnded { g in
                dragY = 0
                guard let cur = store.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                let target = min(store.tracks.count - 1, max(0, cur + Int((g.translation.height / (laneH + 1)).rounded())))
                guard target != cur else { return }
                var order = store.tracks.map { $0.id }
                let m = order.remove(at: cur); order.insert(m, at: target)
                store.reorderTracks(order)
            })
    }

    /// sélecteur de lane d'automation : volume / pan / gain de chaque clip / param de chaque insert (bornes du schéma).
    private var autoMenu: some View {
        Menu {
            Button("volume") { store.setAutoSel(track.id, "controls/gain") }
            Button("pan") { store.setAutoSel(track.id, "controls/pan") }
            if !track.clips.isEmpty {
                Menu("gain de clip") {
                    ForEach(track.clips) { c in
                        Button(clipMenuLabel(c)) { store.setAutoSel(track.id, "clips/\(c.id)/gain") }
                    }
                }
            }
            ForEach(track.inserts) { ins in
                let specs = store.autoParamSpecs(ins)
                if !specs.isEmpty {
                    Menu(store.insertTitle(ins)) {
                        ForEach(specs) { sp in
                            Button(sp.name) { store.setAutoSel(track.id, "fx/\(ins.id)/params/\(sp.id)") }
                        }
                    }
                }
            }
        } label: { Text(store.autoName(track.id, store.autoRel(track.id))).font(.system(size: 9)).lineLimit(1) }
            .menuStyle(.borderlessButton).fixedSize().help("choisir la lane d'automation")
    }

    /// libellé d'un clip dans le sélecteur d'automation : nom du fichier + position.
    private func clipMenuLabel(_ c: ClipVM) -> String {
        let base = (store.assets[c.asset]?.path as NSString?)?.lastPathComponent ?? c.id
        return "\(base) @\(String(format: "%.1f", c.start))s"
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importToTrack(url.path, trackId: track.id)
        }
    }
}

/// Lane d'automation de volume : enveloppe orange + points draggables. Clic vide = ajouter, double-clic point = retirer.
struct AutomationLane: View {
    let path: String
    var lo: Double; var hi: Double; var unit: Double      // bornes d'affichage + valeur de référence (trait pointillé)
    var pps: CGFloat
    var height: CGFloat
    var contentW: CGFloat
    @EnvironmentObject var store: SocketClient

    private var pts: [AutoPointVM] { store.automation[path]?.points ?? [] }
    private func y(_ v: Double) -> CGFloat { CGFloat(1 - (min(hi, max(lo, v)) - lo) / (hi - lo)) * (height - 10) + 5 }
    private func x(_ t: Double) -> CGFloat { CGFloat(t) * pps }
    private func vAt(_ yy: CGFloat) -> Double { lo + Double(1 - (yy - 5) / (height - 10)) * (hi - lo) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.bg)
            // repère unité (1.0 pour le volume, 0 pour le pan)
            Path { p in p.move(to: CGPoint(x: 0, y: y(unit))); p.addLine(to: CGPoint(x: contentW, y: y(unit))) }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            // enveloppe : segments droits, paliers (hold) ou courbes lisses (bezier = smootherstep, échantillonnée)
            if let first = pts.first, let last = pts.last {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(first.v)))
                    p.addLine(to: CGPoint(x: x(first.t), y: y(first.v)))
                    for k in 1..<max(1, pts.count) {
                        let a = pts[k - 1], b = pts[k]
                        let x0 = x(a.t), x1 = x(b.t)
                        switch a.curve {
                        case "hold":                                   // palier : plat puis saut vertical
                            p.addLine(to: CGPoint(x: x1, y: y(a.v))); p.addLine(to: CGPoint(x: x1, y: y(b.v)))
                        case "bezier":                                 // S-curve : on échantillonne le smootherstep
                            let steps = max(2, Int((x1 - x0) / 4))
                            for st in 1...steps {
                                let f = Double(st) / Double(steps)
                                let e = f * f * f * (f * (6 * f - 15) + 10)
                                p.addLine(to: CGPoint(x: x0 + CGFloat(f) * (x1 - x0), y: y(a.v + (b.v - a.v) * e)))
                            }
                        default:                                       // linéaire
                            p.addLine(to: CGPoint(x: x1, y: y(b.v)))
                        }
                    }
                    p.addLine(to: CGPoint(x: contentW, y: y(last.v)))
                }.stroke(Color.orange, lineWidth: 1.5)
            }
            // points
            ForEach(pts) { pt in
                // un point bezier est plein, un linéaire creux : le galbe du segment se lit d'un coup d'œil
                Circle().fill(pt.curve == "bezier" ? Color.orange : Palette.bg).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.orange, lineWidth: 1.5))
                    .position(x: x(pt.t), y: y(pt.v))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in store.previewPoint(path, pointId: pt.id, t: Double(g.location.x / pps), v: vAt(g.location.y)) }
                        .onEnded { g in store.commitPoint(path, pointId: pt.id, t: Double(g.location.x / pps), v: vAt(g.location.y)) })
                    .onTapGesture(count: 2) { store.removePoint(path, pointId: pt.id) }
                    .contextMenu {                                     // galbe du segment partant de ce point
                        Button("Linéaire") { store.setPointCurve(path, pointId: pt.id, curve: "linear") }
                        Button("Lisse (bézier)") { store.setPointCurve(path, pointId: pt.id, curve: "bezier") }
                        Button("Palier (hold)") { store.setPointCurve(path, pointId: pt.id, curve: "hold") }
                        Divider()
                        Button("Supprimer le point") { store.removePoint(path, pointId: pt.id) }
                    }
            }
        }
        .contentShape(Rectangle())
        // clic dans le vide = ajouter un point (ignoré si trop près d'un point existant, qui gère son propre drag)
        .gesture(DragGesture(minimumDistance: 0).onEnded { g in
            let near = pts.contains { abs(x($0.t) - g.location.x) < 8 && abs(y($0.v) - g.location.y) < 8 }
            if !near { store.addPoint(path, t: Double(g.location.x / pps), v: vAt(g.location.y)) }
        })
    }
}

struct Ruler: View {
    var seconds: Double; var pps: CGFloat
    var onSeek: (Double) -> Void = { _ in }
    var onLoop: (Double, Double) -> Void = { _, _ in }    // glisser une plage = définit la zone de boucle
    var body: some View {
        Canvas { ctx, size in
            let step = 1.0
            var t = 0.0
            while CGFloat(t) * pps < size.width {
                let x = CGFloat(t) * pps
                var p = Path(); p.move(to: CGPoint(x: x, y: size.height - 6)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 1)
                if Int(t) % 5 == 0 {
                    ctx.draw(Text("\(Int(t))s").font(.system(size: 8)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 10, y: 8))
                }
                t += step
            }
        }
        .background(Palette.surface)
        .contentShape(Rectangle())
        // tap = seek ; glisser une plage = définir/prévisualiser la zone de boucle (en direct).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let a = Double(g.startLocation.x / pps), b = Double(g.location.x / pps)
                if abs(b - a) > 0.06 { onLoop(a, b) }
            }
            .onEnded { g in
                let a = Double(g.startLocation.x / pps), b = Double(g.location.x / pps)
                if abs(b - a) <= 0.06 { onSeek(max(0, b)) } else { onLoop(a, b) }
            })
    }
}

/// Lane MASTER read-only : le RENDU COMPLET offline en fond (gris, à la demande) + l'enveloppe de crête accumulée
/// EN LIVE par-dessus (accent, **clips en rouge**). Le live montre ce qui a été joué ; l'offline montre tout le mix.
struct MasterLane: View {
    let wave: [Float]
    let bucket: Double
    let pps: CGFloat
    var offline: [Float] = []
    var offlineBucket: Double = 0.05

    /// dessine une enveloppe de crête (bucket → barre) avec un coloriste donné.
    private func drawEnv(_ ctx: GraphicsContext, _ size: CGSize, _ env: [Float], _ b: Double,
                         _ color: (Bool) -> Color) {
        let mid = size.height / 2, half = size.height / 2 - 2
        let bw = max(1, CGFloat(b) * pps)
        for i in 0..<env.count {
            let x = CGFloat(Double(i) * b) * pps
            if x > size.width + bw { break }
            let v = env[i]; if v <= 0.0001 { continue }
            let frac = max(0.02, min(1, (20 * log10(Double(v)) + 60) / 60))   // échelle -60 dB … 0 dB
            let hh = CGFloat(frac) * half
            ctx.fill(Path(CGRect(x: x, y: mid - hh, width: bw, height: 2 * hh)), with: .color(color(v >= 1.0)))
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Palette.deep)
            Canvas { ctx, size in
                let mid = size.height / 2
                var zero = Path(); zero.move(to: CGPoint(x: 0, y: mid)); zero.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(zero, with: .color(.white.opacity(0.1)), lineWidth: 1)
                drawEnv(ctx, size, offline, offlineBucket) { _ in .gray.opacity(0.4) }            // FOND : rendu complet
                drawEnv(ctx, size, wave, bucket) { $0 ? .red : .accentColor.opacity(0.9) }        // DESSUS : live joué
            }
            if wave.isEmpty && offline.isEmpty {
                Text("▶ joue (live) ou ⟳ rendu complet (entête) pour dessiner le mix master")
                    .font(.system(size: 10)).foregroundColor(.secondary).padding(8)
            }
        }
    }
}

struct Lane: View {
    let track: TrackVM
    var pps: CGFloat
    var height: CGFloat
    @ObservedObject var cache: WaveformCache
    var assets: [String: AssetVM]
    @EnvironmentObject var store: SocketClient
    @State private var dropTargeted = false

    private static let audioExts: Set<String> = ["wav", "aif", "aiff", "m4a", "mp3", "caf", "aac", "flac"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.track)
                .contentShape(Rectangle())
                .onTapGesture { store.selectClip(nil) }      // clic dans le vide = désélectionne
            if track.clips.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.badge.plus").font(.system(size: 15)).foregroundColor(Palette.accent.opacity(0.7))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Glissez un audio ici").font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.text2)
                        Text("ou « + clip… » dans l'entête · clic droit › Ajouter un clip").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14).frame(maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            ForEach(track.clips) { clip in
                ClipView(track: track, clip: clip, pps: pps, height: height, cache: cache,
                         asset: assets[clip.asset])
            }
        }
        // glisser-déposer depuis le Finder : importe + pose le clip À LA POSITION lâchée (x → temps).
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers, location in
            handleDrop(providers, atX: location.x)
        }
        .overlay(dropTargeted
            ? RoundedRectangle(cornerRadius: 4).fill(Palette.accent.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
                .allowsHitTesting(false)
            : nil)
    }

    /// Importe chaque fichier audio lâché et le pose à la position temporelle du lâcher (clamp ≥ 0).
    private func handleDrop(_ providers: [NSItemProvider], atX x: CGFloat) -> Bool {
        let startSec = max(0, Double(x / pps))
        var accepted = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let path: String? = (item as? URL)?.path
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil)?.path }
                guard let path, Lane.audioExts.contains((path as NSString).pathExtension.lowercased()) else { return }
                DispatchQueue.main.async { store.importToTrack(path, trackId: track.id, start: startSec) }
            }
        }
        return accepted
    }
}

/// Un clip : waveform tranchée + fades, DÉPLAÇABLE à la souris (drag horizontal → clip.move).
struct ClipView: View {
    let track: TrackVM
    let clip: ClipVM
    var pps: CGFloat
    var height: CGFloat
    @ObservedObject var cache: WaveformCache
    var asset: AssetVM?
    @EnvironmentObject var store: SocketClient
    @State private var dragBaseStart: Double?
    @State private var trimBase: (start: Double, offset: Double, duration: Double)?
    @State private var fadeInBase: Double?
    @State private var fadeOutBase: Double?
    @State private var dragOffsetY: CGFloat = 0     // levée verticale pendant un drag inter-pistes

    private var w: CGFloat { max(1, CGFloat(clip.duration) * pps) }
    private var hh: CGFloat { height - 12 }
    private var selected: Bool { store.selectedClipId == clip.id }

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            if let a = asset, a.duration > 0, let wf = cache.waveform(for: a.path), wf.peaks.count > 0 {
                let n = wf.peaks.count
                let i0 = max(0, min(n - 1, Int(clip.offset / a.duration * Double(n))))
                let i1 = max(i0 + 1, min(n, Int((clip.offset + clip.duration) / a.duration * Double(n))))
                let cnt = i1 - i0
                let mid = rect.midY, half = rect.height / 2 - 2
                var wave = Path()
                wave.move(to: CGPoint(x: 0, y: mid))
                for k in 0..<cnt {
                    let x = size.width * CGFloat(k) / CGFloat(cnt)
                    wave.addLine(to: CGPoint(x: x, y: mid - CGFloat(wf.peaks[i0 + k]) * half * 0.95))
                }
                for k in stride(from: cnt - 1, through: 0, by: -1) {
                    let x = size.width * CGFloat(k) / CGFloat(cnt)
                    wave.addLine(to: CGPoint(x: x, y: mid + CGFloat(wf.peaks[i0 + k]) * half * 0.95))
                }
                wave.closeSubpath()
                ctx.fill(wave, with: .color(track.mute ? .gray.opacity(0.35) : .accentColor.opacity(0.85)))
            }
            // wedges de fade : la pente suit le GALBE (linéaire/exp/S) → le visuel = ce qu'on entend
            let fi = CGFloat(clip.fadeIn) * pps, fo = CGFloat(clip.fadeOut) * pps
            let h = rect.height, shape = clip.fadeShape, steps = 16
            if fi > 1 {
                var t = Path(); t.move(to: .zero); t.addLine(to: CGPoint(x: fi, y: 0))
                for k in 0...steps { let tau = Double(steps - k) / Double(steps)   // de B(fi,0) vers C(0,h)
                    t.addLine(to: CGPoint(x: fi * CGFloat(tau), y: h * CGFloat(1 - Engine.fadeGain(tau, shape)))) }
                t.closeSubpath(); ctx.fill(t, with: .color(.black.opacity(0.45)))
            }
            if fo > 1 {
                var t = Path(); t.move(to: CGPoint(x: rect.width, y: 0)); t.addLine(to: CGPoint(x: rect.width - fo, y: 0))
                for k in 0...steps { let tau = Double(k) / Double(steps)           // de (width-fo,0) vers (width,h)
                    t.addLine(to: CGPoint(x: rect.width - fo * CGFloat(tau), y: h * CGFloat(1 - Engine.fadeGain(tau, shape)))) }
                t.closeSubpath(); ctx.fill(t, with: .color(.black.opacity(0.45)))
            }
        }
        .frame(width: w, height: height - 12)
        .background(Color.white.opacity(selected ? 0.12 : (dragBaseStart == nil ? 0.04 : 0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(selected ? Color.accentColor : Color.white.opacity(dragBaseStart == nil ? 0.2 : 0.6),
                    lineWidth: selected ? 2 : 1))
        .overlay(alignment: .topLeading) { if selected { handles } }   // poignées trim + fade (clip sélectionné)
        .offset(x: CGFloat(clip.start) * pps, y: 6 + dragOffsetY)
        .zIndex(dragOffsetY != 0 ? 10 : 0)
        .onTapGesture { store.selectClip(clip.id) }          // clic = sélectionne ce clip
        .contextMenu {                                       // geste uniforme : couper · dupliquer · supprimer (sur le clip lui-même)
            Button { store.selectClip(clip.id); store.splitClip(clipId: clip.id, at: store.playhead) } label: { Label("Couper au playhead", systemImage: "scissors") }
            Button { store.duplicateClip(clipId: clip.id) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { store.removeClip(clipId: clip.id) } label: { Label("Supprimer", systemImage: "trash") }
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                let base = dragBaseStart ?? clip.start
                if dragBaseStart == nil { dragBaseStart = base; store.selectClip(clip.id) }
                store.previewClipStart(trackId: track.id, clipId: clip.id, snapStart(base + Double(g.translation.width / pps)))
                dragOffsetY = g.translation.height           // la levée verticale suit le doigt
            }
            .onEnded { g in
                dragBaseStart = nil; dragOffsetY = 0
                if let dst = targetTrack(g.translation.height), dst != track.id {
                    store.commitClipMoveToTrack(clipId: clip.id, start: clip.start, trackId: dst)   // → autre piste
                } else {
                    store.commitClipMove(clipId: clip.id, start: clip.start)
                    autoCrossfade()                                                                 // recouvrement → crossfade
                }
            })
        .hoverCursor(.openHand)
        .help("glisser = déplacer (↕ change de piste · recouvrir un voisin = crossfade) · poignées = trim/fade")
    }

    /// Aimantation (snap) du déplacement : ramène le bord GAUCHE ou DROIT du clip au repère le plus proche
    /// (début de timeline, playhead, bords des autres clips toutes pistes) dans une tolérance de ~8 px.
    /// Maintenir Option (⌥) désactive le snap pour un placement fin. Le bord aimanté est celui qui « gagne ».
    private func snapStart(_ proposed: Double) -> Double {
        if NSEvent.modifierFlags.contains(.option) { return max(0, proposed) }
        let thr = Double(8 / pps)                                  // tolérance en secondes (8 px)
        var targets: [Double] = [0, store.playhead]
        for t in store.tracks {
            for c in t.clips where c.id != clip.id { targets.append(c.start); targets.append(c.start + c.duration) }
        }
        let dur = clip.duration
        var best = proposed, bestDelta = thr
        for tgt in targets {
            if abs(tgt - proposed) < bestDelta { bestDelta = abs(tgt - proposed); best = tgt }               // bord gauche
            if abs(tgt - (proposed + dur)) < bestDelta { bestDelta = abs(tgt - (proposed + dur)); best = tgt - dur }  // bord droit
        }
        return max(0, best)
    }

    /// piste cible d'un drag vertical (approx : pas = hauteur de lane ; ignore les lanes d'automation).
    private func targetTrack(_ dy: CGFloat) -> String? {
        guard let cur = store.tracks.firstIndex(where: { $0.id == track.id }) else { return nil }
        let ti = min(store.tracks.count - 1, max(0, cur + Int((dy / (height + 1)).rounded())))
        return store.tracks[ti].id
    }

    /// si le clip déposé chevauche un voisin sur la même piste → fondu enchaîné (a antérieur, b postérieur).
    private func autoCrossfade() {
        guard let t = store.tracks.first(where: { $0.id == track.id }) else { return }
        let b = clip
        if let other = t.clips.first(where: { o in
            o.id != b.id && o.start < b.start + b.duration && o.start + o.duration > b.start
                && (min(o.start + o.duration, b.start + b.duration) - max(o.start, b.start)) > 0.02
        }) {
            let pair = b.start <= other.start ? (b.id, other.id) : (other.id, b.id)
            store.crossfade(a: pair.0, b: pair.1)
        }
    }

    // MARK: poignées d'édition (visibles quand le clip est sélectionné)

    private var maxDur: Double { (asset?.duration ?? (clip.offset + clip.duration)) - clip.offset }

    @ViewBuilder private var handles: some View {
        ZStack(alignment: .topLeading) {
            trimGrip(left: true)
            trimGrip(left: false)
            fadeKnob(isIn: true)
            fadeKnob(isIn: false)
        }
        .frame(width: w, height: hh, alignment: .topLeading)
    }

    /// poignée de trim sur un bord (barre fine, zone de hit large).
    @ViewBuilder private func trimGrip(left: Bool) -> some View {
        let bar = RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.9))
            .frame(width: 3, height: hh * 0.6)
            .frame(width: 16, height: hh).contentShape(Rectangle())
            .position(x: left ? 8 : w - 8, y: hh / 2)
        if left { bar.highPriorityGesture(leftTrim).hoverCursor(.resizeLeftRight).help("trim gauche") }
        else { bar.highPriorityGesture(rightTrim).hoverCursor(.resizeLeftRight).help("trim droit") }
    }

    /// poignée de fade dans un coin haut (rond orange, zone de hit large).
    @ViewBuilder private func fadeKnob(isIn: Bool) -> some View {
        let x = isIn ? min(w, CGFloat(clip.fadeIn) * pps) : max(0, w - CGFloat(clip.fadeOut) * pps)
        let knob = Circle().fill(Color.orange).overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .frame(width: 11, height: 11)
            .frame(width: 26, height: 26).contentShape(Rectangle())
            .position(x: x, y: 6)
        if isIn { knob.highPriorityGesture(fadeInDrag).help("fade in") }
        else { knob.highPriorityGesture(fadeOutDrag).help("fade out") }
    }

    private var rightTrim: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let base = trimBase ?? (clip.start, clip.offset, clip.duration)
                if trimBase == nil { trimBase = base; store.selectClip(clip.id) }
                let lim = max(0.02, (asset?.duration ?? (base.offset + base.duration)) - base.offset)
                let d = min(max(0.02, base.duration + Double(g.translation.width / pps)), lim)
                store.previewClipEdit(clipId: clip.id, duration: d)
            }
            .onEnded { _ in trimBase = nil; store.commitTrim(clipId: clip.id, duration: clip.duration) }
    }
    private var leftTrim: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let base = trimBase ?? (clip.start, clip.offset, clip.duration)
                if trimBase == nil { trimBase = base; store.selectClip(clip.id) }
                let dSec = Double(g.translation.width / pps)
                let lo = max(-base.offset, -base.start)     // offset≥0 et start≥0
                let hi = base.duration - 0.02               // durée mini
                let delta = min(hi, max(lo, dSec))
                store.previewClipEdit(clipId: clip.id, start: base.start + delta,
                                      offset: base.offset + delta, duration: base.duration - delta)
            }
            .onEnded { _ in trimBase = nil
                store.commitTrim(clipId: clip.id, start: clip.start, offset: clip.offset, duration: clip.duration) }
    }
    private var fadeInDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let base = fadeInBase ?? clip.fadeIn
                if fadeInBase == nil { fadeInBase = base; store.selectClip(clip.id) }
                let f = min(max(0, base + Double(g.translation.width / pps)), clip.duration)
                store.previewClipEdit(clipId: clip.id, fadeIn: f)
            }
            .onEnded { _ in fadeInBase = nil; store.commitFade(clipId: clip.id, fadeIn: clip.fadeIn) }
    }
    private var fadeOutDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                let base = fadeOutBase ?? clip.fadeOut
                if fadeOutBase == nil { fadeOutBase = base; store.selectClip(clip.id) }
                let f = min(max(0, base - Double(g.translation.width / pps)), clip.duration)
                store.previewClipEdit(clipId: clip.id, fadeOut: f)
            }
            .onEnded { _ in fadeOutBase = nil; store.commitFade(clipId: clip.id, fadeOut: clip.fadeOut) }
    }
}
