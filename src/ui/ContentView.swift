// Nuedeface — la coquille : barre de statut + timeline (haut) / console (bas), façon GarageBand.

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: SocketClient

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            TransportBar()
            FocusWorkspace()           // les 3 zones logiques à focus (une scène + 2 rails vivants)
        }
        .frame(minWidth: 620, minHeight: 420)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { if let t = store.toast { ToastView(toast: t).padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity)) } }
        .animation(Ballistics.smooth, value: store.toast?.id)
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: SocketClient
    @State private var showActivity = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(store.connected ? Palette.ok : Palette.clip).frame(width: 9, height: 9)
            // conscience de sauvegarde : nom de projet + point « modifié » (C)
            HStack(spacing: 4) {
                Image(systemName: "doc").font(.system(size: 10)).foregroundColor(.secondary)
                Text(store.projectName).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.text)
                if store.dirty { Circle().fill(Palette.hot).frame(width: 6, height: 6).help("modifications non enregistrées") }
            }
            Text("rev \(store.rev)").font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
            Spacer()
            // feed d'activité attribué (B) — « je regarde l'IA bosser »
            Button { showActivity.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    if let d = store.lastDelta { Text(d).font(.system(size: 10)).lineLimit(1).frame(maxWidth: 160, alignment: .leading) }
                }.font(.system(size: 11)).foregroundColor(.secondary)
            }.buttonStyle(.plain).help("historique des actions (humain & IA)")
            .popover(isPresented: $showActivity, arrowEdge: .bottom) { ActivityFeed().environmentObject(store) }
            Divider().frame(height: 14)
            // A/B : capture deux versions, bascule pour comparer à l'oreille (recall REMPLACE l'état)
            Text("A/B").font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            ForEach(["A", "B"], id: \.self) { slot in
                Menu(slot) {
                    Button("capturer \(slot)") { store.abCapture(slot) }
                    Button("rappeler \(slot)") { store.abRecall(slot) }
                }.font(.system(size: 10, weight: .bold)).menuStyle(.borderlessButton).fixedSize()
            }
            Divider().frame(height: 14)
            Button("+ piste") { store.addTrack() }.font(.system(size: 11))
            Button("undo") { store.undo() }.font(.system(size: 11))
            Button("redo") { store.redo() }.font(.system(size: 11))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .lit(Palette.surface2)
        .overlay(Rectangle().fill(Palette.stroke).frame(height: 0.5), alignment: .bottom)
    }
}

/// Toast éphémère (échec rouge / succès vert) — l'app n'est plus muette.
struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(toast.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill((toast.isError ? Palette.clip : Palette.ok).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.2)))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}

/// Feed d'activité : qui a fait quoi, quand. Les actions de l'IA/scripts (≠ ce client) en accent.
struct ActivityFeed: View {
    @EnvironmentObject var store: SocketClient
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("ACTIVITÉ").sectionLabel(); Spacer(); Text("\(store.activity.count)").font(Typo.value).foregroundColor(.secondary) }
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if store.activity.isEmpty {
                Text("aucune action encore — pilote l'app (ou laisse Claude le faire)").font(.system(size: 10))
                    .foregroundColor(.secondary).padding(16).frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.activity.reversed()) { e in
                            HStack(spacing: 8) {
                                Circle().fill(e.mine ? Palette.text2 : Palette.accent).frame(width: 6, height: 6)
                                Text(e.who).font(.system(size: 9, weight: .bold)).foregroundColor(e.mine ? Palette.text2 : Palette.accent).frame(width: 56, alignment: .leading)
                                Text(e.detail).font(.system(size: 10)).foregroundColor(Palette.text).lineLimit(1)
                                Spacer()
                                Text(hms(e.date)).font(Typo.value).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            Divider().opacity(0.3)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }
        .frame(width: 360)
    }
    private func hms(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }
}

struct TransportBar: View {
    @EnvironmentObject var store: SocketClient

    private func metric(_ label: String, _ v: Double, warn: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
            Text(v > -120 ? String(format: "%.1f", v) : "—").font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(warn && v > -1 ? Palette.clip : Palette.text)
        }
        .frame(width: 40)
    }

    var body: some View {
        HStack(spacing: 18) {
            // gros bouton lecture (accent ; vert pendant la lecture) + retour
            Button { store.returnToStart() } label: { Image(systemName: "backward.end.fill").font(.system(size: 15)) }
                .buttonStyle(.plain).foregroundColor(Palette.text2)
            Button { store.togglePlay() } label: {
                ZStack {
                    Circle().fill(store.playing ? Color.green : Palette.accent)
                        .shadow(color: (store.playing ? Color.green : Palette.accent).opacity(0.6), radius: store.playing ? 7 : 3)
                    Image(systemName: store.playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white).offset(x: store.playing ? 0 : 1)
                }.frame(width: 38, height: 38)
            }
            .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])

            // boucle : glisser sur la règle de la timeline définit la zone ; ce bouton l'active/coupe.
            Button { store.toggleLoop() } label: {
                Image(systemName: "repeat").font(.system(size: 15, weight: .bold))
                    .foregroundColor(store.loopOn ? Palette.accent : Palette.text2)
            }
            .buttonStyle(.plain).keyboardShortcut("l", modifiers: [])
            .help("boucle (L) — glisse sur la règle pour définir la zone ; clic droit pour l'effacer")
            .contextMenu { Button("Effacer la zone de boucle") { store.clearLoop() } }

            // temps, en grand
            Text(timeStr(store.playhead)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundColor(store.playing ? .green : Palette.text)

            Divider().frame(height: 30)

            // VU stéréo master live + loudness en direct (l'info qui vivait dans le rail master)
            HStack(spacing: 8) {
                HStack(spacing: 3) { BallisticVU(level: store.masterL); BallisticVU(level: store.masterR) }
                    .frame(width: 14, height: 32)
                Text("MASTER").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                    .rotationEffect(.degrees(-90)).fixedSize().frame(width: 12)
            }
            metric("S", store.shortTerm); metric("M", store.momentary); metric("TP", store.truePeak, warn: true)

            Spacer()

            HStack(spacing: 5) {
                Circle().fill(store.playing ? Color.green : Palette.text2).frame(width: 6, height: 6)
                Text(store.playing ? "lecture" : "preview live").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            }
            Button { exportMix() } label: {
                Label("Exporter", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent).controlSize(.small).tint(Palette.accent)
            .help("Exporter le mix (wav / m4a) — ⌘E")
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(LinearGradient(colors: [Palette.surface2, Palette.track], startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(store.playing ? Color.green.opacity(0.5) : Palette.accent.opacity(0.3)).frame(height: 1.5), alignment: .bottom)
    }

    /// Panneau d'enregistrement natif → rend et écrit le mix (extension .wav ou .m4a). Même chemin que ⌘E.
    private func exportMix() {
        let p = NSSavePanel()
        p.title = "Exporter le mix"
        p.nameFieldStringValue = store.cleanProjectName + ".m4a"
        p.message = "Extension .wav ou .m4a (AAC). Le mix complet est rendu, traînes d'effets incluses."
        if p.runModal() == .OK, let url = p.url {
            store.export(path: url.path, format: url.pathExtension.lowercased() == "wav" ? "wav" : "m4a")
        }
    }
}

func timeStr(_ t: Double) -> String {
    let s = max(0, t); return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s - Double(Int(s))) * 10))
}
