#!/bin/sh
# Build the distribution archive: release/<version>/ManorLords-Coop-<version>.zip
#   payload/ue4ss          UE4SS v3.0.1-1183-gcdbc0b66 (dwmapi.dll + ue4ss/), from the pinned official zip
#   payload/ManorLordsCoop the Lua mod + coopnative.dll
#   ManorLords-Coop.bat, manorlords-coop.sh, README.md, LICENSE, THIRD_PARTY/
# Usage: ./release.sh <path to UE4SS_v3.0.1-1183-gcdbc0b66.zip>
set -eu
cd "$(dirname "$0")"
UE4SS_ZIP="$1"
UE4SS_SHA=e4a47e23e2eeb8379c4fc388d1b1686f01c6c5930d84a2ee4a6a9574b274e681
VERSION=$(sed -n 's/^local VERSION = "\(.*\)"/\1/p' lua/ManorLordsCoop/Scripts/main.lua)
echo "$UE4SS_SHA  $UE4SS_ZIP" | sha256sum -c -
[ "${NOBUILD:-}" = 1 ] || ./native/build.sh
OUT="release/$VERSION"; STAGE="$OUT/stage"
rm -rf "$OUT"; mkdir -p "$STAGE/payload/ue4ss" "$STAGE/THIRD_PARTY"
python3 -I -m zipfile -e "$UE4SS_ZIP" "$STAGE/payload/ue4ss"
echo "UE4SS v3.0.1-1183-gcdbc0b66 (experimental-latest, sha256 $UE4SS_SHA)" > "$STAGE/payload/ue4ss/VERSION"
cp "$STAGE/payload/ue4ss/ue4ss/LICENSE" "$STAGE/THIRD_PARTY/UE4SS-LICENSE"
cp -r lua/ManorLordsCoop "$STAGE/payload/ManorLordsCoop"
rm -f "$STAGE/payload/ManorLordsCoop/config.txt"
rm -rf "$STAGE/payload/ManorLordsCoop/run"
cp native/out/coopnative.dll "$STAGE/payload/ManorLordsCoop/"
echo "$VERSION" > "$STAGE/payload/VERSION"
cp install/ManorLords-Coop.bat install/manorlords-coop.sh README.md LICENSE "$STAGE/"
cp docs/PROTOCOL.md "$STAGE/PROTOCOL.md"
chmod +x "$STAGE/manorlords-coop.sh"
( cd "$STAGE" && python3 -I - "../ManorLords-Coop-$VERSION.zip" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk("."):
        for f in sorted(files):
            p = os.path.join(root, f)
            info = zipfile.ZipInfo.from_file(p, os.path.normpath(p))
            if f.endswith(".sh"):
                info.external_attr = 0o755 << 16
            with open(p, "rb") as fh:
                z.writestr(info, fh.read(), zipfile.ZIP_DEFLATED)
PY
)
rm -rf "$STAGE"
( cd "$OUT" && sha256sum "ManorLords-Coop-$VERSION.zip" | tee "ManorLords-Coop-$VERSION.zip.sha256" )
