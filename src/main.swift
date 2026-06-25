// Nuedeface — point d'entrée (le SEUL fichier avec du code top-level).
//
// Aiguillage selon les arguments :
//   ./nuedeface                       → GUI (fenêtre + serveur embarqué sur /tmp/nuedeface.sock)
//   ./nuedeface --gui [/chemin.sock]  → GUI sur le socket donné
//   ./nuedeface --headless [.sock]    → serveur seul (comportement historique)
//   ./nuedeface /chemin.sock          → serveur seul aussi (back-compat README)
//
// La fenêtre N'EST PAS la source de vérité : elle se connecte au socket comme un script ou Claude.
// Même process, un seul socket, plusieurs clients possibles en parallèle (la thèse du projet).

import Foundation

let args = CommandLine.arguments
let headless = args.contains("--headless")
let gui = args.contains("--gui")
let nonFlag = args.dropFirst().first { !$0.hasPrefix("--") }
let sockPath = nonFlag ?? "/tmp/nuedeface.sock"

signal(SIGPIPE, SIG_IGN)

if headless || (nonFlag != nil && !gui) {
    Server.run(socketPath: sockPath)                 // bloque sur l'accept loop
} else {
    Server.startInBackground(socketPath: sockPath)   // serveur en fond
    FileHandle.standardError.write(
        "nuedeface GUI: serveur embarqué sur \(sockPath) — branche aussi un script / Claude dessus.\n"
        .data(using: .utf8)!)
    AppHost.run(socketPath: sockPath)                // fenêtre sur la main-loop (ne rend jamais la main)
}
