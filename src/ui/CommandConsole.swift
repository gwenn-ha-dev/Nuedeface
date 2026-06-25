// Nuedeface — console de commandes : l'humain parle le protocole socket DIRECTEMENT.
//
// Thèse du projet : « one surface, three clients — you, an AI, a script ». Jusqu'ici l'humain était le
// seul à NE PAS pouvoir parler le protocole (limité aux gestes que l'UI expose). Cette fenêtre comble le
// trou : un REPL sur le MÊME socket que Claude/un script, branché sur la MÊME réplique → on tape une commande
// et on voit le fader bouger. Auto-documenté par `describe` : autocomplétion des verbes, des paths (depuis
// l'état répliqué) et affichage de la signature du verbe courant. Saisie au choix :
//   • raccourci :  set track/t1/controls/gain 0.5      |  clip.add trackId=t1 asset=a1 start=0
//   • JSON brut :  {"cmd":"normalize","target":-16}
// La réponse {ok/error} est affichée pretty-printée ; les deltas des autres clients restent dans le feed.

import SwiftUI
import AppKit

private struct ConsoleLine: Identifiable {
    let id = UUID()
    enum Kind { case input, ok, error, info }
    let kind: Kind
    let text: String
}

struct CommandConsole: View {
    @EnvironmentObject var store: SocketClient

    @State private var input = ""
    @State private var lines: [ConsoleLine] = [
        ConsoleLine(kind: .info, text: "Console socket — tape un verbe (ex. `describe`, `analyze`, `normalize target=-16`)\n"
            + "ou du JSON brut {\"cmd\":…}.  ⇥ complète · ↑ ↓ historique · ⎋ ferme les suggestions.")
    ]
    @State private var history: [String] = []
    @State private var historyIdx = 0
    @State private var suggestions: [String] = []
    @State private var selSug = 0

    // dérivé de `describe` (chargé à l'ouverture) : verbes + args par verbe (pour signature + positionnel).
    @State private var verbs: [String] = []
    @State private var verbArgs: [String: [String]] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            if !suggestions.isEmpty { suggestionBar }
            signatureHint
            inputRow
        }
        .background(Palette.bg)
        .onAppear { focused = true; loadSchema() }
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(color(line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: lines.count) { _ in
                if let last = lines.last { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func color(_ k: ConsoleLine.Kind) -> Color {
        switch k {
        case .input: return Palette.accent
        case .ok:    return Palette.text
        case .error: return Palette.clip
        case .info:  return Palette.text2
        }
    }

    // MARK: suggestions + signature

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(suggestions.prefix(12).enumerated()), id: \.offset) { i, s in
                    Text(s)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(i == selSug ? Palette.selection : Palette.panel)
                        .foregroundColor(i == selSug ? Palette.text : Palette.text2)
                        .clipShape(RoundedRectangle(cornerRadius: Dims.radiusS))
                        .onTapGesture { apply(s) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .background(Palette.surface)
    }

    @ViewBuilder private var signatureHint: some View {
        if let sig = currentSignature {
            Text(sig).font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 4)
        }
    }

    /// Signature du verbe en cours de frappe (issue de describe) : « clip.add · trackId asset start … ».
    private var currentSignature: String? {
        guard let verb = tokens.first, verbs.contains(verb) else { return nil }
        let args = verbArgs[verb] ?? []
        return args.isEmpty ? "\(verb) · (sans argument)" : "\(verb) · " + args.joined(separator: " ")
    }

    // MARK: input

    private var inputRow: some View {
        HStack(spacing: 6) {
            Text("›").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(Palette.accent)
            TextField("commande…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Palette.text)
                .focused($focused)
                .onSubmit { submit() }
                .onChange(of: input) { _ in recomputeSuggestions() }
                .onKeyPress(.tab) { acceptSuggestion(); return .handled }
                .onKeyPress(.upArrow) { moveUp(); return .handled }
                .onKeyPress(.downArrow) { moveDown(); return .handled }
                .onKeyPress(.escape) { suggestions = []; return .handled }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.surface)
    }

    // MARK: parsing / envoi

    private var tokens: [String] { input.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }

    private func submit() {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        guard let (cmd, args) = parse(line) else {
            append(.input, "› " + line); append(.error, "ligne illisible — JSON invalide, ou verbe manquant"); reset(); return
        }
        append(.input, "› " + line)
        history.append(line); historyIdx = history.count
        reset()
        store.call(cmd, args) { reply in
            DispatchQueue.main.async {
                var r = reply; r["id"] = nil
                let ok = (reply["ok"] as? Bool) ?? false
                append(ok ? .ok : .error, pretty(r))
            }
        }
    }

    private func reset() { input = ""; suggestions = []; selSug = 0 }

    /// Parse une ligne en (cmd, args). JSON brut si elle commence par `{` ; sinon `verbe clé=val …`
    /// (les jetons sans `=` sont positionnels, mappés aux args du verbe via describe). nil = illisible.
    private func parse(_ line: String) -> (String, [String: Any])? {
        if line.hasPrefix("{") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = obj["cmd"] as? String else { return nil }
            var args = obj; args["cmd"] = nil; args["id"] = nil
            return (cmd, args)
        }
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return nil }
        var args: [String: Any] = [:]
        var positional: [String] = []
        for tok in parts.dropFirst() {
            if let eq = tok.firstIndex(of: "=") {
                args[String(tok[..<eq])] = coerce(String(tok[tok.index(after: eq)...]))
            } else { positional.append(tok) }
        }
        let names = verbArgs[cmd] ?? fallbackArgs[cmd] ?? []
        for (i, val) in positional.enumerated() where i < names.count { args[names[i]] = coerce(val) }
        return (cmd, args)
    }

    /// Coercition d'un jeton texte → type JSON : bool, entier, réel, ou chaîne (guillemets pour forcer la chaîne).
    private func coerce(_ s: String) -> Any {
        if s == "true" { return true }
        if s == "false" { return false }
        if let i = Int(s) { return i }
        if let d = Double(s.replacingOccurrences(of: ",", with: ".")) { return d }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { return String(s.dropFirst().dropLast()) }
        return s
    }

    private func pretty(_ obj: [String: Any]) -> String {
        // .withoutEscapingSlashes : les paths (track/t1/controls/gain) s'affichent lisibles, pas « track\/t1\/… ».
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) { return s }
        return "\(obj)"
    }

    private func append(_ kind: ConsoleLine.Kind, _ text: String) {
        lines.append(ConsoleLine(kind: kind, text: text))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }   // borne mémoire/transcript
    }

    // MARK: autocomplétion

    private func recomputeSuggestions() {
        selSug = 0
        let toks = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let first = toks.first else { suggestions = []; return }
        if toks.count <= 1 {                                   // on tape le VERBE
            let p = first.lowercased()
            suggestions = p.isEmpty ? [] : verbs.filter { $0.lowercased().hasPrefix(p) }.sorted()
            return
        }
        let verb = first
        let cur = toks.last ?? ""
        if cur.contains("=") { suggestions = []; return }      // valeur d'un clé=val : pas de suggestion
        if verb == "set" {                                     // paths depuis l'état répliqué (le verbe le plus utilisé)
            suggestions = settablePaths().filter { cur.isEmpty || $0.hasPrefix(cur) }
            return
        }
        // sinon : noms d'args restants du verbe, en `clé=`
        let used = Set(toks.dropFirst().compactMap { tok -> String? in
            guard let eq = tok.firstIndex(of: "=") else { return nil }
            return String(tok[..<eq])
        })
        let names = (verbArgs[verb] ?? fallbackArgs[verb] ?? []).map { cleanArg($0) }.filter { !used.contains($0) }
        suggestions = names.filter { cur.isEmpty || $0.hasPrefix(cur) }.map { "\($0)=" }
    }

    private func acceptSuggestion() {
        guard !suggestions.isEmpty else { return }
        apply(suggestions[min(selSug, suggestions.count - 1)])
    }

    private func apply(_ s: String) {
        var toks = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let completingVerb = toks.count <= 1
        if toks.isEmpty { toks = [s] } else { toks[toks.count - 1] = s }
        input = toks.joined(separator: " ")
        if completingVerb || !s.hasSuffix("=") { input += " " }   // verbe ou path complété → espace pour l'arg suivant
        recomputeSuggestions()
    }

    private func moveUp() {
        if suggestions.isEmpty { recallHistory(-1) } else { selSug = max(0, selSug - 1) }
    }
    private func moveDown() {
        if suggestions.isEmpty { recallHistory(1) } else { selSug = min(suggestions.count - 1, selSug + 1) }
    }
    private func recallHistory(_ dir: Int) {
        guard !history.isEmpty else { return }
        historyIdx = max(0, min(history.count, historyIdx + dir))
        input = historyIdx < history.count ? history[historyIdx] : ""
    }

    /// Paths réglables par `set`, construits depuis la réplique (donc toujours valides pour l'état courant).
    private func settablePaths() -> [String] {
        var p: [String] = []
        for t in store.tracks {
            let b = "track/\(t.id)/controls/"
            p += [b + "gain", b + "pan", b + "mute", b + "solo"]
            for ins in t.inserts { for k in ins.params.keys.sorted() { p.append("track/\(t.id)/fx/\(ins.id)/params/\(k)") } }
            for c in t.clips { p.append("track/\(t.id)/clips/\(c.id)/gain") }
        }
        for bus in store.buses {
            p += ["bus/\(bus.id)/controls/gain", "bus/\(bus.id)/controls/mute"]
            for ins in bus.inserts { for k in ins.params.keys.sorted() { p.append("bus/\(bus.id)/fx/\(ins.id)/params/\(k)") } }
        }
        return p
    }

    // MARK: describe

    private func loadSchema() {
        store.call("describe") { reply in
            guard let schema = reply["schema"] as? [String: Any] else { return }
            var vs = (schema["verbs"] as? [String]) ?? []
            var va: [String: [String]] = [:]
            // args : d'abord la section 'structure', puis les entrées top-level (analyze/loudness/…) qui portent 'args'
            if let structure = schema["structure"] as? [String: Any] {
                for (verb, def) in structure { if let args = (def as? [String: Any])?["args"] as? [String] { va[verb] = args } }
            }
            for verb in vs where va[verb] == nil {
                if let def = schema[verb] as? [String: Any], let args = def["args"] as? [String] { va[verb] = args }
            }
            if vs.isEmpty { vs = Array(va.keys) }
            DispatchQueue.main.async { self.verbs = vs.sorted(); self.verbArgs = va }
        }
    }

    /// Nettoie un nom d'arg de describe pour l'usage clé=val : « start(s) » → « start », « trackId OU busId » → « trackId ».
    private func cleanArg(_ a: String) -> String {
        var s = a
        if let r = s.range(of: " ") { s = String(s[..<r.lowerBound]) }   // coupe « OU … » / décorations après espace
        if let r = s.firstIndex(where: { $0 == "(" || $0 == "?" }) { s = String(s[..<r]) }
        return s
    }

    /// Args des verbes que describe ne détaille pas en 'structure' (positionnel + autocomplétion).
    private let fallbackArgs: [String: [String]] = [
        "set": ["path", "value"], "import": ["path"],
        "project.save": ["path"], "project.load": ["path"],
        "transport.seek": ["t"], "transport.play": ["from", "to", "loop"], "subscribe": ["on"],
        "ab.capture": ["slot"], "ab.recall": ["slot"],
        "automation.enable": ["path"], "automation.disable": ["path"],
        "automation.point.add": ["path", "t", "v", "curve"],
        "automation.point.move": ["path", "pointId", "t", "v", "curve"],
        "automation.point.remove": ["path", "pointId"],
        "master.envelope": ["bucket"],
    ]
}
