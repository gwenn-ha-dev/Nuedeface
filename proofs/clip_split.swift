// Nuedeface — proof : clip.split est TRANSPARENT (audio continu, sample-exact).
//   swiftc proofs/clip_split.swift -o /tmp/split && /tmp/split
//
// Le placement d'un clip est pur : timeline[start + j] = source[offset + j] pour j ∈ [0, duration[.
// On vérifie qu'un clip [start, offset, dur] rendu d'un bloc == les DEUX pièces issues d'un split à T
// (gauche [start, offset, T-start] + droite [T, offset+(T-start), dur-(T-start)]). Aucune discontinuité,
// aucun trou, aucun recouvrement : c'est exactement le calcul d'Engine (case "clip.split").

import Foundation

// source « identité » : source[i] = i (chaque sample est traçable)
let assetLen = 1000
let source = (0..<assetLen).map { Float($0) }

struct Clip { var start: Int; var offset: Int; var dur: Int }

// place une liste de clips dans une timeline (longueur = max start+dur), comme Engine.trackBuffer (sans fade/gain)
func place(_ clips: [Clip], _ length: Int) -> [Float] {
    var out = [Float](repeating: -1, count: length)   // -1 = trou (jamais écrit)
    for c in clips {
        for j in 0..<c.dur {
            let from = c.offset + j, to = c.start + j
            guard from >= 0, from < source.count, to >= 0, to < length else { continue }
            out[to] = source[from]
        }
    }
    return out
}

func runCase(_ label: String, start: Int, offset: Int, dur: Int, at: Int) -> Bool {
    let length = start + dur
    let whole = place([Clip(start: start, offset: offset, dur: dur)], length)
    // split à la position timeline `at`
    let leftDur = at - start
    let left  = Clip(start: start, offset: offset, dur: leftDur)
    let right = Clip(start: at, offset: offset + leftDur, dur: dur - leftDur)
    let split = place([left, right], length)

    // transparence = le rendu des deux pièces est sample-pour-sample identique au clip entier
    // (mêmes valeurs ET mêmes zones vides : whole contient déjà -1 dans [0,start[, c'est du silence légitime)
    let identical = whole == split
    print("  [\(label)] start=\(start) offset=\(offset) dur=\(dur) split@\(at)  → identique au clip entier : \(identical)")
    return identical
}

print("clip.split transparent ?")
var ok = true
ok = runCase("simple",       start: 0,   offset: 0,   dur: 800, at: 300) && ok
ok = runCase("offset+start", start: 100, offset: 50,  dur: 600, at: 450) && ok
ok = runCase("split tardif", start: 0,   offset: 0,   dur: 800, at: 799) && ok
ok = runCase("split précoce", start: 200, offset: 10, dur: 500, at: 201) && ok

if ok { print("\nPASS ✓  split = audio continu sample-exact (les deux pièces reconstituent l'original)") }
else  { print("\nFAIL ✗  le split introduit un trou ou un décalage"); exit(1) }
