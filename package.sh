#!/bin/sh
# Nuedeface — packaging d'une release (zip + dmg) pour distribution binaire.
#   ./package.sh [version]      # défaut : lit CFBundleShortVersionString de l'app
#
# Produit dans dist/ :
#   Nuedeface-<version>.zip     (ditto, préserve le bundle .app signé)
#   Nuedeface-<version>.dmg     (image disque glisser-déposer)
#
# Le bundle est signé ad-hoc par build.sh. Pour une distribution SANS alerte Gatekeeper au téléchargement,
# il faut une signature Developer ID + notarisation (compte Apple payant requis).
set -e
cd "$(dirname "$0")"

./build.sh

APP="Nuedeface.app"
VERSION="${1:-$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0.1)}"
DIST="dist"
mkdir -p "$DIST"
BASE="$DIST/Nuedeface-$VERSION"

# --- zip (ditto conserve les attributs du bundle et la signature) ---
rm -f "$BASE.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BASE.zip"
echo "→ $BASE.zip"

# --- dmg (glisser-déposer ; lien Applications pour l'install) ---
rm -f "$BASE.dmg"
STAGE="$(mktemp -d)/Nuedeface"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Nuedeface $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$BASE.dmg" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "→ $BASE.dmg"

echo "ok — release $VERSION packagée dans $DIST/"
