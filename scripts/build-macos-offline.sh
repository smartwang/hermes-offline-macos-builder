#!/bin/bash
set -euo pipefail

ARCH="${1:-}"
case "$ARCH" in
  arm64)
    EXPECTED_MACHINE=arm64; RG_ARCH=aarch64; NODE_ARCH=arm64; UV_ARCH=aarch64
    UV_SHA256=61c04acc52a33ef0f331e494bdfbedcdb6c26c6970c022ed3699e5860f8930e3
    RG_SHA256=3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
    NODE_SHA256=ef28d8fab2c0e4314522d4bb1b7173270aa3937e93b92cb7de79c112ac1fa953
    ELECTRON_SHA256=e889b35e399f374f5dca932195287b373c4b43f8bf242e50c35f88a751511a13
    ;;
  x64)
    EXPECTED_MACHINE=x86_64; RG_ARCH=x86_64; NODE_ARCH=x64; UV_ARCH=x86_64
    UV_SHA256=c4c4de482da9ccdd076dc4fb5cfe7b740609029385c72f58606be3153602387d
    RG_SHA256=af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1
    NODE_SHA256=b8da981b8a0b1241b70249204916da76c63573ddf5814dbd2d1e41069105cb81
    ELECTRON_SHA256=5d171014187fb737f34c70b09ea886215e3d88a1b79cb5370a0815c34dd15668
    ;;
  *) echo "Usage: $0 arm64|x64" >&2; exit 2 ;;
esac

[ "$(uname -s)" = "Darwin" ] || { echo "This builder must run on macOS." >&2; exit 1; }
[ "$(uname -m)" = "$EXPECTED_MACHINE" ] || {
  echo "Runner architecture mismatch: expected=$EXPECTED_MACHINE actual=$(uname -m)" >&2
  exit 1
}

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
HERMES_SOURCE_DIR="${HERMES_SOURCE_DIR:-$ROOT/upstream}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/out}"
WORK_DIR="${WORK_DIR:-$ROOT/work/$ARCH}"
HERMES_REF="${HERMES_REF:-v2026.7.7.2}"
HERMES_VERSION="${HERMES_VERSION:-0.18.2}"
HERMES_COMMIT_EXPECTED="${HERMES_COMMIT_EXPECTED:-9de9c25f620ff7f1ce0fd5457d596052d5159596}"
PYTHON_VERSION="${PYTHON_VERSION:-3.11.15}"
NODE_VERSION="${NODE_VERSION:-22.23.1}"
UV_VERSION="${UV_VERSION:-0.11.29}"
RG_VERSION="${RG_VERSION:-15.2.0}"
ELECTRON_VERSION=40.10.2
BUNDLE_NAME="Hermes-Offline-macOS-$ARCH-$HERMES_VERSION"
BUNDLE="$WORK_DIR/$BUNDLE_NAME"
PAYLOAD="$BUNDLE/payload"
DOWNLOADS="$WORK_DIR/downloads"
VERIFY_FILE="$OUTPUT_DIR/$BUNDLE_NAME.verification.txt"
ZIP_PATH="$OUTPUT_DIR/$BUNDLE_NAME.zip"
SHA_PATH="$ZIP_PATH.sha256"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Required command missing: $1"; }

for cmd in curl git npm node ditto codesign shasum tar file python3 sandbox-exec otool spctl lipo install_name_tool; do need "$cmd"; done
[ -d "$HERMES_SOURCE_DIR/.git" ] || fail "Hermes source checkout not found: $HERMES_SOURCE_DIR"

rm -rf "$WORK_DIR" "$ZIP_PATH" "$SHA_PATH" "$VERIFY_FILE"
mkdir -p "$PAYLOAD/bin" "$PAYLOAD/runtime/python" "$PAYLOAD/desktop" "$DOWNLOADS" "$OUTPUT_DIR" "$BUNDLE/tools"

ACTUAL_COMMIT="$(git -C "$HERMES_SOURCE_DIR" rev-parse HEAD)"
[ "$ACTUAL_COMMIT" = "$HERMES_COMMIT_EXPECTED" ] || \
  fail "Hermes commit mismatch: expected=$HERMES_COMMIT_EXPECTED actual=$ACTUAL_COMMIT"
ACTUAL_VERSION="$(cd "$HERMES_SOURCE_DIR" && python3 -c 'import pathlib,tomllib; print(tomllib.loads(pathlib.Path("pyproject.toml").read_text())["project"]["version"])')"
[ "$ACTUAL_VERSION" = "$HERMES_VERSION" ] || fail "Hermes version mismatch: $ACTUAL_VERSION"
ACTUAL_ELECTRON_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["devDependencies"]["electron"])' "$HERMES_SOURCE_DIR/apps/desktop/package.json")"
[ "$ACTUAL_ELECTRON_VERSION" = "$ELECTRON_VERSION" ] || fail "Electron version mismatch: $ACTUAL_ELECTRON_VERSION"
BUILD_OS="$(sw_vers -productVersion)"

say "Download pinned uv $UV_VERSION"
UV_ASSET="uv-$UV_ARCH-apple-darwin.tar.gz"
UV_BASE="https://github.com/astral-sh/uv/releases/download/$UV_VERSION"
curl -fL --retry 4 "$UV_BASE/$UV_ASSET" -o "$DOWNLOADS/$UV_ASSET"
printf '%s  %s\n' "$UV_SHA256" "$UV_ASSET" > "$DOWNLOADS/$UV_ASSET.sha256"
(cd "$DOWNLOADS" && shasum -a 256 -c "$UV_ASSET.sha256")
mkdir -p "$DOWNLOADS/uv-extract"
tar -xzf "$DOWNLOADS/$UV_ASSET" -C "$DOWNLOADS/uv-extract"
UV_SOURCE="$(find "$DOWNLOADS/uv-extract" -type f -name uv | head -1)"
UVX_SOURCE="$(find "$DOWNLOADS/uv-extract" -type f -name uvx | head -1)"
install -m 0755 "$UV_SOURCE" "$PAYLOAD/bin/uv"
install -m 0755 "$UVX_SOURCE" "$PAYLOAD/bin/uvx"
UV="$PAYLOAD/bin/uv"
"$UV" --version

say "Install relocatable Python $PYTHON_VERSION into payload"
UV_PYTHON_INSTALL_DIR="$PAYLOAD/runtime/python" UV_PYTHON_PREFERENCE=only-managed \
  "$UV" python install "$PYTHON_VERSION"
BUNDLE_PYTHON="$(find "$PAYLOAD/runtime/python" \( -type f -o -type l \) -path '*/bin/python3.11' | head -1)"
[ -x "$BUNDLE_PYTHON" ] || fail "Bundled Python not found"
say "Rewrite Python Mach-O references for relocation"
python3 "$ROOT/scripts/relocate_macho.py" "$PAYLOAD/runtime/python"
PYTHON_RELOCATION_PROBE="$WORK_DIR/python-relocation-probe"
ditto "$PAYLOAD/runtime/python" "$PYTHON_RELOCATION_PROBE"
PROBE_PYTHON="$(find "$PYTHON_RELOCATION_PROBE" \( -type f -o -type l \) -path '*/bin/python3.11' | head -1)"
[ -x "$PROBE_PYTHON" ] || fail "Relocated Python probe executable missing"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  "$PROBE_PYTHON" -c 'import hashlib,ssl,sqlite3,sys; print("python-relocation-probe=OK", sys.version)'
rm -rf "$PYTHON_RELOCATION_PROBE"
"$BUNDLE_PYTHON" --version

say "Create clean pinned Hermes checkout"
git clone --local --no-hardlinks "$HERMES_SOURCE_DIR" "$PAYLOAD/hermes-agent"
git -C "$PAYLOAD/hermes-agent" checkout --detach "$HERMES_COMMIT_EXPECTED"
git -C "$PAYLOAD/hermes-agent" remote set-url origin https://github.com/NousResearch/hermes-agent.git
[ -z "$(git -C "$PAYLOAD/hermes-agent" status --porcelain)" ] || fail "Payload checkout is dirty"

say "Build hash-locked Python dependency set"
BUILD_VENV="$WORK_DIR/deps-venv"
UV_PROJECT_ENVIRONMENT="$BUILD_VENV" UV_PYTHON="$BUNDLE_PYTHON" \
  "$UV" sync --project "$PAYLOAD/hermes-agent" --extra all --locked --no-dev
SITE_PACKAGES="$("$BUILD_VENV/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
ditto "$SITE_PACKAGES" "$PAYLOAD/site-packages"
"$BUNDLE_PYTHON" "$ROOT/scripts/sanitize_site_packages.py" "$PAYLOAD/site-packages" \
  --forbid "$WORK_DIR" --forbid "$HERMES_SOURCE_DIR" --forbid "$PAYLOAD/hermes-agent"
python3 "$ROOT/scripts/relocate_macho.py" "$PAYLOAD/site-packages"
SITE_PACKAGES_RELOCATION_PROBE="$WORK_DIR/site-packages-relocation-probe"
mv "$PAYLOAD/site-packages" "$SITE_PACKAGES_RELOCATION_PROBE"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONPATH="$SITE_PACKAGES_RELOCATION_PROBE" \
  "$BUNDLE_PYTHON" -c \
  'import charset_normalizer.md,charset_normalizer.md__mypyc,cryptography.hazmat.bindings._rust,google._upb._message,uvloop.loop; print("site-packages-relocation-probe=OK")'
mv "$SITE_PACKAGES_RELOCATION_PROBE" "$PAYLOAD/site-packages"

say "Pre-seed bundled skills without target-machine code execution"
mkdir -p "$PAYLOAD/home-seed"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  HERMES_HOME="$PAYLOAD/home-seed" \
  PYTHONPATH="$PAYLOAD/hermes-agent:$PAYLOAD/site-packages" \
  "$BUNDLE_PYTHON" "$PAYLOAD/hermes-agent/tools/skills_sync.py"
[ -d "$PAYLOAD/home-seed/skills" ] || fail "Bundled skills seed was not created"
[ -z "$(git -C "$PAYLOAD/hermes-agent" status --porcelain)" ] || fail "Dependency build dirtied payload checkout"

say "Download pinned Node.js $NODE_VERSION"
NODE_ASSET="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
NODE_BASE="https://nodejs.org/dist/v$NODE_VERSION"
curl -fL --retry 4 "$NODE_BASE/$NODE_ASSET" -o "$DOWNLOADS/$NODE_ASSET"
printf '%s  %s\n' "$NODE_SHA256" "$NODE_ASSET" > "$DOWNLOADS/$NODE_ASSET.sha256"
(cd "$DOWNLOADS" && shasum -a 256 -c "$NODE_ASSET.sha256")
tar -xzf "$DOWNLOADS/$NODE_ASSET" -C "$DOWNLOADS"
mv "$DOWNLOADS/node-v$NODE_VERSION-darwin-$NODE_ARCH" "$PAYLOAD/node"
"$PAYLOAD/node/bin/node" --version

say "Download pinned ripgrep $RG_VERSION"
RG_ASSET="ripgrep-$RG_VERSION-$RG_ARCH-apple-darwin.tar.gz"
RG_BASE="https://github.com/BurntSushi/ripgrep/releases/download/$RG_VERSION"
curl -fL --retry 4 "$RG_BASE/$RG_ASSET" -o "$DOWNLOADS/$RG_ASSET"
printf '%s  %s\n' "$RG_SHA256" "$RG_ASSET" > "$DOWNLOADS/$RG_ASSET.sha256"
(cd "$DOWNLOADS" && shasum -a 256 -c "$RG_ASSET.sha256")
mkdir -p "$DOWNLOADS/rg-extract"
tar -xzf "$DOWNLOADS/$RG_ASSET" -C "$DOWNLOADS/rg-extract"
RG_SOURCE="$(find "$DOWNLOADS/rg-extract" -type f -name rg | head -1)"
install -m 0755 "$RG_SOURCE" "$PAYLOAD/bin/rg"
"$PAYLOAD/bin/rg" --version | head -1

say "Download pinned Electron $ELECTRON_VERSION"
ELECTRON_ASSET="electron-v$ELECTRON_VERSION-darwin-$NODE_ARCH.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/$ELECTRON_ASSET"
curl -fL --retry 4 "$ELECTRON_URL" -o "$DOWNLOADS/$ELECTRON_ASSET"
printf '%s  %s\n' "$ELECTRON_SHA256" "$ELECTRON_ASSET" > "$DOWNLOADS/$ELECTRON_ASSET.sha256"
(cd "$DOWNLOADS" && shasum -a 256 -c "$ELECTRON_ASSET.sha256")

say "Install integrity-pinned npm tarballs without lifecycle scripts"
(cd "$HERMES_SOURCE_DIR" && npm ci --ignore-scripts --no-audit --no-fund)
ELECTRON_PACKAGE_DIR="$HERMES_SOURCE_DIR/apps/desktop/node_modules/electron"
rm -rf "$ELECTRON_PACKAGE_DIR/dist"
mkdir -p "$ELECTRON_PACKAGE_DIR/dist"
ditto -x -k "$DOWNLOADS/$ELECTRON_ASSET" "$ELECTRON_PACKAGE_DIR/dist"
printf '%s' 'Electron.app/Contents/MacOS/Electron' > "$ELECTRON_PACKAGE_DIR/path.txt"
[ "$(cat "$ELECTRON_PACKAGE_DIR/dist/version")" = "$ELECTRON_VERSION" ] || fail "Electron dist version mismatch"
lipo "$ELECTRON_PACKAGE_DIR/dist/Electron.app/Contents/MacOS/Electron" -verify_arch "$EXPECTED_MACHINE"

NO_NETWORK_PROFILE='(version 1) (allow default) (deny network*)'
NODE_PTY_PREBUILD_DIR="$HERMES_SOURCE_DIR/node_modules/node-pty/prebuilds/darwin-$ARCH"
[ -d "$NODE_PTY_PREBUILD_DIR" ] || fail "Pinned node-pty prebuild missing: $NODE_PTY_PREBUILD_DIR"
find "$NODE_PTY_PREBUILD_DIR" -type f -name '*.node' -print | while IFS= read -r prebuild; do
  lipo "$prebuild" -verify_arch "$EXPECTED_MACHINE"
done
[ -n "$(find "$NODE_PTY_PREBUILD_DIR" -type f -name '*.node' -print -quit)" ] || \
  fail "Pinned node-pty prebuild contains no native module"
say "Build Desktop renderer and stage pinned N-API prebuilds without network"
DESKTOP_PACKAGE_JSON="$HERMES_SOURCE_DIR/apps/desktop/package.json"
DESKTOP_PACKAGE_BACKUP="$WORK_DIR/desktop-package.json.original"
(cd "$HERMES_SOURCE_DIR/apps/desktop" && \
  GITHUB_SHA="$HERMES_COMMIT_EXPECTED" GITHUB_REF_NAME="$HERMES_REF" \
  CSC_IDENTITY_AUTO_DISCOVERY=false sandbox-exec -p "$NO_NETWORK_PROFILE" npm run build)
"$BUNDLE_PYTHON" - "$HERMES_SOURCE_DIR/apps/desktop/build/install-stamp.json" \
  "$HERMES_COMMIT_EXPECTED" <<'PY'
import json, pathlib, sys
stamp = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if stamp.get("commit") != sys.argv[2] or stamp.get("dirty") is not False:
    raise SystemExit(f"invalid Desktop install stamp: {stamp}")
print(f"desktop-install-stamp=OK {stamp['commit']}")
PY

say "Package Desktop without scanning bundled renderer dependencies"
cp "$DESKTOP_PACKAGE_JSON" "$DESKTOP_PACKAGE_BACKUP"
python3 - "$DESKTOP_PACKAGE_JSON" "$ELECTRON_PACKAGE_DIR/dist" "$ELECTRON_VERSION" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data["dependencies"] = {}
data["optionalDependencies"] = {}
data["build"]["electronDist"] = sys.argv[2]
data["build"]["electronVersion"] = sys.argv[3]
data["build"]["npmRebuild"] = False
data["build"]["nodeGypRebuild"] = False
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
(cd "$HERMES_SOURCE_DIR/apps/desktop" && CSC_IDENTITY_AUTO_DISCOVERY=false \
  sandbox-exec -p "$NO_NETWORK_PROFILE" npm run builder -- --dir --publish never)
cp "$DESKTOP_PACKAGE_BACKUP" "$DESKTOP_PACKAGE_JSON"
[ -z "$(git -C "$HERMES_SOURCE_DIR" status --porcelain -- apps/desktop/package.json)" ] || \
  fail "Desktop package.json was not restored"
if [ "$ARCH" = arm64 ]; then
  APP_SOURCE="$HERMES_SOURCE_DIR/apps/desktop/release/mac-arm64/Hermes.app"
else
  APP_SOURCE="$HERMES_SOURCE_DIR/apps/desktop/release/mac/Hermes.app"
fi
[ -d "$APP_SOURCE" ] || fail "Desktop app not found: $APP_SOURCE"
NATIVE_LIST="$WORK_DIR/desktop-native-modules.txt"
find "$APP_SOURCE/Contents/Resources" -type f -name '*.node' -print > "$NATIVE_LIST"
[ -s "$NATIVE_LIST" ] || fail "Desktop node-pty native binary missing"
while IFS= read -r native_module; do
  codesign --force --sign - "$native_module"
done < "$NATIVE_LIST"
codesign --force --deep --sign - "$APP_SOURCE"
codesign --verify --deep --strict "$APP_SOURCE"
APP_BINARY="$APP_SOURCE/Contents/MacOS/Hermes"
file -b "$APP_BINARY"
lipo "$APP_BINARY" -verify_arch "$EXPECTED_MACHINE"
ELECTRON_RUNTIME_ARCH="$(ELECTRON_RUN_AS_NODE=1 sandbox-exec -p "$NO_NETWORK_PROFILE" \
  "$APP_BINARY" -p 'process.arch')"
[ "$ELECTRON_RUNTIME_ARCH" = "$ARCH" ] || \
  fail "Electron runtime arch mismatch: expected=$ARCH actual=$ELECTRON_RUNTIME_ARCH"
while IFS= read -r native_module; do
  native_info="$(file -b "$native_module")"
  printf '%s\n' "$native_info"
  lipo "$native_module" -verify_arch "$EXPECTED_MACHINE"
  codesign --verify --strict "$native_module"
  NATIVE_MODULE="$native_module" ELECTRON_RUN_AS_NODE=1 sandbox-exec -p "$NO_NETWORK_PROFILE" \
    "$APP_BINARY" -e \
    'require(process.env.NATIVE_MODULE); console.log("native-module-load=OK " + process.env.NATIVE_MODULE)'
done < "$NATIVE_LIST"
ditto "$APP_SOURCE" "$PAYLOAD/desktop/Hermes.app"

say "Validate Mach-O architecture and reject runner-bound load commands"
find "$PAYLOAD" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.node' \) -print |
while IFS= read -r macho; do
  macho_info="$(file -b "$macho")"
  case "$macho_info" in
    *Mach-O*) ;;
    *) continue ;;
  esac
  if ! lipo "$macho" -verify_arch "$EXPECTED_MACHINE"; then
    fail "Mach-O architecture mismatch: expected=$EXPECTED_MACHINE file=$macho info=$macho_info"
  fi
  if ! otool_load_raw="$(otool -l "$macho")"; then
    fail "otool -l failed: $macho"
  fi
  if ! otool_link_raw="$(otool -L "$macho")"; then
    fail "otool -L failed: $macho"
  fi
  load_commands="$(printf '%s\n' "$otool_load_raw" | \
    grep -E '^[[:space:]]+(name|path) ' || true)"
  linked_libraries="$(printf '%s\n' "$otool_link_raw" | \
    grep -E '^[[:space:]]+(/|@)' || true)"
  for forbidden_path in "$WORK_DIR" "$HERMES_SOURCE_DIR"; do
    forbidden_metadata="$(printf '%s\n%s\n' "$load_commands" "$linked_libraries" | \
      grep -F -m 1 "$forbidden_path" || true)"
    [ -z "$forbidden_metadata" ] || \
      fail "Runner path in Mach-O load metadata: file=$macho metadata=$forbidden_metadata"
  done
done

say "Assemble installer and metadata"
cp "$ROOT/templates/install-offline.sh" "$BUNDLE/install-offline.sh"
cp "$ROOT/templates/install-offline.command" "$BUNDLE/install-offline.command"
cp "$ROOT/scripts/manifest_tool.py" "$BUNDLE/tools/manifest_tool.py"
chmod 0755 "$BUNDLE/install-offline.sh" "$BUNDLE/install-offline.command" "$BUNDLE/tools/manifest_tool.py"
python3 "$ROOT/scripts/render_template.py" "$ROOT/templates/README-中文.md" "$BUNDLE/README-中文.md" \
  --set "HERMES_VERSION=$HERMES_VERSION" --set "HERMES_REF=$HERMES_REF" \
  --set "HERMES_COMMIT=$HERMES_COMMIT_EXPECTED" --set "ARCH=$ARCH" \
  --set "BUILD_OS=$BUILD_OS" --set "PYTHON_VERSION=$PYTHON_VERSION" \
  --set "NODE_VERSION=$NODE_VERSION" --set "UV_VERSION=$UV_VERSION" --set "RG_VERSION=$RG_VERSION"

DESKTOP_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$HERMES_SOURCE_DIR/apps/desktop/package.json")"
cat > "$WORK_DIR/build-metadata.json" <<EOF
{
  "hermesVersion": "$HERMES_VERSION",
  "hermesRef": "$HERMES_REF",
  "hermesCommit": "$HERMES_COMMIT_EXPECTED",
  "desktopVersion": "$DESKTOP_VERSION",
  "platform": "macos",
  "arch": "$ARCH",
  "buildOS": "$BUILD_OS",
  "components": {
    "python": "$PYTHON_VERSION",
    "node": "$NODE_VERSION",
    "uv": "$UV_VERSION",
    "ripgrep": "$RG_VERSION",
    "electron": "$ELECTRON_VERSION",
    "ffmpeg": null,
    "portableGit": null
  },
  "downloadSHA256": {
    "nodeArchive": "$NODE_SHA256",
    "uvArchive": "$UV_SHA256",
    "ripgrepArchive": "$RG_SHA256",
    "electronArchive": "$ELECTRON_SHA256"
  },
  "omissions": ["browser-runtime", "ffmpeg", "portable-git", "model-credentials", "local-model-weights"]
}
EOF
"$BUNDLE_PYTHON" "$ROOT/scripts/manifest_tool.py" create \
  --root "$PAYLOAD" --output "$BUNDLE/MANIFEST.json" --metadata "$WORK_DIR/build-metadata.json"

say "Create system-shasum bootstrap list for all regular bundle files"
BUNDLE_CHECKSUMS="$BUNDLE/BUNDLE-CONTENTS.sha256"
(
  cd "$BUNDLE"
  find . -type f ! -name 'BUNDLE-CONTENTS.sha256' -print | LC_ALL=C sort |
  while IFS= read -r bundle_file; do
    shasum -a 256 "$bundle_file"
  done
) > "$BUNDLE_CHECKSUMS"
[ -s "$BUNDLE_CHECKSUMS" ] || fail "Bundle checksum list is empty"

run_install_test() {
  bundle_root="$1"
  test_root="$2"
  log_file="$3"
  test_home="$test_root/home"
  test_hermes_home="$test_home/.hermes"
  test_applications="$test_home/Applications"
  sandbox_profile='(version 1) (allow default) (deny network*)'
  rm -rf "$test_root"
  mkdir -p "$test_applications"
  sandbox-exec -p "$sandbox_profile" /usr/bin/env -i \
    HOME="$test_home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    PIP_NO_INDEX=1 UV_OFFLINE=1 \
    /bin/bash "$bundle_root/install-offline.sh" \
      --applications-dir "$test_applications" --no-path --no-launch 2>&1 | tee "$log_file"
  hermes="$test_hermes_home/hermes-agent/venv/bin/hermes"
  python="$test_hermes_home/hermes-agent/venv/bin/python"
  app="$test_applications/Hermes.app"
  HERMES_HOME="$test_hermes_home" PYTHONPATH="$test_hermes_home/hermes-agent" \
    sandbox-exec -p "$sandbox_profile" "$hermes" --version
  sandbox-exec -p "$sandbox_profile" "$python" -c \
    'import acp,aiohttp,fastapi,google_auth_httplib2,google_auth_oauthlib,googleapiclient.discovery,hermes_cli,mcp,openai,pydantic,simple_term_menu,uvicorn,yaml,youtube_transcript_api; print("imports=OK")'
  sandbox-exec -p "$sandbox_profile" "$test_hermes_home/node/bin/node" --version
  sandbox-exec -p "$sandbox_profile" "$test_hermes_home/bin/rg" --version | head -1
  ELECTRON_RUN_AS_NODE=1 sandbox-exec -p "$sandbox_profile" \
    "$app/Contents/MacOS/Hermes" -e \
    'console.log("electron=" + process.versions.electron + " node=" + process.versions.node + " arch=" + process.arch)'
  gui_log="$test_root/electron-gui.log"
  HERMES_HOME="$test_hermes_home" sandbox-exec -p "$sandbox_profile" \
    "$app/Contents/MacOS/Hermes" --disable-gpu >"$gui_log" 2>&1 &
  gui_pid=$!
  gui_wait=0
  while [ "$gui_wait" -lt 8 ]; do
    sleep 1
    kill -0 "$gui_pid" 2>/dev/null || {
      wait "$gui_pid" || true
      fail "Hermes Desktop GUI exited during startup; log=$gui_log"
    }
    gui_wait=$((gui_wait + 1))
  done
  kill "$gui_pid" 2>/dev/null || true
  wait "$gui_pid" || true
  echo "electron-gui-startup=OK"
  codesign --verify --deep --strict "$app"
  codesign -dv --verbose=4 "$app" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|Runtime Version)=' || true
  if spctl --assess --type execute --verbose=4 "$app"; then
    echo "gatekeeper-assessment=accepted"
  else
    echo "gatekeeper-assessment=not-notarized-ad-hoc-expected"
  fi
  installed_runtime_python="$(find "$test_hermes_home/runtime/python" \( -type f -o -type l \) -path '*/bin/python3.11' | head -1)"
  [ -x "$installed_runtime_python" ] || fail "Installed runtime Python missing"
  sandbox-exec -p "$sandbox_profile" "$installed_runtime_python" --version
  venv_base_python="$(sandbox-exec -p "$sandbox_profile" "$python" -c 'import os,sys; print(os.path.realpath(sys._base_executable))')"
  case "$venv_base_python" in
    "$test_hermes_home/runtime/"*) ;;
    *) fail "Venv Python escapes installed runtime: $venv_base_python" ;;
  esac
  [ -z "$(git -C "$test_hermes_home/hermes-agent" status --porcelain)" ] || fail "Installed checkout is dirty"
}

say "Pre-archive isolated installation test"
: > "$VERIFY_FILE"
{
  echo "bundle=$BUNDLE_NAME"
  echo "hermes_commit=$HERMES_COMMIT_EXPECTED"
  echo "runner_arch=$(uname -m)"
  echo "build_os=$BUILD_OS"
  run_install_test "$BUNDLE" "$WORK_DIR/test-prezip" "$WORK_DIR/install-prezip.log"
} 2>&1 | tee -a "$VERIFY_FILE"

# Reclaim runner disk before making and re-extracting the final archive.
rm -rf "$BUILD_VENV" "$HERMES_SOURCE_DIR/node_modules" "$HERMES_SOURCE_DIR/apps/desktop/node_modules" "$WORK_DIR/test-prezip" "$DOWNLOADS"

say "Create macOS ZIP with Unix modes, symlinks and app metadata"
ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" | (cd "$OUTPUT_DIR" && sed "s#  .*/#  #") > "$SHA_PATH"

say "Extract final ZIP and repeat payload + install verification"
EXTRACT_ROOT="$WORK_DIR/final-extract"
rm -rf "$EXTRACT_ROOT"
mkdir -p "$EXTRACT_ROOT"
ditto -x -k "$ZIP_PATH" "$EXTRACT_ROOT"
EXTRACTED_BUNDLE="$EXTRACT_ROOT/$BUNDLE_NAME"
(cd "$EXTRACTED_BUNDLE" && shasum -a 256 -c --quiet BUNDLE-CONTENTS.sha256) | tee -a "$VERIFY_FILE"
EXTRACTED_PYTHON="$(find "$EXTRACTED_BUNDLE/payload/runtime/python" \( -type f -o -type l \) -path '*/bin/python3.11' | head -1)"
"$EXTRACTED_PYTHON" "$EXTRACTED_BUNDLE/tools/manifest_tool.py" verify \
  --root "$EXTRACTED_BUNDLE/payload" --manifest "$EXTRACTED_BUNDLE/MANIFEST.json" | tee -a "$VERIFY_FILE"
run_install_test "$EXTRACTED_BUNDLE" "$WORK_DIR/test-finalzip" "$WORK_DIR/install-finalzip.log" 2>&1 | tee -a "$VERIFY_FILE"

say "Final archive checks"
(cd "$OUTPUT_DIR" && shasum -a 256 -c "$(basename "$SHA_PATH")") | tee -a "$VERIFY_FILE"
unzip -Z -1 "$ZIP_PATH" | wc -l | awk '{print "zip_entries=" $1}' | tee -a "$VERIFY_FILE"
stat -f 'zip_bytes=%z' "$ZIP_PATH" | tee -a "$VERIFY_FILE"
echo "build-and-verification=OK" | tee -a "$VERIFY_FILE"
printf 'Artifact: %s\nChecksum: %s\nVerification: %s\n' "$ZIP_PATH" "$SHA_PATH" "$VERIFY_FILE"
