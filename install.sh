#!/bin/bash
# Instala Tapa Cerrada compilándola desde el código (no necesita Gatekeeper ni descargas de binarios).
# Uso:  ./install.sh            (desde una copia del repositorio)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Hacen falta las herramientas de desarrollo de Apple. Se va a abrir el instalador;"
  echo "cuando termine, vuelve a ejecutar ./install.sh"
  xcode-select --install || true
  exit 1
fi

scripts/build-app.sh
DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x TapaCerrada 2>/dev/null || true
sleep 1
rm -rf "$DEST/Tapa Cerrada.app"
cp -R "build/Tapa Cerrada.app" "$DEST/"
open "$DEST/Tapa Cerrada.app"
echo
echo "Listo: Tapa Cerrada está en $DEST y en la barra de menús (icono de taza)."
echo "La primera vez te pedirá la contraseña de administrador una sola vez."
