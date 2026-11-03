#!/usr/bin/env bash
# Manor Lords Co-op : installation, mise à jour et désinstallation (Linux, Steam + Proton).
#
# Lancez-le depuis le dossier de l'archive : ./manorlords-coop.sh [install|uninstall] [--game-dir DIR] [--yes]
# Il trouve le jeu dans vos bibliothèques Steam, vérifie la version, installe UE4SS (fourni dans
# l'archive, version figée) et le mod, écrit config.txt. Il n'écrit que dans le dossier du jeu.
set -euo pipefail

APPID=1363080
EXE_SHA=560451df38cd91134026c25b69539449c570f3163e33bc8c45b4dc20b6952cee
HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$HERE/payload"
ACTION=""; GAME_DIR=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    install|update) ACTION=install ;;
    uninstall) ACTION=uninstall ;;
    --game-dir) shift; GAME_DIR="$1" ;;
    --yes|-y) YES=1 ;;
    *) echo "argument inconnu : $1"; exit 2 ;;
  esac
  shift
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*"; exit 1; }
ask()  { # ask "question" default -> REPLY
  if [ "$YES" = 1 ]; then REPLY="$2"; return; fi
  read -r -p "  $1 [$2] " REPLY || true
  [ -n "$REPLY" ] || REPLY="$2"
}

say ""
say "  ✦ MANOR LORDS CO-OP ✦  installation · mise à jour · désinstallation (Linux)"
say ""
[ -d "$PAYLOAD/ManorLordsCoop" ] || die "dossier payload/ introuvable : lancez ce script depuis l'archive décompressée"

# ------------------------------------------------------------------ find the game
find_game() {
  local roots=("$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam")
  local libs=()
  for r in "${roots[@]}"; do
    local vdf="$r/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    libs+=("$r")
    while IFS= read -r p; do libs+=("$p"); done < <(sed -n 's/^\s*"path"\s*"\(.*\)"/\1/p' "$vdf")
  done
  for l in "${libs[@]}"; do
    if [ -f "$l/steamapps/appmanifest_$APPID.acf" ]; then
      local dir; dir=$(sed -n 's/^\s*"installdir"\s*"\(.*\)"/\1/p' "$l/steamapps/appmanifest_$APPID.acf")
      [ -d "$l/steamapps/common/$dir" ] && { echo "$l/steamapps/common/$dir"; return; }
    fi
  done
}
[ -n "$GAME_DIR" ] || GAME_DIR="$(find_game || true)"
[ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ] || die "Manor Lords introuvable. Relancez avec --game-dir \"/chemin/vers/Manor Lords\""
WIN64="$GAME_DIR/ManorLords/Binaries/Win64"
EXE="$WIN64/ManorLords-Win64-Shipping.exe"
[ -f "$EXE" ] || die "jeu incomplet : $EXE manque"
ok "jeu : $GAME_DIR"

MODDIR="$WIN64/ue4ss/Mods/ManorLordsCoop"
MARK="$WIN64/ue4ss/.installed-by-manorlords-coop"

# ------------------------------------------------------------------ uninstall
if [ -z "$ACTION" ]; then
  if [ -d "$MODDIR" ]; then ask "Le mod est installé. (i)nstaller/mettre à jour ou (d)ésinstaller ?" i
  else REPLY=i; fi
  case "$REPLY" in d*|D*) ACTION=uninstall ;; *) ACTION=install ;; esac
fi
if [ "$ACTION" = uninstall ]; then
  rm -rf "$MODDIR"
  if [ -f "$WIN64/ue4ss/Mods/mods.txt" ]; then sed -i '/^ManorLordsCoop *:/d' "$WIN64/ue4ss/Mods/mods.txt"; fi
  ok "mod retiré"
  if [ -f "$MARK" ]; then
    ask "Retirer aussi UE4SS (installé par ce script) ? (o/n)" o
    case "$REPLY" in o*|O*|y*|Y*) rm -rf "$WIN64/ue4ss" "$WIN64/dwmapi.dll"; ok "UE4SS retiré" ;; esac
  fi
  say ""; say "  Pensez à retirer l'option de lancement WINEDLLOVERRIDES dans Steam."; exit 0
fi

# ------------------------------------------------------------------ install
say "  vérification de la version du jeu…"
got=$(sha256sum "$EXE" | cut -d' ' -f1)
if [ "$got" != "$EXE_SHA" ]; then
  die "version du jeu non prise en charge (empreinte $got). Ce mod demande Manor Lords, build Steam 26185246."
fi
ok "version du jeu : build Steam 26185246"

if [ -f "$WIN64/ue4ss/UE4SS.dll" ] && [ -f "$WIN64/dwmapi.dll" ]; then
  if cmp -s "$WIN64/ue4ss/UE4SS.dll" "$PAYLOAD/ue4ss/ue4ss/UE4SS.dll"; then ok "UE4SS déjà installé (même version)"
  else warn "un autre UE4SS est déjà installé : il est gardé. Si le mod ne démarre pas, désinstallez-le et relancez ce script."; fi
else
  cp -r "$PAYLOAD/ue4ss/ue4ss" "$WIN64/"
  cp "$PAYLOAD/ue4ss/dwmapi.dll" "$WIN64/"
  touch "$MARK"
  ok "UE4SS installé ($(cat "$PAYLOAD/ue4ss/VERSION" 2>/dev/null || echo 'version figée'))"
fi

keep_cfg=""
[ -f "$MODDIR/config.txt" ] && keep_cfg="$(cat "$MODDIR/config.txt")"
rm -rf "$MODDIR"
cp -r "$PAYLOAD/ManorLordsCoop" "$MODDIR"
MT="$WIN64/ue4ss/Mods/mods.txt"
touch "$MT"
sed -i '/^ManorLordsCoop *:/d' "$MT"
if grep -q '^Keybinds' "$MT"; then sed -i 's/^Keybinds/ManorLordsCoop : 1\nKeybinds/' "$MT"; else echo "ManorLordsCoop : 1" >> "$MT"; fi
ok "mod installé et activé ($(cat "$PAYLOAD/VERSION" 2>/dev/null || echo '?'))"

if [ -n "$keep_cfg" ]; then
  printf '%s\n' "$keep_cfg" > "$MODDIR/config.txt"
  ok "réglages précédents gardés (ue4ss/Mods/ManorLordsCoop/config.txt)"
else
  ask "Vous êtes l'hôte (h) ou l'invité (i) ?" h
  case "$REPLY" in i*|I*|j*|J*) role=join ;; *) role=host ;; esac
  addr=127.0.0.1
  if [ "$role" = join ]; then ask "Adresse de l'hôte (IP ou nom) ?" 127.0.0.1; addr="$REPLY"; fi
  ask "Nom de votre seigneur ?" "$USER"; lord="$REPLY"
  cat > "$MODDIR/config.txt" <<CFG
role = $role
address = $addr
port = 27015
lord = $lord
region =
CFG
  ok "réglages écrits (role=$role, seigneur=$lord)"
fi

say ""
say "  Dernière étape, une seule fois : dans Steam, clic droit sur Manor Lords > Propriétés >"
say "  Options de lancement, mettez :"
say ""
say '      WINEDLLOVERRIDES="dwmapi=n,b" %command%'
say ""
say "  Ensuite lancez le jeu. L'état du mod s'écrit dans :"
say "  $MODDIR/run/status.txt"
