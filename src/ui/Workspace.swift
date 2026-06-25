// Nuedeface — l'espace de travail à ONGLETS (Waves · Mix · Master).
//
// Trois zones logiques = trois lentilles sur le même document. De VRAIS onglets en haut ; la zone active
// occupe TOUTE la fenêtre dessous (pas de rails qui rognent l'espace). Le focus reste AUTO : sélectionner
// un clip bascule sur Waves, une piste sur Mix, le master sur Master — l'onglet suit la manipulation, et
// 1/2/3 basculent aussi. Le cache de waveforms et l'état de zoom sont détenus ici → survivent au changement
// d'onglet (pas de re-décodage, pas de zoom réinitialisé).

import SwiftUI

struct FocusWorkspace: View {
    @EnvironmentObject var store: SocketClient
    @StateObject private var waveCache = WaveformCache()
    @StateObject private var tlState = TimelineViewState()

    var body: some View {
        VStack(spacing: 0) {
            ZoneTabBar()
            activeZone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var activeZone: some View {
        switch store.stageZone {
        case .waves:  TimelineView(cache: waveCache, view: tlState)
        case .mix:    MixStage()
        case .master: MasterStage()
        }
    }
}

// MARK: - barre d'onglets (en haut, l'onglet actif « attaché » au contenu)

struct ZoneTabBar: View {
    @EnvironmentObject var store: SocketClient

    var body: some View {
        HStack(spacing: 0) {
            tab(.waves,  "Waves",  "waveform",                                "1")
            tab(.mix,    "Mix",    "slider.vertical.3",                       "2")
            tab(.master, "Master", "gauge.with.dots.needle.bottom.50percent", "3")
            Spacer(minLength: 0)
            Button { store.togglePin(store.stageZone) } label: {
                Image(systemName: store.pinnedZone == nil ? "pin.slash" : "pin.fill").font(.system(size: 11))
                    .foregroundColor(store.pinnedZone == nil ? Palette.text2 : .accentColor)
            }
            .buttonStyle(.plain).padding(.trailing, 12)
            .help(store.pinnedZone == nil ? "épingler l'onglet (ne suit plus la sélection)" : "désépingler (auto)")
        }
        .background(Palette.bg)
        .overlay(Rectangle().fill(Palette.stroke).frame(height: 0.5), alignment: .bottom)
    }

    private func tab(_ z: Zone, _ title: String, _ icon: String, _ key: String) -> some View {
        let on = store.stageZone == z
        return Button { store.focus(z) } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(key).font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
            }
            .foregroundColor(on ? Palette.text : Palette.text2)
            .padding(.horizontal, 18).frame(height: 38)
            .background(on ? Palette.surface : Color.clear)                 // onglet actif = couleur du contenu (attaché)
            .overlay(alignment: .bottom) {                                  // indicateur d'onglet
                Rectangle().fill(on ? Palette.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [])
        .help("\(title) — touche \(key)")
    }
}

/// Bargraphe de crête minuscule (vert→jaune→rouge sur -60..0 dB) pour le sélecteur de canaux.
struct MiniLevel: View {
    var level: Double
    var body: some View {
        let db = level > 0.0001 ? 20 * log10(level) : -120
        let frac = min(1, max(0, (db + 60) / 60))
        return RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.5))
            .frame(width: 4, height: 26)
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(width: 4, height: 26 * CGFloat(frac))
            }
    }
}

// MARK: - scène MIX (focus objet)

/// Scène MIX : à gauche un SÉLECTEUR compact de canaux, au centre le rack du canal sélectionné EN GRAND, à
/// droite sa VRAIE tranche (fader/pan/VU/mute-solo). Un seul canal en grand → fin de la densité « 12 tranches ».
struct MixStage: View {
    @EnvironmentObject var store: SocketClient

    private var sel: (id: String, isTrack: Bool)? {
        switch store.selectedChannel {
        case .track(let id) where store.tracks.contains(where: { $0.id == id }): return (id, true)
        case .bus(let id) where id != "master" && store.buses.contains(where: { $0.id == id }): return (id, false)
        default: break
        }
        return store.tracks.first.map { ($0.id, true) }
    }
    private var channel: (loc: FXLoc, title: String, inserts: [InsertVM], output: String?)? {
        guard let s = sel else { return nil }
        if s.isTrack, let t = store.tracks.first(where: { $0.id == s.id }) { return (.track(s.id), t.name, t.inserts, t.output) }
        if let b = store.buses.first(where: { $0.id == s.id }) { return (.bus(s.id), b.name.uppercased(), b.inserts, b.output) }
        return nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ChannelSelector(selId: sel?.id ?? "").frame(width: 168)
            Divider().background(Palette.divider)
            ChannelDetail(channel: channel).frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            Divider().background(Palette.divider)
            if let s = sel { ChannelStrip(id: s.id, isTrack: s.isTrack).frame(width: 104) }
        }
        .lit(Palette.surface)
    }
}

/// Sélecteur de canaux : liste verticale compacte (pistes puis bus aux) + ajout. Clic = met ce canal en grand.
struct ChannelSelector: View {
    let selId: String
    @EnvironmentObject var store: SocketClient

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("CANAUX").sectionLabel(); Spacer() }
                .padding(.horizontal, 12).frame(height: 30).lit(Palette.header)
            Divider().background(Palette.divider)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.tracks) { t in row(t.id, t.name, store.trackLevels[t.id] ?? 0, t.mute, "piste", isBus: false) }
                    if !store.auxBuses.isEmpty {
                        HStack { Text("BUS").sectionLabel(); Spacer() }.padding(.horizontal, 4).padding(.top, 6)
                        ForEach(store.auxBuses) { b in row(b.id, b.name, store.busLevels[b.id] ?? 0, b.mute, "bus", isBus: true) }
                    }
                }
                .padding(8)
            }
            Divider().background(Palette.divider)
            HStack(spacing: 8) {
                Button { store.addTrack() } label: { Label("piste", systemImage: "plus") }
                Button { store.addBus() } label: { Label("bus", systemImage: "plus") }
            }
            .font(.system(size: 10)).buttonStyle(.bordered).controlSize(.small).padding(8)
        }
        .lit(Palette.surface2)
    }

    private func row(_ id: String, _ name: String, _ level: Double, _ mute: Bool, _ kind: String, isBus: Bool) -> some View {
        let on = id == selId
        return HStack(spacing: 8) {
            MiniLevel(level: level)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(on ? .white : Palette.text).lineLimit(1)
                Text(mute ? "muet" : kind).font(.system(size: 8)).foregroundColor(mute ? .red : .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 38).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Palette.accent.opacity(0.22) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Palette.accent.opacity(0.5) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if isBus { store.selectBus(id) } else { store.selectTrack(id) } }
        .hoverCursor(.pointingHand)
    }
}

/// Vraie tranche du canal sélectionné : fader + VU live + pan + mute/solo (piste) ou fader + mute (bus).
struct ChannelStrip: View {
    let id: String
    let isTrack: Bool
    @EnvironmentObject var store: SocketClient
    private func bind(_ path: String, _ v: Double) -> Binding<Double> { Binding(get: { v }, set: { store.set(path, $0) }) }

    var body: some View {
        Group {
            if isTrack, let t = store.tracks.first(where: { $0.id == id }) { trackStrip(t) }
            else if let b = store.buses.first(where: { $0.id == id }) { busStrip(b) }
            else { Color.clear }
        }
        .lit(Palette.raised)
    }

    private func trackStrip(_ t: TrackVM) -> some View {
        VStack(spacing: 8) {
            Text(t.name).font(.system(size: 11, weight: .bold)).lineLimit(1).foregroundColor(Palette.text)
            Dial(value: bind("track/\(id)/controls/pan", t.pan), range: -1...1, size: 30)
            Text("pan").font(.system(size: 8)).foregroundColor(.secondary)
            HStack(spacing: 4) {
                VFader(gain: bind("track/\(id)/controls/gain", t.gain))
                BallisticVU(level: store.trackLevels[id] ?? 0)
            }.frame(maxHeight: .infinity)
            Text(dbStr(t.gain)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
            HStack(spacing: 5) {
                Button(t.mute ? "M" : "m") { store.set("track/\(id)/controls/mute", !t.mute) }.buttonStyle(.borderedProminent).tint(t.mute ? .red : .gray)
                Button(t.solo ? "S" : "s") { store.set("track/\(id)/controls/solo", !t.solo) }.buttonStyle(.borderedProminent).tint(t.solo ? .yellow : .gray)
            }.font(.system(size: 9, weight: .bold)).controlSize(.small)
        }
        .padding(.vertical, 12).padding(.horizontal, 8).frame(maxHeight: .infinity, alignment: .top)
    }

    private func busStrip(_ b: BusVM) -> some View {
        VStack(spacing: 8) {
            Text(b.name).font(.system(size: 11, weight: .bold)).lineLimit(1).foregroundColor(Palette.text)
            Image(systemName: "arrow.triangle.merge").font(.system(size: 10)).foregroundColor(.secondary)
            HStack(spacing: 4) {
                VFader(gain: bind("bus/\(id)/controls/gain", b.gain))
                BallisticVU(level: store.busLevels[id] ?? 0)
            }.frame(maxHeight: .infinity)
            Text(dbStr(b.gain)).font(.system(size: 9).monospacedDigit()).foregroundColor(.secondary)
            Button(b.mute ? "M" : "m") { store.set("bus/\(id)/controls/mute", !b.mute) }
                .buttonStyle(.borderedProminent).tint(b.mute ? .red : .gray).font(.system(size: 9, weight: .bold)).controlSize(.small)
        }
        .padding(.vertical, 12).padding(.horizontal, 8).frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - scène MASTER

/// Scène MASTER : le rack du master EN GRAND (avec son spectre tonal) + la tranche master (radar loudness,
/// VU stéréo, normalize). Tout le « rendu final » à un seul endroit.
struct MasterStage: View {
    @EnvironmentObject var store: SocketClient
    var body: some View {
        HStack(spacing: 0) {
            ChannelDetail(channel: (.bus("master"), "MASTER", store.master.inserts, nil))
                .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            Divider().background(Palette.divider)
            MasterMini().frame(width: 96)
        }
        .lit(Palette.surface)
    }
}

private func dbStr(_ lin: Double) -> String { lin <= 0.0001 ? "-∞" : String(format: "%+.1f", 20 * log10(lin)) }
