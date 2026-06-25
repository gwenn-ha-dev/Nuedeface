// Nuedeface — outil autonome : énumère les Audio Units natives installées (effets, etc.).
//   swiftc tools/list_audio_units.swift -o /tmp/lau && /tmp/lau
// Sert à cartographier ce qu'Apple offre comme DSP/traitement exposable dans notre API socket.

import AVFoundation

func fourCC(_ code: UInt32) -> String {
    let b = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: b, encoding: .macOSRoman) ?? "?"
}

let mgr = AVAudioUnitComponentManager.shared()

func dump(_ title: String, _ type: OSType) {
    let d = AudioComponentDescription(componentType: type, componentSubType: 0,
                                      componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
    let comps = mgr.components(matching: d).sorted { $0.name < $1.name }
    let apple = comps.filter { $0.manufacturerName == "Apple" }
    print("\n=== \(title) — \(apple.count) Apple (sur \(comps.count) au total) ===")
    for c in apple {
        let sub = fourCC(c.audioComponentDescription.componentSubType)
        print(String(format: "  %-28s  subType=%@", (c.name as NSString).utf8String!, sub))
    }
}

dump("kAudioUnitType_Effect", kAudioUnitType_Effect)
dump("kAudioUnitType_MusicEffect", kAudioUnitType_MusicEffect)
dump("kAudioUnitType_Mixer", kAudioUnitType_Mixer)
dump("kAudioUnitType_FormatConverter", kAudioUnitType_FormatConverter)
