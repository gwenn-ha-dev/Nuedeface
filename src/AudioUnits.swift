// Nuedeface — registre des Audio Units Apple (insert générique « au »).
//
// Un seul type d'insert "au" expose N'IMPORTE QUELLE AU effet Apple : on lit son AUParameterTree
// et on projette ses params sous track/<id>/fx/<insertId>/params/<identifier>, avec unit/min/max/
// default ISSUS de l'AU → describe/getState les rendent pilotables à froid, sans coder chaque effet.
//
// Instanciation SYNCHRONE via AVAudioUnitEffect(audioComponentDescription:) (classe de base des
// wrappers typés eq/reverb/delay/distortion) — pas d'async/sémaphore. Le subType voyage en 4cc
// lisible ("dcmp") au bord du protocole, converti en OSType seulement ici. Schéma déterministe par
// subType (même AU → mêmes params) → caché, et undo-safe (le refold reproduit le même schéma).

import Foundation
import AVFoundation

enum AU {
    /// Schéma d'un paramètre d'AU, projeté sur notre surface (clé = identifier stable de l'AUParameter).
    struct ParamSpec { let id: String; let name: String; let unit: String; let min: Double; let max: Double; let def: Double }

    // "dcmp" -> OSType (4 octets big-endian ; complété par des espaces si < 4 caractères, convention OSType).
    static func fourCC(_ s: String) -> OSType {
        var bytes = Array(s.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }
    static func string(_ code: OSType) -> String {
        let b = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return (String(bytes: b, encoding: .macOSRoman) ?? "?").trimmingCharacters(in: .whitespaces)
    }

    /// Instancie une AU effet Apple par subType. Synchrone. nil si subType inconnu.
    static func make(_ subType: String) -> AVAudioUnit? {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: fourCC(subType),
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    // INVARIANT DE QUEUE : catalogCache/schemaCache sont peuplés depuis applyQ uniquement (describe, insert.add,
    // snapshot) — jamais en concurrence. Caches statiques sans lock par conception ; un appelant hors applyQ
    // devrait introduire une synchro.
    // Catalogue des effets Apple installés (subType 4cc + nom lisible), énuméré une fois puis caché.
    private static var catalogCache: [(subType: String, name: String)]?
    static func catalog() -> [(subType: String, name: String)] {
        if let c = catalogCache { return c }
        let d = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0,
                                          componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
        let comps = AVAudioUnitComponentManager.shared().components(matching: d)
            .filter { $0.manufacturerName == "Apple" }
            .map { (subType: string($0.audioComponentDescription.componentSubType), name: $0.name) }
            .sorted { $0.name < $1.name }
        catalogCache = comps
        return comps
    }

    /// Ce subType correspond-il à une AU effet Apple installée ?
    static func exists(_ subType: String) -> Bool { catalog().contains { $0.subType == subType } }

    // Schéma des params d'un subType (déterministe → caché). def = valeur d'usine à l'instanciation.
    private static var schemaCache: [String: [ParamSpec]] = [:]
    static func schema(_ subType: String) -> [ParamSpec] {
        if let s = schemaCache[subType] { return s }
        guard let node = make(subType), let tree = node.auAudioUnit.parameterTree else {
            schemaCache[subType] = []; return []
        }
        let specs = tree.allParameters.map { p in
            ParamSpec(id: p.identifier, name: p.displayName, unit: unitName(p.unit),
                      min: Double(p.minValue), max: Double(p.maxValue), def: Double(p.value))
        }
        schemaCache[subType] = specs
        return specs
    }

    /// Nom court d'unité pour describe/UI (vide = générique/sans unité).
    static func unitName(_ u: AudioUnitParameterUnit) -> String {
        switch u {
        case .decibels:               return "dB"
        case .hertz:                  return "Hz"
        case .percent, .equalPowerCrossfade: return "%"
        case .seconds:                return "s"
        case .milliseconds:           return "ms"
        case .linearGain:             return "lin"
        case .pan:                    return "pan"
        case .degrees, .phase:        return "°"
        case .cents, .absoluteCents, .relativeSemiTones: return "cents"
        case .ratio:                  return "ratio"
        case .boolean:                return "bool"
        case .indexed:                return "idx"
        case .rate:                   return "rate"
        case .BPM:                    return "bpm"
        case .beats:                  return "beats"
        case .sampleFrames:           return "smp"
        case .octaves:                return "oct"
        case .midiNoteNumber, .midiController: return "midi"
        case .meters:                 return "m"
        default:                      return ""
        }
    }
}
