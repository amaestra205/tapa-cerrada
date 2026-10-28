#!/bin/bash
# Desinstala Tapa Cerrada y deja el reposo del Mac como estaba.
set -uo pipefail
echo "Cerrando Tapa Cerrada…"
pkill -x TapaCerrada 2>/dev/null || true
sleep 1
echo "Restaurando el reposo y quitando el permiso (pide tu contraseña)…"
sudo /usr/bin/pmset -a disablesleep 0
sudo /bin/rm -f /etc/sudoers.d/tapacerrada
for D in /Applications "$HOME/Applications"; do
  [ -d "$D/Tapa Cerrada.app" ] && rm -rf "$D/Tapa Cerrada.app" && echo "Borrada $D/Tapa Cerrada.app"
done
defaults delete com.alejandro.tapacerrada 2>/dev/null || true
rm -f "$HOME/Library/Logs/TapaCerrada.log"
echo "Hecho. Si aparece en Ajustes > General > Ítems de inicio, ya puedes ignorarlo: desaparecerá solo."
