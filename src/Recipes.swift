// Nuedeface — recettes (la couche qui rend l'IA *bonne* à froid, pas juste *capable*).
//
// Une recette = une intention nommée (« voix téléphone », « master podcast ») qui s'expanse en
// commandes PRIMITIVES déjà prouvées (insert.add + set + automation), chacune passée par doc.mutate
// → undo/redo et deltas gratuits, zéro nouveau chemin moteur. Les AU sont adressées par identifier
// FUZZY (on cherche le param par sous-chaîne) → robuste si Apple renomme/réordonne ses params.
//
// Le cookbook (describe.recipes/examples) expose ces intentions à un LLM : il lit les fréquences au
// lieu de les réinventer. C'est exactement le test de recette du concept (« mixe cette voix… seul »).

import Foundation

enum Recipes {
    /// Métadonnée d'une recette, exposée dans describe (cookbook) et au menu UI.
    struct Meta { let id: String; let name: String; let group: String; let description: String; let expands: String; let target: String }

    static let metas: [Meta] = [
        Meta(id: "telephone", name: "Voix téléphone", group: "Voix",
             description: "Voix passée au filtre « combiné téléphonique » : bande étroite medium + grain.",
             expands: "EQ bande passante ~300–3400 Hz (coupe graves + aigus, bosse medium) + distorsion légère",
             target: "track"),
        Meta(id: "voice-radio", name: "Voix radio", group: "Voix",
             description: "Voix « radio FM » : présence avant, médiums tenus, sifflantes domptées.",
             expands: "EQ présence (+ high-pass doux) + compresseur (dcmp) + de-ess statique (creux ~6,5 kHz). Trim des blancs : via detectSilence.",
             target: "track"),
        Meta(id: "master-podcast", name: "Master podcast / broadcast", group: "Master",
             description: "Chaîne de bus master + cible loudness en une commande (referme le mastering).",
             expands: "EQ légère + compresseur (dcmp) + limiteur (lmtr) sur le master, puis normalize −16 LUFS",
             target: "bus"),
        Meta(id: "ambience-duck", name: "Ambiance duckée sous voix", group: "Ambiance",
             description: "L'ambiance (cible) baisse automatiquement quand la voix (source) parle.",
             expands: "lane d'automation de gain sur la cible, pilotée par le RMS de la source (ducking baké)",
             target: "duck"),
    ]

    static func meta(_ id: String) -> Meta? { metas.first { $0.id == id } }

    enum Target { case track(String), bus(String), duck(source: String, target: String) }

    /// Plan d'expansion d'une recette : la liste de commandes canoniques + actions serveur optionnelles.
    struct Plan {
        var cmds: [[String: Any]] = []
        var normalizeTo: Double? = nil                                   // master-podcast : cible LUFS après la chaîne
        var duck: (source: String, target: String)? = nil              // ambience-duck : routine de ducking serveur
    }

    /// Construit le plan d'une recette pour une cible donnée. Génère les ids d'inserts frais (gravés dans les paths).
    /// Renvoie (plan, nil) ou (nil, message d'erreur).
    static func plan(_ id: String, doc: Document, target: Target) -> (Plan?, String?) {
        switch (id, target) {
        case ("telephone", .track(let tid)):     return (telephone(doc, tid), nil)
        case ("voice-radio", .track(let tid)):    return (voiceRadio(doc, tid), nil)
        case ("master-podcast", .bus(let bid)):   return (masterPodcast(doc, bid), nil)
        case ("ambience-duck", .duck(let s, let t)): var p = Plan(); p.duck = (s, t); return (p, nil)
        case (_, _) where meta(id) == nil:        return (nil, "recette inconnue: \(id)")
        default:                                  return (nil, "recette \(id) : cible incompatible (attend \(meta(id)?.target ?? "?"))")
        }
    }

    // --- helpers ---

    private static func setCmd(_ path: String, _ v: Double) -> [String: Any] { ["op": "set", "path": path, "value": v] }

    /// Identifier réel d'un param d'AU dont l'`id` OU le `name` contient `needle` (insensible à la casse), ou nil.
    /// Certaines AU (ex. AUDynamicsProcessor) exposent un `id` NUMÉRIQUE et le libellé dans `name` : chercher
    /// seulement dans `id` ratait silencieusement (seuil/makeup jamais appliqués). On garde l'ordre du schéma
    /// → « Compression Threshold » l'emporte sur « Expansion Threshold » pour le needle "threshold".
    private static func auParam(_ subType: String, _ needle: String) -> String? {
        let n = needle.lowercased()
        return AU.schema(subType).first { $0.id.lowercased().contains(n) || $0.name.lowercased().contains(n) }?.id
    }

    /// insert.add canonique (id frais) + le chemin de base de ses params. Renvoie (cmd, fxPath, insertId).
    private static func addInsert(_ doc: Document, _ prefix: String, _ ownerKey: String, _ ownerId: String,
                                  type: String, subType: String? = nil) -> (cmd: [String: Any], fxPath: String, id: String) {
        let iid = doc.freshId("i")
        var cmd: [String: Any] = ["op": "insert.add", "id": iid, ownerKey: ownerId, "type": type]
        if let st = subType { cmd["subType"] = st }
        return (cmd, "\(prefix)/fx/\(iid)/params", iid)
    }

    // --- recettes ---

    private static func telephone(_ doc: Document, _ tid: String) -> Plan {
        var p = Plan()
        let prefix = "track/\(tid)"
        let eq = addInsert(doc, prefix, "trackId", tid, type: "eq")
        p.cmds.append(eq.cmd)
        // EQ 4 bandes → bande passante téléphone : graves coupés, bosse medium, aigus coupés.
        p.cmds += [
            setCmd("\(eq.fxPath)/b0_freq", 320), setCmd("\(eq.fxPath)/b0_gain", -24),   // low-shelf : tue le grave
            setCmd("\(eq.fxPath)/b1_freq", 1_000), setCmd("\(eq.fxPath)/b1_gain", 3),    // peak medium bas
            setCmd("\(eq.fxPath)/b2_freq", 2_400), setCmd("\(eq.fxPath)/b2_gain", 4),    // peak presence « nasale »
            setCmd("\(eq.fxPath)/b3_freq", 3_400), setCmd("\(eq.fxPath)/b3_gain", -24),  // high-shelf : tue l'aigu
        ]
        let dist = addInsert(doc, prefix, "trackId", tid, type: "distortion")
        p.cmds.append(dist.cmd)
        p.cmds += [setCmd("\(dist.fxPath)/drive", -3), setCmd("\(dist.fxPath)/mix", 12), setCmd("\(dist.fxPath)/preset", 0)]
        return p
    }

    private static func voiceRadio(_ doc: Document, _ tid: String) -> Plan {
        var p = Plan()
        let prefix = "track/\(tid)"
        let eq = addInsert(doc, prefix, "trackId", tid, type: "eq")
        p.cmds.append(eq.cmd)
        p.cmds += [
            setCmd("\(eq.fxPath)/b0_freq", 80), setCmd("\(eq.fxPath)/b0_gain", -4),       // high-pass doux (low-shelf bas)
            setCmd("\(eq.fxPath)/b1_freq", 250), setCmd("\(eq.fxPath)/b1_gain", -2),      // dégage la boue
            setCmd("\(eq.fxPath)/b2_freq", 4_000), setCmd("\(eq.fxPath)/b2_gain", 4),     // présence radio
            setCmd("\(eq.fxPath)/b3_freq", 6_500), setCmd("\(eq.fxPath)/b3_gain", -4),    // de-ess statique (dompte les sifflantes)
        ]
        // compresseur (AUDynamicsProcessor) si présent — sinon on saute (insert quand même utile aux défauts).
        if AU.exists("dcmp") {
            let cmp = addInsert(doc, prefix, "trackId", tid, type: "au", subType: "dcmp")
            p.cmds.append(cmp.cmd)
            if let thr = auParam("dcmp", "threshold") { p.cmds.append(setCmd("\(cmp.fxPath)/\(thr)", -18)) }
            if let mk = auParam("dcmp", "overall") ?? auParam("dcmp", "gain") { p.cmds.append(setCmd("\(cmp.fxPath)/\(mk)", 4)) }
        }
        return p
    }

    private static func masterPodcast(_ doc: Document, _ bid: String) -> Plan {
        var p = Plan()
        let prefix = "bus/\(bid)"
        let eq = addInsert(doc, prefix, "busId", bid, type: "eq")
        p.cmds.append(eq.cmd)
        p.cmds += [
            setCmd("\(eq.fxPath)/b0_freq", 50), setCmd("\(eq.fxPath)/b0_gain", -3),       // nettoie le rumble
            setCmd("\(eq.fxPath)/b2_freq", 3_000), setCmd("\(eq.fxPath)/b2_gain", 1.5),   // présence légère
        ]
        if AU.exists("dcmp") {
            let cmp = addInsert(doc, prefix, "busId", bid, type: "au", subType: "dcmp")
            p.cmds.append(cmp.cmd)
            if let thr = auParam("dcmp", "threshold") { p.cmds.append(setCmd("\(cmp.fxPath)/\(thr)", -14)) }
            if let mk = auParam("dcmp", "overall") ?? auParam("dcmp", "gain") { p.cmds.append(setCmd("\(cmp.fxPath)/\(mk)", 3)) }
        }
        if AU.exists("lmtr") {                                                            // plafond de sécurité
            let lim = addInsert(doc, prefix, "busId", bid, type: "au", subType: "lmtr")
            p.cmds.append(lim.cmd)
        }
        p.normalizeTo = -16                                                               // ferme la boucle loudness
        return p
    }
}
