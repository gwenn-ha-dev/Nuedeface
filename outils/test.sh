#!/bin/sh
# Nuedeface — suite de tests (swiftc, zéro dépendance). Deux étages :
#   1. DSP/modèle : compile le cœur AVEC Tests/main.swift (les tests exercent le vrai code de prod).
#   2. PROTOCOLE  : lance le vrai serveur headless et le pilote en client (Tests/protocol.swift).
# Sort ≠ 0 au premier échec → CI-friendly.
set -e
cd "$(dirname "$0")/.."

# Minimum macOS, pinned. Without -target, swiftc stamps the binary with the
# installed SDK's version: the same source produced macOS 27 here and 26.6 on
# CI, and the README's claim went stale with every Xcode update.
DEPLOY="$(uname -m)-apple-macos26.0"

TMP="$(mktemp -d)"

echo "═══ étage 1 : DSP / modèle ═══"
swiftc -O -target "$DEPLOY" \
  src/AudioUnits.swift src/Spectrum.swift src/Document.swift src/Engine.swift src/LiveEngine.swift src/Recipes.swift src/Server.swift \
  Tests/main.swift \
  -o "$TMP/nuedeface-tests"
"$TMP/nuedeface-tests"

echo ""
echo "═══ étage 2 : conformité protocole (serveur réel) ═══"
# le test pilote l'ARTEFACT réel ./nuedeface (le serveur headless) ; on le construit s'il manque.
[ -x ./nuedeface ] || ./build.sh >/dev/null
swiftc -O -target "$DEPLOY" Tests/protocol.swift -o "$TMP/nuedeface-proto"
exec "$TMP/nuedeface-proto" ./nuedeface
