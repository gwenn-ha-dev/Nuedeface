// Nuedeface — la console de mix « à l'ancienne » (le 2ᵉ pilier du projet).
//
// Une tranche par piste (EQ lisible, pan, fader, mute, source) + une tranche MASTER avec le
// VRAI mètre (LUFS/peak/clipping) renvoyé par `analyze`. Tout passe par le socket : chaque
// geste émet un `set`, et le delta attribué revient (visible aussi si Claude pousse en parallèle).

import SwiftUI

/// La console (vue du bas) : à GAUCHE le canal sélectionné en détail (son rack d'effets),
/// à DROITE la section mix+master (un mini-fader par piste + la sortie master épinglée).
struct ConsoleView: View {
    @EnvironmentObject var store: SocketClient
    /// le canal courant à éditer dans le rack : piste OU master (même vue FX pour tous — pas de cas spécial master).
    private var channel: (loc: FXLoc, title: String, inserts: [InsertVM], output: String?)? {
        switch store.selectedChannel {
        case .bus(let id):
            guard let b = store.buses.first(where: { $0.id == id }) else { return nil }
            return (.bus(id), b.name.uppercased(), b.inserts, id == "master" ? nil : b.output)   // master → sortie physique
        case .track(let id):
            guard let t = store.tracks.first(where: { $0.id == id }) else { return nil }
            return (.track(id), t.name, t.inserts, t.output)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ChannelDetail(channel: channel)
                .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            Divider().background(Palette.divider)
            MixMaster()
        }
        .lit(Palette.surface)
    }
}

private func dbString(_ lin: Double) -> String {
    lin <= 0.0001 ? "-∞" : String(format: "%+.1f", 20 * log10(lin))
}

/// GAUCHE : le canal sélectionné en RACK horizontal — IN → modules d'effet → MASTER, signal gauche→droite.
struct ChannelDetail: View {
    let channel: (loc: FXLoc, title: String, inserts: [InsertVM], output: String?)?
    @EnvironmentObject var store: SocketClient

    var body: some View {
        if let c = channel {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.3.group").font(.system(size: 13)).foregroundColor(.accentColor)
                    Text(c.title).font(Typo.heading).foregroundColor(Palette.text)
                    if let out = c.output { outputMenu(c.loc, out) }     // sélecteur de sortie (sauf master)
                    Spacer()
                    RecipeMenu(loc: c.loc)
                    AddFXButton(target: c.loc)
                }
                .padding(.horizontal, 16).frame(height: 44).lit(Palette.header)
                Divider().background(Palette.divider)
                RackFlow(loc: c.loc, inserts: c.inserts)
                Divider()
                // master : oreille tonale (spectre) ; autres canaux : leurs sends
                if case .bus("master") = c.loc { SpectrumPanel() } else { SendsBar(loc: c.loc) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "hand.point.up.left").font(.system(size: 20)).foregroundColor(.secondary)
                Text("sélectionne un canal").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// menu de routage : vers master ou un bus aux (anti-cycle validé côté moteur).
    private func outputMenu(_ loc: FXLoc, _ current: String) -> some View {
        let me = locId(loc)
        return Menu {
            Button("→ MASTER") { store.setOutput(loc, dest: "master") }
            ForEach(store.auxBuses.filter { $0.id != me }) { b in
                Button("→ \(b.name)") { store.setOutput(loc, dest: b.id) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                Text("sortie : \(outName(current))").font(.system(size: 10))
            }.foregroundColor(.secondary)
        }.menuStyle(.borderlessButton).fixedSize()
    }
    private func locId(_ loc: FXLoc) -> String { switch loc { case .track(let i): return i; case .bus(let i): return i } }
    private func outName(_ id: String) -> String { store.buses.first { $0.id == id }?.name ?? id }
}

/// Le rack d'un canal : modules DOCKÉS (taille = contenu) reliés par des connecteurs, repliés en SERPENTIN
/// (snake : rangées paires gauche→droite, impaires droite→gauche) quand la largeur ne suffit plus.
struct RackFlow: View {
    let loc: FXLoc
    let inserts: [InsertVM]
    @EnvironmentObject var store: SocketClient

    private enum Item: Identifiable {
        case input, output, fx(Int)
        var id: String { switch self { case .input: return "in"; case .output: return "out"; case .fx(let i): return "fx\(i)" } }
    }
    private let connW: CGFloat = 20

    private func moduleWidth(_ ins: InsertVM) -> CGFloat {
        switch ins.type {
        case "eq": return 250
        case "reverb": return 92
        case "delay": return 196
        case "distortion": return 140
        case "au": return CGFloat(min(3, max(1, ins.schema.count))) * 62 + 16   // grille de knobs
        default: return 120
        }
    }
    private func itemWidth(_ it: Item) -> CGFloat {
        switch it { case .input, .output: return 56; case .fx(let i): return moduleWidth(inserts[i]) }
    }

    /// répartit IN + modules + OUT en rangées qui tiennent dans `width` (greedy).
    private func rows(_ width: CGFloat) -> [[Item]] {
        var items: [Item] = [.input]; items += inserts.indices.map { Item.fx($0) }; items.append(.output)
        var out: [[Item]] = [], cur: [Item] = [], w: CGFloat = 0
        for it in items {
            let add = (cur.isEmpty ? 0 : connW) + itemWidth(it)
            if !cur.isEmpty && w + add > width { out.append(cur); cur = []; w = 0 }
            cur.append(it); w += (cur.count == 1 ? 0 : connW) + itemWidth(it)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let rs = rows(max(160, geo.size.width - 24))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rs.indices, id: \.self) { r in
                        let even = r % 2 == 0
                        let row = even ? rs[r] : Array(rs[r].reversed())     // serpentin : impaire = sens inverse
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.element.id) { k, it in
                                if k > 0 { connector }
                                itemView(it)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: even ? .leading : .trailing)
                        // coude « patch » qui boucle au bord du rack vers la rangée suivante du serpentin
                        if r < rs.count - 1 { rowTurn(even ? .trailing : .leading) }
                    }
                }
                .padding(12)
            }
        }
    }

    /// connecteur « patch » physique entre deux modules dockés (câble court + jack).
    private var connector: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 2)
            Circle().fill(Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
        }
        .frame(width: connW).frame(maxHeight: .infinity)
    }

    /// coude de fin de rangée : le câble boucle au bord (`side`) et redescend vers la rangée suivante.
    /// Le geste de lecture reste continu (serpentin) — il rend la 2D « physique » plutôt que de sauter sec.
    private func rowTurn(_ side: HorizontalEdge) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let xIn: CGFloat = side == .trailing ? w - 12 : 12      // ancrage près du dernier/premier module
            let xOut: CGFloat = side == .trailing ? w - 2 : 2       // sommet de la boucle, au bord du rack
            ZStack {
                Path { p in                                          // demi-boucle : bas de la rangée → haut de la suivante
                    p.move(to: CGPoint(x: xIn, y: 1))
                    p.addQuadCurve(to: CGPoint(x: xIn, y: h - 1), control: CGPoint(x: xOut + (side == .trailing ? 8 : -8), y: h / 2))
                }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle().fill(Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
                    .position(x: xOut, y: h / 2)                     // jack au point de virage
            }
        }
        .frame(height: 18)
    }

    @ViewBuilder private func itemView(_ it: Item) -> some View {
        switch it {
        case .input: RackEndcap(title: "IN", icon: "arrow.right.to.line.compact")
        case .output: RackEndcap(title: "OUT", icon: "arrow.right.to.line")
        case .fx(let i):
            InsertCard(target: loc, insert: inserts[i],
                       canMoveUp: i > 0, canMoveDown: i < inserts.count - 1,
                       onMove: { up in move(i, up) }, horizontal: true)
                .frame(width: moduleWidth(inserts[i]))
        }
    }

    private func move(_ idx: Int, _ up: Bool) {
        var order = inserts.map { $0.id }
        let j = up ? idx - 1 : idx + 1
        guard order.indices.contains(idx), order.indices.contains(j) else { return }
        order.swapAt(idx, j); store.reorderInsert(loc, order: order)
    }
}

/// Barre de SENDS du canal : taps parallèles vers des bus aux (knob de niveau + pré/post + retrait) + ajout.
struct SendsBar: View {
    let loc: FXLoc
    @EnvironmentObject var store: SocketClient

    private var sends: [SendVM] {
        switch loc { case .track(let i): return store.tracks.first { $0.id == i }?.sends ?? []
                     case .bus(let i): return store.buses.first { $0.id == i }?.sends ?? [] }
    }
    private func busName(_ id: String) -> String { store.buses.first { $0.id == id }?.name ?? id }
    private var meId: String { switch loc { case .track(let i): return i; case .bus(let i): return i } }
    private var destinations: [BusVM] { store.auxBuses.filter { $0.id != meId } }

    var body: some View {
        HStack(spacing: 12) {
            Text("SENDS").sectionLabel()
            ForEach(sends) { snd in sendChip(snd) }
            addMenu
            if case .track(let tgt) = loc { duckMenu(target: tgt) }   // ducking : ce canal baisse sous une source
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 64).lit(Palette.panel)
    }

    /// menu DUCK : la piste courante (cible/ambiance) baisse automatiquement sous une source (voix).
    /// C'est de l'AUTOMATION bakée (pas un vrai sidechain — mur API Apple) → lane éditable dans la timeline.
    private func duckMenu(target: String) -> some View {
        Menu {
            Text("baisser sous… (source)").font(.system(size: 9))
            ForEach(store.tracks.filter { $0.id != target }) { src in
                Button(src.name) { store.duck(source: src.id, target: target) }
            }
        } label: { Label("duck", systemImage: "waveform.path.badge.minus").font(.system(size: 9)) }
        .menuStyle(.borderlessButton).fixedSize().help("ducking : baisse sous une source (automation)")
    }

    private func sendChip(_ snd: SendVM) -> some View {
        HStack(spacing: 5) {
            VStack(spacing: 1) {
                Dial(value: Binding(get: { snd.level }, set: { store.set("\(loc.pathPrefix)/sends/\(snd.id)/level", $0) }),
                     range: 0...1, size: 28)
                Text(busName(snd.dest)).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
            }
            VStack(spacing: 3) {
                Button(snd.pre ? "PRE" : "post") { store.setSendPre(loc, sendId: snd.id, !snd.pre) }
                    .font(.system(size: 7, weight: .bold)).buttonStyle(.bordered).controlSize(.mini)
                Button { store.removeSend(loc, sendId: snd.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(7).card()
        .contextMenu {        // geste uniforme : pré/post · supprimer
            Button { store.setSendPre(loc, sendId: snd.id, !snd.pre) } label: { Label(snd.pre ? "Passer en post-fader" : "Passer en pré-fader", systemImage: "arrow.left.arrow.right") }
            Button(role: .destructive) { store.removeSend(loc, sendId: snd.id) } label: { Label("Supprimer le send", systemImage: "trash") }
        }
    }

    private var addMenu: some View {
        Menu {
            if destinations.isEmpty {
                Text("crée un bus aux d'abord")
            } else {
                ForEach(destinations) { b in Button("→ \(b.name)") { store.addSend(loc, dest: b.id) } }
            }
        } label: { Label("send", systemImage: "plus.circle").font(.system(size: 9)) }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

/// Oreille tonale du master : barres de bandes + centroïde/pic/tilt. Mesure à la demande (rend le mix offline).
struct SpectrumPanel: View {
    @EnvironmentObject var store: SocketClient
    private func hz(_ f: Double) -> String { f >= 1000 ? String(format: "%.1f kHz", f / 1000) : String(format: "%.0f Hz", f) }

    var body: some View {
        HStack(spacing: 12) {
            Text("SPECTRE").sectionLabel()
            if let sp = store.spectrum {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(sp.bands) { b in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(LinearGradient(colors: [.green, .yellow, .orange], startPoint: .bottom, endPoint: .top))
                            .frame(width: 9, height: 40 * CGFloat(max(0.03, min(1, (b.db + 60) / 60))))
                    }
                }
                .frame(height: 40, alignment: .bottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text("centroïde \(hz(sp.centroidHz))")
                    Text("pic \(hz(sp.peakHz)) · tilt \(String(format: "%+.1f dB", sp.tiltDb))")
                }.font(.system(size: 8)).foregroundColor(.secondary).monospacedDigit()
            } else {
                Text("— mesure à la demande").font(.system(size: 9)).foregroundColor(.secondary)
            }
            // spectrogramme LIVE (temps × fréq) : repère sifflantes/ronflette à l'œil
            if !store.spectrogram.isEmpty {
                SpectrogramView(frames: store.spectrogram).frame(width: 150, height: 44)
            }
            Spacer()
            Button { store.fetchSpectrum() } label: {
                Image(systemName: store.spectrumLoading ? "hourglass" : "waveform.path.ecg").frame(width: 24, height: 18)
            }.buttonStyle(.bordered).controlSize(.mini).disabled(store.spectrumLoading).help("mesurer le spectre")
        }
        .padding(.horizontal, 16).frame(height: 64).lit(Palette.panel)
    }
}

/// Embout de rack (entrée / sortie vers master).
struct RackEndcap: View {
    let title: String
    let icon: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(Palette.text2)
            Text(title).sectionLabel()
        }
        .frame(width: 56).frame(maxHeight: .infinity)
        .card(Palette.bg)
    }
}

/// Menu RECETTES (baguette) : applique une intention nommée (téléphone, master podcast…) qui s'expanse en
/// chaîne d'effets. L'humain a les MÊMES raccourcis que l'IA ; les deltas groupés s'affichent en direct.
struct RecipeMenu: View {
    let loc: FXLoc
    @EnvironmentObject var store: SocketClient

    private var isTrack: Bool { if case .track = loc { return true }; return false }
    private var meId: String { switch loc { case .track(let i): return i; case .bus(let i): return i } }
    /// recettes applicables à ce canal (track → 'track'/'duck' ; bus → 'bus').
    private var applicable: [RecipeVM] { store.recipes.filter { isTrack ? ($0.target == "track" || $0.target == "duck") : $0.target == "bus" } }

    var body: some View {
        Menu {
            if applicable.isEmpty { Text("aucune recette") }
            ForEach(applicable) { r in
                if r.target == "duck" {
                    Menu("\(r.name)…") {
                        Text("source (voix) :").font(.system(size: 9))
                        ForEach(store.tracks.filter { $0.id != meId }) { src in
                            Button(src.name) { store.applyRecipe(r.id, source: src.id) }
                        }
                    }
                } else {
                    Button(r.name) { store.applyRecipe(r.id) }.help(r.expands)
                }
            }
        } label: { Image(systemName: "wand.and.stars").foregroundColor(.accentColor) }
        .menuStyle(.borderlessButton).fixedSize().help("recettes : intentions prêtes (téléphone, master…)")
    }
}

/// Menu « + » d'ajout d'effet (4 typés + catalogue AU Apple). Réutilisé rack piste & master.
struct AddFXButton: View {
    let target: FXLoc
    @EnvironmentObject var store: SocketClient
    var body: some View {
        Menu {
            Button("EQ") { store.addInsert(target, type: "eq") }
            Button("Reverb") { store.addInsert(target, type: "reverb") }
            Button("Delay") { store.addInsert(target, type: "delay") }
            Button("Distortion") { store.addInsert(target, type: "distortion") }
            if !store.auCatalog.isEmpty {
                Divider()
                Menu("Audio Units Apple") {
                    ForEach(store.auCatalog) { au in
                        Button(au.name) { store.addInsert(target, type: "au", subType: au.subType) }
                    }
                }
            }
        } label: { Image(systemName: "plus.circle") }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

/// FFT LIVE dessiné DERRIÈRE la courbe d'EQ (le wow Pro-Q) : aire remplie, bins log-espacés alignés sur
/// l'axe fréquence de l'EQ (20 Hz→20 kHz). Vide hors lecture. Mapping identique à EQCurve → ce que l'œil
/// voit sous la courbe = le spectre réel du master à cet instant.
struct LiveSpectrumBackdrop: View {
    let bins: [Float]
    let sr: Double
    private let fLo = 20.0, fHi = 20_000.0

    var body: some View {
        Canvas { ctx, size in
            guard bins.count > 2 else { return }
            let w = size.width, h = size.height
            let nyq = sr / 2
            func binFreq(_ i: Int) -> Double { pow(10, log10(fLo) + Double(i) / Double(bins.count) * (log10(nyq) - log10(fLo))) }
            func x(_ f: Double) -> Double { (log10(min(fHi, max(fLo, f))) - log10(fLo)) / (log10(fHi) - log10(fLo)) * w }
            func y(_ db: Double) -> Double { h - CGFloat(max(0.0, min(1.0, (db + 90) / 90))) * (h - 3) }   // -90..0 dB → bas..haut
            var p = Path()
            p.move(to: CGPoint(x: 0, y: h))
            for i in 0..<bins.count { p.addLine(to: CGPoint(x: x(binFreq(i)), y: y(Double(bins[i])))) }
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [Palette.accent.opacity(0.30), Palette.accent.opacity(0.05)]),
                                              startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        }
        .allowsHitTesting(false)
    }
}

/// EQ TANGIBLE 4 bandes : courbe sommée + un NŒUD par bande (low-shelf · low-mid · high-mid · high-shelf).
/// On attrape un nœud → X = fréquence, Y = gain de SA bande. Le geste EST l'édition.
struct EQNodeView: View {
    let target: FXLoc
    let insert: InsertVM
    @EnvironmentObject var store: SocketClient

    // 4 bandes fixes (mêmes défauts que le moteur) + une couleur par bande
    static let specs: [(kind: EQBandKind, defFreq: Double, color: Color)] = [
        (.lowShelf, 100, .blue), (.peak, 500, .accentColor), (.peak, 3_000, .green), (.highShelf, 8_000, .orange)
    ]
    private let fLo = 20.0, fHi = 20_000.0, dbMax = 24.0

    @State private var pinchBase: [Int: Double] = [:]   // largeur de bande au début d'un pincement (par bande)

    private func freq(_ i: Int) -> Double { insert.params["b\(i)_freq"] ?? Self.specs[i].defFreq }
    private func gain(_ i: Int) -> Double { insert.params["b\(i)_gain"] ?? 0 }
    private func bw(_ i: Int) -> Double { insert.params["b\(i)_bw"] ?? 1.0 }
    private func isPeak(_ i: Int) -> Bool { Self.specs[i].kind == .peak }
    private var bands: [EQBandVal] { (0..<4).map { EQBandVal(kind: Self.specs[$0].kind, freq: freq($0), gain: gain($0), bw: bw($0)) } }

    private func nx(_ f: Double, _ w: Double) -> Double {
        (log10(min(fHi, max(fLo, f))) - log10(fLo)) / (log10(fHi) - log10(fLo)) * w
    }
    private func ny(_ db: Double, _ h: Double) -> Double { h / 2 - min(dbMax, max(-dbMax, db)) / dbMax * (h / 2 - 4) }
    private func freqAt(_ x: Double, _ w: Double) -> Double {
        let f = min(1, max(0, x / w)); return pow(10, log10(fLo) + f * (log10(fHi) - log10(fLo)))
    }
    private func dbAt(_ y: Double, _ h: Double) -> Double { min(dbMax, max(-dbMax, (h / 2 - y) / (h / 2 - 4) * dbMax)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LiveSpectrumBackdrop(bins: store.liveSpectrum, sr: store.sampleRate)   // FFT live qui coule derrière la courbe
                EQCurve(bands: bands, bypass: insert.bypass, sr: store.sampleRate)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(insert.bypass ? Color.gray : Self.specs[i].color)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 15, height: 15)
                        .position(x: nx(freq(i), w), y: ny(gain(i), h))
                        .shadow(radius: 1.5)
                        .hoverCursor(.crosshair)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                            store.set("\(target.pathPrefix)/fx/\(insert.id)/params/b\(i)_freq", freqAt(g.location.x, w))
                            store.set("\(target.pathPrefix)/fx/\(insert.id)/params/b\(i)_gain", dbAt(g.location.y, h))
                        })
                        // pincement = largeur de bande (Q) — n'agit que sur les peaks (les shelves ont une pente fixe)
                        .simultaneousGesture(MagnificationGesture().onChanged { scale in
                            guard isPeak(i) else { return }
                            let base = pinchBase[i] ?? bw(i); pinchBase[i] = base
                            let nv = min(3, max(0.1, base / Double(scale)))   // écarter les doigts = bande plus étroite (Q ↑)
                            store.set("\(target.pathPrefix)/fx/\(insert.id)/params/b\(i)_bw", nv)
                        }.onEnded { _ in pinchBase[i] = nil })
                }
            }
            .contentShape(Rectangle())
        }
    }
}

/// DROITE : la « table de mixage » — un mini-fader par piste (balance) + la sortie MASTER épinglée à droite.
struct MixMaster: View {
    @EnvironmentObject var store: SocketClient

    var body: some View {
        HStack(spacing: 0) {
            tracksArea
            Divider().background(Color.black)
            // bus aux / sous-groupes + bouton « créer un bus »
            ForEach(store.auxBuses) { b in
                BusMini(bus: b)
                Divider().background(Color.black.opacity(0.3))
            }
            addBusButton
            Divider().background(Color.black)
            MasterMini()
        }
        .frame(maxHeight: .infinity)
        .lit(Palette.surface2)
    }

    // ≤6 pistes : hug le contenu (responsive) ; au-delà : défile
    @ViewBuilder private var tracksArea: some View {
        if store.tracks.count <= 6 {
            HStack(spacing: 0) { faders }
        } else {
            ScrollView(.horizontal, showsIndicators: true) { HStack(spacing: 0) { faders } }.frame(width: 6 * 64)
        }
    }
    @ViewBuilder private var faders: some View {
        ForEach(store.tracks) { t in
            MiniFader(track: t)
            Divider().background(Color.black.opacity(0.3))
        }
    }
    private var addBusButton: some View {
        Button { store.addBus() } label: {
            VStack(spacing: 4) { Image(systemName: "plus.circle").font(.system(size: 14)); Text("bus").font(.system(size: 8)) }
                .foregroundColor(.secondary).frame(width: 42).frame(maxHeight: .infinity)
        }.buttonStyle(.plain).help("créer un bus aux / sous-groupe")
    }
}

/// Mini-tranche d'un BUS aux : nom (sélectionne → rack), fader, mute. Pas de pan/solo (c'est un sous-mix).
struct BusMini: View {
    let bus: BusVM
    @EnvironmentObject var store: SocketClient
    @State private var renaming = false
    private var selected: Bool { store.selectedChannel == .bus(bus.id) }

    var body: some View {
        VStack(spacing: 5) {
            EditableLabel(text: bus.name, editing: $renaming) { store.renameBus(bus.id, $0) }
                .frame(maxWidth: .infinity).foregroundColor(selected ? Palette.text : Palette.text2)
                .onTapGesture(count: 2) { renaming = true }
            Image(systemName: "arrow.triangle.merge").font(.system(size: 9)).foregroundColor(.secondary)
            HStack(spacing: 3) {                                   // fader + VU live (crête du sous-mix)
                VFader(gain: Binding(get: { bus.gain }, set: { store.set("bus/\(bus.id)/controls/gain", $0) }))
                BallisticVU(level: store.busLevels[bus.id] ?? 0)
            }
            .frame(maxHeight: .infinity)
            Text(dbString(bus.gain)).font(.system(size: 8)).monospacedDigit().foregroundColor(.secondary)
            Button(bus.mute ? "M" : "m") { store.set("bus/\(bus.id)/controls/mute", !bus.mute) }
                .buttonStyle(.borderedProminent).tint(bus.mute ? .red : .gray)
                .font(.system(size: 8, weight: .bold)).controlSize(.mini)
        }
        .padding(.vertical, 8).padding(.horizontal, 5)
        .frame(width: Dims.stripW).frame(maxHeight: .infinity, alignment: .top)
        .background(selected ? Palette.selection : Palette.track)
        .overlay(selected ? RoundedRectangle(cornerRadius: 0).stroke(Palette.accent.opacity(0.5), lineWidth: 1) : nil)
        .contentShape(Rectangle())
        .onTapGesture { store.selectBus(bus.id) }
        .contextMenu {        // long-press / clic droit : renommer · déplacer · supprimer (bus.rename/reorder/remove)
            Button { renaming = true } label: { Label("Renommer", systemImage: "pencil") }
            Button { moveBus(left: true) } label: { Label("Déplacer à gauche", systemImage: "arrow.left") }
            Button { moveBus(left: false) } label: { Label("Déplacer à droite", systemImage: "arrow.right") }
            Button(role: .destructive) { store.removeBus(bus.id) } label: { Label("Supprimer le bus", systemImage: "trash") }
        }
    }

    /// réordonne ce bus parmi ses voisins aux (ne franchit pas le master). Verbe bus.reorder (ordre complet).
    private func moveBus(left: Bool) {
        var order = store.buses.map { $0.id }
        guard let i = order.firstIndex(of: bus.id) else { return }
        let j = left ? i - 1 : i + 1
        guard order.indices.contains(j), order[j] != "master" else { return }
        order.swapAt(i, j); store.reorderBuses(order)
    }
}

/// Mini-tranche compacte d'une piste : nom (sélectionne), pan, fader + dB, mute/solo. Le VU live arrive à l'étape 2.
struct MiniFader: View {
    let track: TrackVM
    @EnvironmentObject var store: SocketClient
    @State private var renaming = false
    private var selected: Bool { store.selectedTrackId == track.id }

    private func bind(_ path: String, _ v: Double) -> Binding<Double> {
        Binding(get: { v }, set: { store.set("track/\(track.id)/\(path)", $0) })
    }

    var body: some View {
        VStack(spacing: 5) {
            EditableLabel(text: track.name, editing: $renaming) { store.renameTrack(track.id, $0) }
                .frame(maxWidth: .infinity).foregroundColor(selected ? Palette.text : Palette.text2)
                .onTapGesture(count: 2) { renaming = true }
            Dial(value: bind("controls/pan", track.pan), range: -1...1, size: 24)
            HStack(spacing: 3) {                                   // fader + VU live (crête de la piste)
                VFader(gain: bind("controls/gain", track.gain))
                BallisticVU(level: store.trackLevels[track.id] ?? 0)
            }
            .frame(maxHeight: .infinity)
            EditableNumber(value: track.gain, range: 0...4, display: { dbString($0) },
                           toField: { $0 > 0 ? String(format: "%.1f", 20 * log10($0)) : "-inf" },
                           fromField: { Double($0).map { pow(10, $0 / 20) } },
                           commit: { store.set("track/\(track.id)/controls/gain", $0) })
            HStack(spacing: 3) {
                Button(track.mute ? "M" : "m") { store.set("track/\(track.id)/controls/mute", !track.mute) }
                    .buttonStyle(.borderedProminent).tint(track.mute ? .red : .gray)
                Button(track.solo ? "S" : "s") { store.set("track/\(track.id)/controls/solo", !track.solo) }
                    .buttonStyle(.borderedProminent).tint(track.solo ? .yellow : .gray)
            }
            .font(.system(size: 8, weight: .bold)).controlSize(.mini)
        }
        .padding(.vertical, 8).padding(.horizontal, 5)
        .frame(width: Dims.stripW).frame(maxHeight: .infinity, alignment: .top)
        .background(selected ? Palette.selection : Color.clear)
        .overlay(selected ? Rectangle().stroke(Palette.accent.opacity(0.5), lineWidth: 1) : nil)
        .contentShape(Rectangle())
        .onTapGesture { store.selectTrack(track.id) }
        .contextMenu {        // long-press / clic droit : renommer · supprimer (verbes track.rename / track.remove)
            Button { renaming = true } label: { Label("Renommer", systemImage: "pencil") }
            Button(role: .destructive) { store.removeTrack(track.id) } label: { Label("Supprimer la piste", systemImage: "trash") }
        }
    }
}

/// Chaîne d'inserts réutilisable (piste ou bus master) : entête + menu +FX + cartes ordonnées.
struct FXChain: View {
    let target: FXLoc
    let inserts: [InsertVM]
    @EnvironmentObject var store: SocketClient

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("FX").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                AddFXButton(target: target)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(Array(inserts.enumerated()), id: \.element.id) { idx, ins in
                        InsertCard(target: target, insert: ins,
                                   canMoveUp: idx > 0, canMoveDown: idx < inserts.count - 1,
                                   onMove: { up in move(idx, up: up) })
                    }
                    if inserts.isEmpty {
                        Text("aucun insert").font(.system(size: 9)).foregroundColor(.secondary).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    /// échange un insert avec son voisin et pousse le nouvel ordre (insert.reorder).
    private func move(_ idx: Int, up: Bool) {
        var order = inserts.map { $0.id }
        let j = up ? idx - 1 : idx + 1
        guard order.indices.contains(idx), order.indices.contains(j) else { return }
        order.swapAt(idx, j)
        store.reorderInsert(target, order: order)
    }
}

/// Une carte d'insert dans la chaîne : type, bypass, suppression, et contrôles selon le type.
struct InsertCard: View {
    let target: FXLoc
    let insert: InsertVM
    var canMoveUp = false
    var canMoveDown = false
    var onMove: ((Bool) -> Void)? = nil
    var horizontal = false        // rack horizontal → réordonnancement gauche/droite au lieu de haut/bas
    @EnvironmentObject var store: SocketClient
    static let dynamicSubtypes: Set<String> = ["dcmp", "lmtr", "mcmp", "dynp", "mcph"]   // inserts à GR mesurée

    private func bindParam(_ name: String, _ def: Double) -> Binding<Double> {
        Binding(get: { insert.params[name] ?? def },
                set: { store.set("\(target.pathPrefix)/fx/\(insert.id)/params/\(name)", $0) })
    }
    private func pct(_ v: Double?) -> String { String(format: "%.0f%%", v ?? 0) }
    private var label: String {
        if insert.type == "au" {
            let nm = store.auCatalog.first { $0.subType == insert.subType }?.name
            return (nm ?? insert.subType ?? "AU").uppercased()
        }
        return ["eq": "EQ", "reverb": "REVERB", "delay": "DELAY", "distortion": "DRIVE"][insert.type] ?? insert.type.uppercased()
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(Typo.label).tracking(0.5).foregroundColor(Palette.text).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                // réordonnancement dans la chaîne (insert.reorder)
                Button { onMove?(true) } label: { Image(systemName: horizontal ? "chevron.left" : "chevron.up").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).disabled(!canMoveUp).help("plus tôt dans la chaîne")
                Button { onMove?(false) } label: { Image(systemName: horizontal ? "chevron.right" : "chevron.down").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(.secondary).disabled(!canMoveDown).help("plus tard dans la chaîne")
                Toggle("", isOn: Binding(get: { !insert.bypass },
                                         set: { store.setBypass(target, insertId: insert.id, !$0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().help("actif / bypass")
                Button { store.removeInsert(target, insertId: insert.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(.secondary)
            }
            controls
        }
        .padding(8)
        .card()
        .opacity(insert.bypass ? 0.5 : 1)
        .contextMenu {        // geste uniforme : bypass · réordre · supprimer (mêmes actions que les boutons de la carte)
            Button { store.setBypass(target, insertId: insert.id, !insert.bypass) } label: {
                Label(insert.bypass ? "Réactiver" : "Bypass", systemImage: insert.bypass ? "play.circle" : "pause.circle")
            }
            if canMoveUp { Button { onMove?(true) } label: { Label("Plus tôt dans la chaîne", systemImage: horizontal ? "arrow.left" : "arrow.up") } }
            if canMoveDown { Button { onMove?(false) } label: { Label("Plus tard dans la chaîne", systemImage: horizontal ? "arrow.right" : "arrow.down") } }
            Button(role: .destructive) { store.removeInsert(target, insertId: insert.id) } label: { Label("Supprimer l'effet", systemImage: "trash") }
        }
    }

    @ViewBuilder private var controls: some View {
        switch insert.type {
        case "eq":
            // GESTE = ÉDITION : 4 nœuds (un par bande) qu'on attrape sur la courbe sommée. Plus de sliders.
            EQNodeView(target: target, insert: insert).frame(height: horizontal ? 150 : 90)
            HStack(spacing: 7) {
                eqLegend(.blue, "low"); eqLegend(.accentColor, "low-mid")
                eqLegend(.green, "hi-mid"); eqLegend(.orange, "high")
            }.font(.system(size: 8)).foregroundColor(.secondary)
        case "reverb":
            HStack(spacing: 6) {
                ParamKnob(label: "mix", value: insert.params["mix"] ?? 30, range: 0...100, fmt: { pct($0) }) { setParam("mix", $0) }
            }
        case "delay":
            HStack(spacing: 6) {
                ParamKnob(label: "time", value: insert.params["time"] ?? 0.25, range: 0...2, fmt: { String(format: "%.2fs", $0) }) { setParam("time", $0) }
                ParamKnob(label: "fb", value: insert.params["feedback"] ?? 30, range: -100...100, fmt: { pct($0) }) { setParam("feedback", $0) }
                ParamKnob(label: "mix", value: insert.params["mix"] ?? 25, range: 0...100, fmt: { pct($0) }) { setParam("mix", $0) }
            }
        case "distortion":
            HStack(spacing: 6) {
                ParamKnob(label: "drive", value: insert.params["drive"] ?? -6, range: -80...20, fmt: { String(format: "%.0fdB", $0) }) { setParam("drive", $0) }
                ParamKnob(label: "mix", value: insert.params["mix"] ?? 40, range: 0...100, fmt: { pct($0) }) { setParam("mix", $0) }
            }
        case "au":
            // UI GÉNÉRIQUE TANGIBLE : une grille de knobs bornés par le schéma auto-décrit de l'AU. Zéro code par effet.
            if insert.schema.isEmpty {
                Text("aucun paramètre").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 8) {
                    ForEach(insert.schema) { sp in
                        ParamKnob(label: sp.name, value: insert.params[sp.id] ?? sp.def,
                                  range: sp.min...max(sp.min + 0.0001, sp.max),
                                  fmt: { auFmt(sp, $0) }) { setParam(sp.id, $0) }
                    }
                }
            }
            // mètre de réduction de gain (compresseur/limiteur/multibande) — on VOIT le comp travailler
            if Self.dynamicSubtypes.contains(insert.subType ?? "") {
                GRMeterView(gr: store.gainReduction[insert.id] ?? 0).padding(.top, 4)
            }
        default: EmptyView()
        }
    }

    private func eqLegend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 2) { Circle().fill(c).frame(width: 6, height: 6); Text(t) }
    }
    private func setParam(_ name: String, _ v: Double) { store.set("\(target.pathPrefix)/fx/\(insert.id)/params/\(name)", v) }
    private func auFmt(_ sp: InsertParamSpec, _ v: Double) -> String {
        let s = abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        return sp.unit.isEmpty ? s : "\(s) \(sp.unit)"
    }
}

/// Knob générique tangible : on tourne pour régler un param borné (min…max), avec label + valeur. Geste = sens.
struct ParamKnob: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var fmt: (Double) -> String
    let onChange: (Double) -> Void
    var body: some View {
        VStack(spacing: 3) {
            Dial(value: Binding(get: { value }, set: { onChange($0) }), range: range, size: 40)
            // labels d'AU parfois longs (« Threshold », « Master Gain ») : 2 lignes + réduction,
            // hauteur fixe → pas de reflow de la grille, et le nom complet en infobulle.
            Text(label).font(.system(size: 8)).foregroundColor(.secondary)
                .lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
                .frame(height: 20, alignment: .top).help(label)
            EditableNumber(value: value, range: range, display: fmt,
                           toField: { String(format: abs($0) >= 100 ? "%.0f" : "%.2f", $0) },
                           fromField: { Double($0) }, commit: onChange)
        }
        .frame(width: 58)
    }
}

/// Bargraph de crête vertical (échelle dB) pour les VU live.
struct VUBar: View {
    var level: Double        // crête linéaire 0..1
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let db = level > 0.0001 ? 20 * log10(level) : -120
            let frac = min(1, max(0, (db + 60) / 60))      // échelle -60 dB … 0 dB
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.black.opacity(0.55))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: h * CGFloat(frac))
            }
        }
        .frame(width: 5)
    }
}

/// Mini-tranche MASTER de la section mix : fader + VU stéréo live + LUFS à la demande. Sélectionnable → son rack à gauche.
/// (Le master est un canal comme un autre : sa chaîne FX vit dans le rack, pas empilée ici.)
struct MasterMini: View {
    @EnvironmentObject var store: SocketClient
    private var selected: Bool { store.selectedChannel == .bus("master") }

    var body: some View {
        VStack(spacing: 5) {
            Button { store.selectMaster() } label: {
                Text("MASTER").font(.system(size: 9, weight: .bold)).frame(maxWidth: .infinity)
                    .foregroundColor(selected ? .white : .secondary)
            }.buttonStyle(.plain)
            HStack(spacing: 3) {                              // fader master + VU stéréo L/R live
                VFader(gain: Binding(get: { store.master.gain }, set: { store.set("bus/master/controls/gain", $0) }))
                BallisticVU(level: store.masterL)
                BallisticVU(level: store.masterR)
            }
            .frame(maxHeight: .infinity)
            Text(dbString(store.master.gain)).font(.system(size: 8)).monospacedDigit().foregroundColor(.secondary)
            // RADAR LOUDNESS R128 : momentary/short-term/true-peak LIVE + integrated/LRA à la demande
            ProLoudnessMeter(momentary: store.momentary, shortTerm: store.shortTerm, truePeak: store.truePeak,
                             integrated: store.loudness?.integrated ?? store.metrics?.lufs ?? -120,
                             lra: store.loudness?.lra ?? 0)
                .frame(height: 40)
            HStack(spacing: 4) {
                Button { store.fetchLoudness(); store.scheduleAnalyze() } label: {
                    Image(systemName: store.loudnessLoading ? "hourglass" : "gauge.with.dots.needle.bottom.50percent")
                }.buttonStyle(.bordered).controlSize(.mini).disabled(store.loudnessLoading).help("mesurer la loudness (integrated/LRA)")
                Button { store.normalizeMaster(to: -16) } label: { Text("→-16").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.bordered).controlSize(.mini).help("normaliser à -16 LUFS")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 6)
        .frame(width: 88).frame(maxHeight: .infinity, alignment: .top)
        .background(selected ? Palette.selection : Palette.raised)
        .overlay(selected ? Rectangle().stroke(Palette.accent.opacity(0.5), lineWidth: 1) : nil)
        .contentShape(Rectangle())
        .onTapGesture { store.selectMaster() }
    }
}

/// Mètre LUFS vertical : échelle -36..0 LU, repère -16 (cible boucle IA).
struct LUFSMeter: View {
    var metrics: Metrics?
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, w = geo.size.width
            let lo = -36.0, hi = 0.0
            let y: (Double) -> Double = { v in (1 - (min(hi, max(lo, v)) - lo) / (hi - lo)) * h }
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.5))
                if let m = metrics, m.lufs.isFinite {
                    let top = y(m.lufs)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.green, .yellow, .orange],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(height: max(0, h - top))
                }
                // repère -16 (cible boucle IA)
                Path { p in p.move(to: CGPoint(x: 0, y: y(-16))); p.addLine(to: CGPoint(x: w, y: y(-16))) }
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                // graduations
                ForEach([0, -16, -36], id: \.self) { v in
                    Text(verbatim: "\(v)").font(.system(size: 7)).foregroundColor(.white.opacity(0.55))
                        .position(x: w - 9, y: max(6, min(h - 6, y(Double(v)))))
                }
            }
        }
    }
}

// MARK: - petits helpers

struct LabeledMini<Content: View>: View {
    var label: String; var value: String; @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text(label).lineLimit(1).truncationMode(.tail)
                Spacer()
                Text(value).monospacedDigit().lineLimit(1).layoutPriority(1)
            }
            .font(.system(size: 9)).foregroundColor(.secondary)
            content
        }
    }
}

private func panLabel(_ p: Double) -> String {
    if abs(p) < 0.02 { return "C" }
    return p < 0 ? "L\(Int(-p * 100))" : "R\(Int(p * 100))"
}
private func logFrac(_ f: Double) -> Double { (log10(max(20, f)) - log10(20)) / (log10(20_000) - log10(20)) }
private func logFreq(_ x: Double) -> Double { pow(10, log10(20) + x * (log10(20_000) - log10(20))) }
