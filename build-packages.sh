#!/bin/sh
# Build the Lyrion zip and the piCorePlayer tcz. Does not install either.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
VER=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' "$ROOT/Bluetooth/install.xml")
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/lms-bluetooth-build.XXXXXX")
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/Bluetooth"
cd "$ROOT/Bluetooth"
find . -type f \
	! -name '*.bak' \
	! -name '*.pyc' \
	! -path './__pycache__/*' \
	-print | while IFS= read -r file; do
	rel=${file#./}
	mkdir -p "$STAGE/Bluetooth/$(dirname "$rel")"
	cp -X "$ROOT/Bluetooth/$rel" "$STAGE/Bluetooth/$rel"
done
cp -X "$ROOT/README.md" "$STAGE/Bluetooth/README.md"

rm -f "$ROOT/Bluetooth-$VER.zip"
(
	cd "$STAGE"
	COPYFILE_DISABLE=1 zip -r -X "$ROOT/Bluetooth-$VER.zip" Bluetooth
)

SHA=$(shasum -a 1 "$ROOT/Bluetooth-$VER.zip" | awk '{print $1}')
cat > "$ROOT/repo.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
  <details>
    <title lang="EN">Bluetooth</title>
    <title lang="FR">Bluetooth</title>
  </details>
  <plugins>
    <plugin name="Bluetooth" version="$VER" minTarget="8.0" maxTarget="*">
      <title lang="EN">Bluetooth</title>
      <title lang="FR">Bluetooth</title>
      <desc lang="EN">Registry of Bluetooth devices, their player and their drift. The bridge is told afterwards. Nothing starts playing.</desc>
      <desc lang="FR">Registre des dispositifs Bluetooth, de leur platine et du drift. Le bridge est prévenu ensuite. Rien ne se met à jouer.</desc>
      <changes lang="EN">$VER: The player menu can read Bluetooth without a scan. Identity and subwoofer reads run beside Lyrion and no longer freeze it.</changes>
      <changes lang="FR">$VER : Le menu de la platine peut lire le Bluetooth sans balayage. L’identité et les lectures du caisson tournent à côté de Lyrion et ne le figent plus.</changes>
      <category>hardware</category>
      <creator>JS Arcand assisted by Grok</creator>
      <email>info@jsarcand.com</email>
      <link>https://github.com/jsarcand/LMS-bluetooth</link>
      <url>https://raw.githubusercontent.com/jsarcand/LMS-bluetooth/v$VER/Bluetooth-$VER.zip</url>
      <sha>$SHA</sha>
    </plugin>
  </plugins>
</extensions>
EOF

TREE="$STAGE/tree"
mkdir -p "$TREE/usr/local/share/lms-bluetooth" "$TREE/usr/local/tce.installed"
cp -R "$STAGE/Bluetooth" "$TREE/usr/local/share/lms-bluetooth/Bluetooth"
cp -X "$ROOT/pcp/tce.installed" "$TREE/usr/local/tce.installed/lms-bluetooth"
chmod 755 "$TREE/usr/local/tce.installed/lms-bluetooth"
find "$TREE" -name '.DS_Store' -delete

if ! command -v mksquashfs >/dev/null 2>&1; then
	echo "mksquashfs is not on PATH. The zip and repo.xml are written."
	echo "Build the tcz on piCorePlayer with squashfs-tools.tcz:"
	echo "  mksquashfs tree lms-bluetooth.tcz -comp gzip -b 16384 -all-root -no-xattrs -noappend"
	exit 0
fi

rm -f "$ROOT/pcp/lms-bluetooth.tcz"
mksquashfs "$TREE" "$ROOT/pcp/lms-bluetooth.tcz" -comp gzip -b 16384 -all-root -no-xattrs -noappend

python3 - "$ROOT/pcp/lms-bluetooth.tcz" <<'PY'
import hashlib, pathlib, sys
path = pathlib.Path(sys.argv[1])
digest = hashlib.md5(path.read_bytes()).hexdigest()
path.with_name(path.name + ".md5.txt").write_text(digest + "  " + path.name + "\n")
size = path.stat().st_size
label = size / 1024
text = f"{label:.0f}K" if label >= 10 else f"{size}B"
info = f"""Title:          lms-bluetooth.tcz
Description:    Lyrion Bluetooth registry for piCorePlayer
Version:        {path.parent.parent.joinpath('Bluetooth/install.xml').read_text().split('<version>')[1].split('</version>')[0]}
Author:         JS Arcand
Original-site:  https://github.com/jsarcand/LMS-bluetooth
Copying-policy: All rights reserved
Size:           {text}
Extension_by:   jsarcand
Tags:           lms bluetooth lyrion picoreplayer
Comments:       Copies the plugin into the Lyrion cache. Does not restart Lyrion and does not start playback. Restart Lyrion once to load the new files.
Change-log:     2026/11/13 First publication
Current:        2026/11/13 First publication (0.2.0)
"""
path.with_suffix(".tcz.info").write_text(info)
print(digest)
print(text)
PY

echo "zip $ROOT/Bluetooth-$VER.zip"
echo "sha1 $SHA"
unzip -l "$ROOT/Bluetooth-$VER.zip"
