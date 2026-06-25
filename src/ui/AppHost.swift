// Nuedeface — hôte AppKit de l'UI SwiftUI.
//
// Bootstrap impératif (pas de @main) pour cohabiter avec le top-level de main.swift :
// NSApplication + fenêtre + NSHostingView(ContentView). La fenêtre reçoit un SocketClient
// qui se connecte au socket du serveur embarqué.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: SocketClient
    let socketPath: String
    var window: NSWindow!
    var consoleWindow: NSWindow?       // fenêtre console (retenue : isReleasedWhenClosed=false → réouvrable)

    init(store: SocketClient, socketPath: String) {
        self.store = store; self.socketPath = socketPath
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        store.connect(path: socketPath)

        let root = ContentView().environmentObject(store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Nuedeface"
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // --- actions de menu (D) : routent vers le store, dialogs fichier natifs ---
    @objc func menuOpen() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false
        p.canChooseDirectories = true                  // un paquet .nuedeface est un DOSSIER
        p.canChooseFiles = true                        // …mais on accepte aussi un .json projet (plat)
        p.allowedContentTypes = []
        if p.runModal() == .OK, let url = p.url { store.load(path: url.path) }
    }
    @objc func menuSave() {
        if let path = store.projectPath { store.save(path: path) } else { menuSaveAs() }
    }
    @objc func menuSaveAs() {
        let p = NSSavePanel(); p.nameFieldStringValue = (store.projectPath as NSString?)?.lastPathComponent ?? "projet.nuedeface"
        p.message = "Enregistre un PAQUET .nuedeface (auto-suffisant : assets copiés à côté, projet déplaçable)."
        if p.runModal() == .OK, let url = p.url { store.save(path: url.path) }
    }
    @objc func menuExport() {
        let p = NSSavePanel()
        p.title = "Exporter le mix"
        p.nameFieldStringValue = store.cleanProjectName + ".m4a"
        p.message = "Extension .wav ou .m4a (AAC). Le mix complet est rendu, traînes d'effets incluses."
        if p.runModal() == .OK, let url = p.url {
            let ext = url.pathExtension.lowercased()
            store.export(path: url.path, format: ext == "wav" ? "wav" : "m4a")
        }
    }
    private func pickRefAndMatch(mode: String) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.title = "Choisir une référence audio"
        if p.runModal() == .OK, let url = p.url { store.matchRef(path: url.path, mode: mode) }
    }
    @objc func menuMatchLoudness() { pickRefAndMatch(mode: "loudness") }
    @objc func menuMatchTone() { pickRefAndMatch(mode: "tone") }
    /// Ouvre (ou ramène au premier plan) la console de commandes : un client socket de plus, dans une 2e fenêtre.
    @objc func menuConsole() {
        if consoleWindow == nil {
            let root = CommandConsole().environmentObject(store)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "Console — socket Nuedeface"
            w.minSize = NSSize(width: 380, height: 260)
            w.contentView = NSHostingView(rootView: root)
            w.isReleasedWhenClosed = false
            w.center()
            consoleWindow = w
        }
        consoleWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func menuUndo() { store.undo() }
    @objc func menuRedo() { store.redo() }
    @objc func menuAddTrack() { store.addTrack() }
    @objc func menuPlayPause() { store.togglePlay() }
    @objc func menuReturnStart() { store.returnToStart() }
}

enum AppHost {
    private static var delegateRef: AppDelegate?   // NSApp.delegate est weak → on retient ici

    static func run(socketPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(store: SocketClient(), socketPath: socketPath)
        delegateRef = delegate
        app.delegate = delegate
        installMenu(delegate)
        app.run()
    }

    /// Vraie barre de menus macOS (Fichier / Édition / Lecture) → discoverability des raccourcis + feel natif.
    private static func installMenu(_ t: AppDelegate) {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(); main.addItem(item)
            let sub = NSMenu(title: title); items.forEach { sub.addItem($0) }; item.submenu = sub
        }
        func mi(_ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = t) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        // App menu
        menu("Nuedeface", [mi("Quitter Nuedeface", #selector(NSApplication.terminate(_:)), "q", target: nil)])
        // Fichier
        menu("Fichier", [
            mi("Ouvrir…", #selector(AppDelegate.menuOpen), "o"),
            NSMenuItem.separator(),
            mi("Enregistrer", #selector(AppDelegate.menuSave), "s"),
            mi("Enregistrer sous…", #selector(AppDelegate.menuSaveAs), "s", [.command, .shift]),
            NSMenuItem.separator(),
            mi("Exporter le mix…", #selector(AppDelegate.menuExport), "e"),
        ])
        // Édition
        menu("Édition", [
            mi("Annuler", #selector(AppDelegate.menuUndo), "z"),
            mi("Rétablir", #selector(AppDelegate.menuRedo), "z", [.command, .shift]),
            NSMenuItem.separator(),
            mi("Ajouter une piste", #selector(AppDelegate.menuAddTrack), "t"),
        ])
        // Lecture (pas de raccourci Espace ici : il vit dans la vue transport pour éviter le double-déclenchement)
        menu("Lecture", [
            mi("Lire / Pause", #selector(AppDelegate.menuPlayPause), "", []),
            mi("Retour au début", #selector(AppDelegate.menuReturnStart), "", []),
        ])
        // Mix : gestes haut niveau pilotant le master (caler sur une référence)
        menu("Mix", [
            mi("Caler le niveau sur une référence…", #selector(AppDelegate.menuMatchLoudness), "", []),
            mi("Caler le timbre sur une référence…", #selector(AppDelegate.menuMatchTone), "", []),
        ])
        // Fenêtre : la console de commandes (l'humain parle le protocole socket directement)
        menu("Fenêtre", [
            mi("Console des commandes", #selector(AppDelegate.menuConsole), "k"),
        ])
        NSApplication.shared.mainMenu = main
    }
}
