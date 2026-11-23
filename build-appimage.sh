#!/bin/sh
# Builds the Linux AppImage:  dist/Game-Format-Converter-Enhanced-<version>-x86_64.AppImage
# One file with everything inside: the program, Python with Tk (python-build-standalone), zstandard, chdman built from
# MAME's source, and gameInfo.db. Nothing has to be installed to run it (Bazzite, SteamOS and other image-based systems too).
#
# Usage, on any x86_64 Linux with podman or docker:   ./build-appimage.sh
# The build runs inside Ubuntu 22.04, so the AppImage runs on Linux from 2022 on (glibc 2.35 or newer).
# Every download is checked against the SHA-256 below; build/appimage-cache keeps them (and the chdman build) for next time.
# ./build-appimage.sh --inside runs the build steps directly (what the container does; needs Ubuntu 22.04 or alike, as root).
set -eu

MAME_TAG=mame0289
MAME_SHA=0929cc749afabcef892900e10dd90bd8b05f94a7dde8f367ac6a5d2082589f84
PY_FILE=cpython-3.14.10+20261110-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz
PY_URL=https://github.com/astral-sh/python-build-standalone/releases/download/20261110/$PY_FILE
PY_SHA=c2ff2e97422f5d3896a16e0317fd212ba977bbf2688d93a6f7a03d817506bd30
PY_VER=3.14.10
TKSRC_SHA__tkinter_c=a52ac62ff1a6e09d9bed70be4043d08cadfb2dd5a3e9b1a8f010fb28843dc63c
TKSRC_SHA_tkappinit_c=27f8a06f46cd8e4578999f7e3edbd862dfc18a98b2085a367afaf7c59899bb93
TKSRC_SHA_tkinter_h=e3ee25f18ddc2a6e3d48ebec11672d46729e9802250129b701504d20c710abb4
TKSRC_SHA_clinic__tkinter_c_h=7b7a43ef4badd3adf25a65867433458ab9e94438d07d0aac562abc8f3fe4c8bd
ZSTD_WHL=zstandard-0.25.0-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl
ZSTD_SHA=e09bb6252b6476d8d56100e8147b803befa9a12cea144bbe629dd508800d1ad0
TOOL_URL=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
TOOL_SHA=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
RUNTIME_URL=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
RUNTIME_SHA=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
RUNTIME_LICENSE_SHA=aa154fc9070614bbe7921f89db11efd1dba7a1f3a41685958110e2230f9c0ca1
IMAGE=docker.io/library/ubuntu:22.04
ID=game-format-converter-enhanced

root=$(cd "$(dirname "$0")" && pwd)

if [ "${1:-}" != "--inside" ]; then
    engine=$(command -v podman || command -v docker || true)
    [ -n "$engine" ] || { echo "Needs podman or docker (or run '$0 --inside' on Ubuntu 22.04 as root)." >&2; exit 1; }
    exec "$engine" run --rm -v "$root:/src:Z" "$IMAGE" sh /src/build-appimage.sh --inside
fi

cache=$root/build/appimage-cache
work=$root/build/appimage
mkdir -p "$cache" "$root/dist"

echo "== Build tools"
export DEBIAN_FRONTEND=noninteractive
printf 'Acquire::http::Timeout "30";\nAcquire::Retries "5";\n' > /etc/apt/apt.conf.d/99gfc-retries    # a stalled mirror is retried, not waited on forever
apt-get update -qq
apt-get install -y -qq --no-install-recommends build-essential python3 curl ca-certificates file icoutils \
    pkg-config libsdl2-dev libfontconfig-dev tk8.6-dev libxss1 >/dev/null 2>&1   # (MAME's project generator asks for SDL even when only its tools are built)

get() {   # get URL FILE SHA256: download into the cache (once) and check it
    if [ ! -f "$cache/$2" ]; then
        curl -sSfL -o "$cache/$2.part" "$1" || { rm -f "$cache/$2.part"; echo "Could not download $1" >&2; exit 1; }
        mv "$cache/$2.part" "$cache/$2"
    fi
    echo "$3  $cache/$2" | sha256sum -c --quiet - || { rm -f "$cache/$2"; echo "Checksum mismatch: $2 (the download was discarded)" >&2; exit 1; }
}

echo "== Downloads"
get "https://github.com/mamedev/mame/archive/refs/tags/$MAME_TAG.tar.gz" "$MAME_TAG.tar.gz" "$MAME_SHA"
get "$PY_URL" "$PY_FILE" "$PY_SHA"
[ -f "$cache/$ZSTD_WHL" ] || zstd_url=$(curl -sSf https://pypi.org/pypi/zstandard/0.25.0/json \
    | python3 -c "import sys, json; print(next(u['url'] for u in json.load(sys.stdin)['urls'] if u['filename'] == '$ZSTD_WHL'))")
get "${zstd_url:-}" "$ZSTD_WHL" "$ZSTD_SHA"
get "$TOOL_URL" appimagetool-x86_64.AppImage "$TOOL_SHA"
get "$RUNTIME_URL" runtime-x86_64 "$RUNTIME_SHA"
gamedb=$(python3 - "$root/CHD_Manager.pyw" <<'EOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'GAMEDB_FILE = \("gameInfo\.db", "([^"]+)"\s*"([^"]+)", "([0-9a-f]{64})"\)', src)
print(m.group(1) + m.group(2), m.group(3))
EOF
)
get "${gamedb% *}" gameInfo.db "${gamedb#* }"

echo "== chdman (MAME $MAME_TAG, tools only; the first build takes a while)"
chdman=$cache/chdman-$MAME_TAG
if [ ! -x "$chdman" ]; then
    rm -rf "$work/mame" && mkdir -p "$work/mame"
    tar -xzf "$cache/$MAME_TAG.tar.gz" -C "$work/mame" --strip-components=1
    opts="TOOLS=1 EMULATOR=0 NOWERROR=1 PYTHON_EXECUTABLE=python3 USE_QTDEBUG=0 NO_USE_PORTAUDIO=1 NO_USE_PULSEAUDIO=1 NO_USE_MIDI=1 NO_X11=1 NO_OPENGL=1"
    {   # MAME's project generator first, on its own: the chdman-only target below would otherwise be passed to its build too
        make -C "$work/mame" -j"$(nproc)" $opts 3rdparty/genie/bin/linux/genie &&
        make -C "$work/mame" -j"$(nproc)" $opts LDOPTS="-static-libstdc++ -static-libgcc" MAKEPARAMS="-R chdman" linux_x64
    } >"$work/mame-build.log" 2>&1 \
        || { tail -40 "$work/mame-build.log"; echo "The chdman build failed (whole log: build/appimage/mame-build.log)." >&2; exit 1; }
    strip -o "$chdman" "$work/mame/chdman"
    rm -rf "$work/mame"
fi
"$chdman" --help 2>&1 | head -1

echo "== AppDir"
ver=$(sed -n 's/^APP_VER = "\([^"]*\)".*/\1/p' "$root/CHD_Manager.pyw")
app=$work/AppDir
share=$app/usr/share/$ID
rm -rf "$app" && mkdir -p "$app/usr/python" "$share"
tar -xzf "$cache/$PY_FILE" -C "$app/usr/python" --strip-components=1
py=$app/usr/python/bin/python3
"$py" -m pip install --quiet --no-index --no-compile --disable-pip-version-check --root-user-action=ignore "$cache/$ZSTD_WHL"
"$py" -m pip uninstall --quiet -y pip >/dev/null 2>&1 || true
lib=$(echo "$app"/usr/python/lib/python3.*)
# The Tk that comes with python-build-standalone draws text with old X bitmap fonts only (no Xft), so every label would be
# 'fixed'. Python's Tk bridge is rebuilt here against Ubuntu's Tk 8.6, which uses the desktop's own fonts (Xft + fontconfig),
# and that Tk is bundled. fontconfig, freetype and the X libraries themselves come from the system, as AppImages should.
mkdir -p "$work/clinic"
for f in _tkinter.c tkappinit.c tkinter.h clinic/_tkinter.c.h; do
    flat=$(echo "$f" | tr / _)
    eval sha=\$TKSRC_SHA_$(echo "$flat" | tr -c 'a-zA-Z0-9\n' _)
    get "https://raw.githubusercontent.com/python/cpython/v$PY_VER/Modules/$f" "cpython-$PY_VER-$flat" "$sha"
    cp "$cache/cpython-$PY_VER-$flat" "$work/$f"
done
inc=$(echo "$app"/usr/python/include/python3.*)
gcc -O2 -shared -fPIC -DWITH_APPINIT=1 -DPy_BUILD_CORE_MODULE -I"$inc" -I"$inc/internal" -I/usr/include/tcl8.6 -o "$lib/lib-dynload/$(basename "$lib"/lib-dynload/_tkinter*.so)" \
    "$work/_tkinter.c" "$work/tkappinit.c" -ltk8.6 -ltcl8.6 -Wl,--disable-new-dtags,-rpath,'$ORIGIN/../../../../lib'
mkdir -p "$app/usr/lib" "$app/usr/share/tcltk"
for l in libtk8.6.so libtcl8.6.so libXft.so.2 libXss.so.1 libXrender.so.1; do cp -L "/usr/lib/x86_64-linux-gnu/$l" "$app/usr/lib/"; done
cp -r /usr/share/tcltk/tcl8.6 /usr/share/tcltk/tk8.6 "$app/usr/share/tcltk/"
for p in libtcl8.6 libtk8.6 libxft2 libxss1 libxrender1; do      # their licenses travel with them
    mkdir -p "$app/usr/share/doc/$p" && cp "/usr/share/doc/$p/copyright" "$app/usr/share/doc/$p/"
done
get "https://raw.githubusercontent.com/AppImage/type2-runtime/20251108/LICENSE" type2-runtime-LICENSE "$RUNTIME_LICENSE_SHA"
mkdir -p "$app/usr/share/doc/appimage-runtime" && cp "$cache/type2-runtime-LICENSE" "$app/usr/share/doc/appimage-runtime/LICENSE"
rm -rf "$app"/usr/python/lib/libtcl9* "$app"/usr/python/lib/tcl9* "$app"/usr/python/lib/tk9* "$app"/usr/python/lib/itcl* "$app"/usr/python/lib/thread*
rm -rf "$lib/test" "$lib/idlelib" "$lib/ensurepip" "$lib/lib2to3" "$lib/turtledemo" "$lib"/config-*/libpython*.a "$app/usr/python/include"
find "$app/usr/python" -name __pycache__ -type d -prune -exec rm -rf {} +
cp "$root/CHD_Manager.pyw" "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.txt" "$root/README.md" "$cache/gameInfo.db" "$share/"
cp "$chdman" "$share/chdman"
cat > "$app/AppRun" <<EOF
#!/bin/sh
here=\$(dirname "\$(readlink -f "\$0")")
export TCL_LIBRARY="\$here/usr/share/tcltk/tcl8.6" TK_LIBRARY="\$here/usr/share/tcltk/tk8.6"
exec "\$here/usr/python/bin/python3" -I "\$here/usr/share/$ID/CHD_Manager.pyw" "\$@"
EOF
chmod 755 "$app/AppRun" "$share/chdman"
cat > "$app/$ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Game Format Converter Enhanced
Comment=Convert game images and files between formats
Exec=$ID %F
Icon=$ID
Categories=Utility;
Terminal=false
EOF
rm -rf "$work/icons" && mkdir -p "$work/icons"
icotool -x -o "$work/icons" "$root/assets/icon.ico"
cp "$(ls -S "$work"/icons/*.png | head -1)" "$app/$ID.png"        # the largest size in the .ico
ln -sf "$ID.png" "$app/.DirIcon"

echo "== Test run inside the build"
"$app/AppRun" cli --version
env -i "$py" -I -c "import _tkinter, zstandard; print('Tk', _tkinter.TK_VERSION, '+ zstandard', zstandard.__version__)"
ldd "$lib"/lib-dynload/_tkinter*.so | grep -E "not found|=> /usr/lib/x86_64" && { echo "The Tk bridge doesn't load only the bundled Tk." >&2; exit 1; } || true

echo "== AppImage"
out=$root/dist/Game-Format-Converter-Enhanced-$ver-x86_64.AppImage
chmod +x "$cache/appimagetool-x86_64.AppImage"
ARCH=x86_64 "$cache/appimagetool-x86_64.AppImage" --appimage-extract-and-run --no-appstream \
    --runtime-file "$cache/runtime-x86_64" "$app" "$out" >"$work/appimagetool.log" 2>&1 \
    || { cat "$work/appimagetool.log"; exit 1; }
chmod 755 "$out"
echo
echo "Done: $out ($(du -h "$out" | cut -f1))"
echo "For the release notes (the updater reads the checksum from the line that names the file):"
(cd "$root/dist" && sha256sum "$(basename "$out")")
