// Nuedeface — tokens de design (la cohérence « à la Apple » centralisée).
//
// Avant : couleurs/typos/rayons en dur, inline, dispersés dans 6 fichiers UI. Ici : une seule
// source. Identité sombre cohérente (gris chauds, UN accent + des sémantiques RÉSERVÉES aux mètres),
// typographie en tailles fixes, cibles tactiles 44 pt (contrat touch-first), constantes de ballistique.

import SwiftUI
import AppKit

/// Palette : surfaces empilées (du fond au premier plan) + accents sémantiques.
enum Palette {
    // surfaces (du plus sombre au plus clair) — empilement console/timeline/rack
    static let deep      = Color(white: 0.08)     // creux (lane master)
    static let bg        = Color(white: 0.10)     // fond profond (diviseurs)
    static let panel     = Color(white: 0.12)     // panneaux (sends, spectre)
    static let track     = Color(white: 0.13)     // mini-tranche / transport
    static let surface   = Color(white: 0.14)     // console
    static let surface2  = Color(white: 0.16)     // section mix / barres
    static let header    = Color(white: 0.17)     // entêtes de panneau
    static let rail      = Color(white: 0.185)    // colonne d'entêtes / ruler
    static let raised    = Color(white: 0.21)     // tranche master
    static let module    = Color(white: 0.165)    // cartes d'insert, chips (opaque → bord net)
    static let well      = Color.black.opacity(0.5)     // fond de mètre creusé

    static let accent    = Color.accentColor
    static let selection = Color.accentColor.opacity(0.18)
    static let stroke    = Color.white.opacity(0.08)    // filet de carte (le « liseré » Apple)
    static let strokeHi  = Color.white.opacity(0.14)    // filet accentué (élément sélectionné)
    static let hairline  = Color.white.opacity(0.06)    // grilles fines
    static let divider   = Color.black.opacity(0.35)
    static let text      = Color.white.opacity(0.92)
    static let text2     = Color.white.opacity(0.55)    // secondaire lisible (mieux que .secondary système)

    // sémantiques — réservées aux mètres / états (jamais décoratives)
    static let ok        = Color.green
    static let warn      = Color.yellow
    static let hot       = Color.orange
    static let clip      = Color.red
    static let auto      = Color.orange            // lanes d'automation
    /// dégradé d'un VU de niveau (vert→jaune→rouge), du bas vers le haut.
    static let meter     = [Color.green, Color.green, Color.yellow, Color.red]
    /// dégradé de réduction de gain (vert calme → rouge fort), de gauche à droite.
    static let reduction = [Color.green, Color.yellow, Color.orange, Color.red]
}

/// Typographie : tailles/poids fixes — fin des `.system(size:)` épars.
/// Échelle relevée : la thèse du projet est la LISIBILITÉ ; les readouts de mètres/radar/sends ne
/// peuvent pas vivre à 7-8 pt (sous le seuil confortable macOS, illisible en Retina). Plancher = 9 pt.
enum Typo {
    static let heading = Font.system(size: 15, weight: .bold)
    static let title   = Font.system(size: 12, weight: .semibold)
    static let label   = Font.system(size: 10, weight: .bold)
    static let hint    = Font.system(size: 10)
    static let value   = Font.system(size: 10).monospacedDigit()   // valeurs de mètres / dB
    static let micro   = Font.system(size: 9, weight: .bold)       // libellés denses (plancher lisible)
}

/// Dimensions : rayons, paddings, cibles tactiles (44 pt), hauteurs récurrentes.
enum Dims {
    static let radius: CGFloat = 5
    static let radiusS: CGFloat = 3
    static let tap: CGFloat = 44                 // cible tactile mini (touch-first)
    static let barH: CGFloat = 58                // sends / spectre
    static let stripW: CGFloat = 62              // mini-tranche
}

/// Ballistique des mètres + durées d'animation (le « feel » Apple).
enum Ballistics {
    static let attack: Double = 0.5              // montée quasi-instantanée (lissage faible)
    static let release: Double = 0.12            // descente lente (chute douce)
    static let peakHold: Double = 1.5            // maintien de crête (s)
    static let fast = Animation.easeOut(duration: 0.12)
    static let smooth = Animation.easeInOut(duration: 0.18)

    /// Lissage asymétrique d'un niveau (attaque rapide, release lente) — pour les VU.
    static func smoothed(_ current: Double, towards target: Double) -> Double {
        let coef = target > current ? attack : release
        return current + (target - current) * coef
    }
}

// MARK: - styles réutilisables (le « fini » centralisé)

/// Voile de lumière « éclairé d'en haut » (blanc 0.06 → 0) — donne la matière sans skeuomorphe.
let litGradient = LinearGradient(colors: [Color.white.opacity(0.06), Color.white.opacity(0)],
                                 startPoint: .top, endPoint: .bottom)
/// Fond de surface MATÉRIÉ : couleur de base + voile de lumière. À utiliser dans `.background(litFill(...))`.
@ViewBuilder func litFill(_ base: Color) -> some View { ZStack { base; litGradient } }

/// Curseur natif au survol (resize, main, croix…) : le feedback « vivant » sous la souris qui manquait.
/// push/pop équilibré par un flag + garde sur disparition de la vue (pas de curseur qui « reste coincé »).
struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { cursor.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View {
    /// Applique un curseur natif au survol de la vue (ex. `.resizeLeftRight` sur une poignée de trim).
    func hoverCursor(_ cursor: NSCursor) -> some View { modifier(HoverCursor(cursor: cursor)) }

    /// Carte : surface arrondie matérée (base + lumière) + filet fin. `raised` = sélectionnée (filet accentué + glow).
    func card(_ fill: Color = Palette.module, radius: CGFloat = Dims.radius, raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .background(shape.fill(fill).overlay(shape.fill(litGradient)))
            .overlay(shape.stroke(raised ? Palette.strokeHi : Palette.stroke, lineWidth: raised ? 1 : 0.5))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
    /// Surface matérée (panneaux/barres) : base + voile de lumière, sans arrondi.
    func lit(_ base: Color) -> some View { background(litFill(base)) }
    /// Étiquette de section en petites capitales espacées (le ton « console » lisible).
    func sectionLabel() -> some View {
        font(Typo.label).tracking(0.8).foregroundColor(Palette.text2)
    }
}
