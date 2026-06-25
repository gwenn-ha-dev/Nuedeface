#!/bin/sh
# Nuedeface — build (swiftc, zéro dépendance externe).
#   - produit ./nuedeface           : le binaire (serveur headless ET hôte de l'UI)
#   - assemble ./Nuedeface.app      : bundle .app pour double-clic (Dock, menu, focus fenêtre)
set -e
cd "$(dirname "$0")"

# coeur + UI, un seul module, un seul binaire
swiftc -O \
  src/AudioUnits.swift src/Spectrum.swift src/Document.swift src/Engine.swift src/LiveEngine.swift src/Recipes.swift src/Server.swift src/main.swift \
  src/ui/Theme.swift src/ui/SocketClient.swift src/ui/AppHost.swift src/ui/Widgets.swift \
  src/ui/Console.swift src/ui/Timeline.swift src/ui/Workspace.swift src/ui/ContentView.swift src/ui/CommandConsole.swift \
  -o nuedeface

# bundle .app (wrapper autour du même binaire)
APP="Nuedeface.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp nuedeface "$APP/Contents/MacOS/nuedeface"

# icône d'app (squircle macOS, asset versionné)
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || echo "AppIcon.icns absent (non bloquant)"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Nuedeface</string>
  <key>CFBundleDisplayName</key>     <string>Nuedeface</string>
  <key>CFBundleIdentifier</key>      <string>local.nuedeface</string>
  <key>CFBundleExecutable</key>      <string>nuedeface</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleVersion</key>         <string>0.1</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# signature ad-hoc (gratuite, locale) : évite l'alerte « endommagé » sur certaines configs et donne une
# identité de code stable au bundle. Pour une vraie distribution publique : signature Developer ID + notarisation.
codesign --force --deep --sign - "$APP" 2>/dev/null && echo "signé ad-hoc" || echo "codesign indisponible (non bloquant)"

echo "ok -> ./nuedeface (headless: --headless [sock])  |  open ./Nuedeface.app (GUI)"
