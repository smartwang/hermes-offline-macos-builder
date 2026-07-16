#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"
MANIFEST="$SCRIPT_DIR/MANIFEST.json"
MANIFEST_TOOL="$SCRIPT_DIR/tools/manifest_tool.py"
BUNDLE_CHECKSUMS="$SCRIPT_DIR/BUNDLE-CONTENTS.sha256"
HERMES_HOME="$HOME/.hermes"
APPLICATIONS_DIR="$HOME/Applications"
MODIFY_PATH=true
LAUNCH_APP=true
BACKUP_ROOT=""
ROLLBACK_NEEDED=false
INSTALLATION_STARTED=false

usage() {
  cat <<'EOF'
Hermes Agent macOS 离线安装器

用法：install-offline.sh [选项]

选项：
  --applications-dir PATH Hermes.app 目录，默认 ~/Applications
  --no-path                不修改 ~/.zprofile 和 ~/.bash_profile
  --no-launch              安装后不启动 Hermes.app
  -h, --help               显示帮助
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --applications-dir)
      [ "$#" -ge 2 ] || { printf '%s\n' '--applications-dir 缺少 PATH 参数。' >&2; exit 2; }
      APPLICATIONS_DIR="$2"; shift 2
      ;;
    --no-path) MODIFY_PATH=false; shift ;;
    --no-launch) LAUNCH_APP=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
info() { printf '→ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || fail "此安装包只能在 macOS 上运行。"
[ -d "$PAYLOAD" ] || fail "payload 目录不存在：$PAYLOAD"
[ -f "$MANIFEST" ] || fail "MANIFEST.json 不存在。"
[ -f "$MANIFEST_TOOL" ] || fail "payload 校验器不存在。"
[ -f "$BUNDLE_CHECKSUMS" ] || fail "BUNDLE-CONTENTS.sha256 不存在。"

info "检查 bundle checksum 清单路径边界..."
  checksum_entries=0
  while IFS= read -r checksum_line; do
    checksum_hash="${checksum_line%%  *}"
    checksum_path="${checksum_line#*  }"
    [ "${#checksum_hash}" -eq 64 ] || fail "bundle checksum 含非法 SHA-256。"
    case "$checksum_hash" in *[!0-9a-f]*) fail "bundle checksum 含非法 SHA-256。" ;; esac
    case "$checksum_path" in
      ./*) ;;
      *) fail "bundle checksum 含非相对路径：$checksum_path" ;;
    esac
    case "/${checksum_path#./}/" in
      *"/../"*|*"/./"*) fail "bundle checksum 含越界路径：$checksum_path" ;;
    esac
    checksum_entries=$((checksum_entries + 1))
  done < "$BUNDLE_CHECKSUMS"
  [ "$checksum_entries" -gt 4 ] || fail "bundle checksum 条目不足。"
  for required_checksum_path in \
    ./install-offline.sh ./MANIFEST.json ./tools/manifest_tool.py; do
    grep -Fq "  $required_checksum_path" "$BUNDLE_CHECKSUMS" || \
      fail "bundle checksum 缺少：$required_checksum_path"
  done
  grep -Fq '  ./payload/' "$BUNDLE_CHECKSUMS" || fail "bundle checksum 未覆盖 payload。"
  info "使用 macOS 系统 shasum 校验离线包普通文件..."
  (cd "$SCRIPT_DIR" && /usr/bin/shasum -a 256 -c --quiet "$(basename "$BUNDLE_CHECKSUMS")")
ok "bundle SHA-256 校验通过"

BUNDLE_PYTHON="$(find "$PAYLOAD/runtime/python" \( -type f -o -type l \) -path '*/bin/python3.11' 2>/dev/null | head -1 || true)"
if [ -z "$BUNDLE_PYTHON" ]; then
  BUNDLE_PYTHON="$(find "$PAYLOAD/runtime/python" \( -type f -o -type l \) -path '*/bin/python3' 2>/dev/null | head -1 || true)"
fi
[ -x "$BUNDLE_PYTHON" ] || fail "找不到离线 Python runtime。请重新解压安装包。"

EXPECTED_ARCH="$("$BUNDLE_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["arch"])' "$MANIFEST")"
MACHINE_ARCH="$(uname -m)"
case "$EXPECTED_ARCH:$MACHINE_ARCH" in
  arm64:arm64|x64:x86_64) ;;
  *) fail "架构不匹配：安装包=$EXPECTED_ARCH，当前 Mac=$MACHINE_ARCH。" ;;
esac

info "校验离线 payload（文件较多，可能需要数分钟）..."
"$BUNDLE_PYTHON" "$MANIFEST_TOOL" verify --root "$PAYLOAD" --manifest "$MANIFEST"
ok "payload 完整性校验通过"

validate_user_path() {
  local label candidate relative current old_ifs component
  label="$1"
  candidate="$2"
  case "$candidate" in
    ""|"/"|"$HOME") fail "拒绝危险的 $label 路径：$candidate" ;;
    *"//"*|*/) fail "$label 不能包含重复或尾随斜杠：$candidate" ;;
    *'*'*|*'?'*|*'['*|*']'*) fail "$label 不能包含 glob 字符：$candidate" ;;
    *\\*) fail "$label 不能包含反斜杠字符：$candidate" ;;
    /*) ;;
    *) fail "$label 必须是绝对路径：$candidate" ;;
  esac
  case "/${candidate#/}/" in
    *"/../"*|*"/./"*) fail "$label 不能包含 . 或 .. 路径段：$candidate" ;;
  esac
  case "$candidate/" in
    "$HOME/"*) ;;
    *) fail "$label 必须位于当前用户 HOME 下：$candidate" ;;
  esac

  relative="${candidate#"$HOME"/}"
  current="$HOME"
  old_ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2086 # Intentional path-component splitting.
  set -- $relative
  IFS="$old_ifs"
  for component in "$@"; do
    [ -n "$component" ] || continue
    current="$current/$component"
    [ ! -L "$current" ] || fail "$label 不能经过符号链接：$current"
  done
}

COMMAND_DIR="$HOME/.local/bin"
validate_user_path "HERMES_HOME" "$HERMES_HOME"
validate_user_path "--applications-dir" "$APPLICATIONS_DIR"
validate_user_path "命令目录" "$COMMAND_DIR"

# Resolve case-folded aliases and physical paths before destructive operations.
mkdir -p "$HERMES_HOME" "$APPLICATIONS_DIR" "$COMMAND_DIR"
HERMES_HOME="$(CDPATH='' cd -- "$HERMES_HOME" && pwd -P)"
APPLICATIONS_DIR="$(CDPATH='' cd -- "$APPLICATIONS_DIR" && pwd -P)"
COMMAND_DIR="$(CDPATH='' cd -- "$COMMAND_DIR" && pwd -P)"
validate_user_path "HERMES_HOME" "$HERMES_HOME"
validate_user_path "--applications-dir" "$APPLICATIONS_DIR"
validate_user_path "命令目录" "$COMMAND_DIR"

case "$APPLICATIONS_DIR/" in
  "$HERMES_HOME/"*) fail "--applications-dir 不能位于 --hermes-home 内。" ;;
esac
case "$HERMES_HOME/" in
  "$APPLICATIONS_DIR/"*) fail "--hermes-home 不能位于 --applications-dir 内。" ;;
esac
case "$COMMAND_DIR/" in
  "$HERMES_HOME/"*) fail "命令目录不能位于 --hermes-home 内。" ;;
  "$APPLICATIONS_DIR/"*) fail "命令目录不能位于 --applications-dir 内。" ;;
esac
case "$HERMES_HOME/" in
  "$COMMAND_DIR/"*) fail "--hermes-home 不能位于命令目录内。" ;;
esac
case "$APPLICATIONS_DIR/" in
  "$COMMAND_DIR/"*) fail "--applications-dir 不能位于命令目录内。" ;;
esac
case "$SCRIPT_DIR/" in
  "$HERMES_HOME/"*|"$APPLICATIONS_DIR/"*|"$COMMAND_DIR/"*) fail "离线包目录不能位于安装目标内：$SCRIPT_DIR" ;;
esac
case "$HERMES_HOME/" in
  "$SCRIPT_DIR/"*) fail "--hermes-home 不能位于离线包目录内。" ;;
esac
case "$APPLICATIONS_DIR/" in
  "$SCRIPT_DIR/"*) fail "--applications-dir 不能位于离线包目录内。" ;;
esac
case "$COMMAND_DIR/" in
  "$SCRIPT_DIR/"*) fail "命令目录不能位于离线包目录内。" ;;
esac

INSTALL_DIR="$HERMES_HOME/hermes-agent"
BOOTSTRAP_MARKER="$INSTALL_DIR/.hermes-bootstrap-complete"
RUNTIME_DIR="$HERMES_HOME/runtime"
NODE_DIR="$HERMES_HOME/node"
BIN_DIR="$HERMES_HOME/bin"
APP_PATH="$APPLICATIONS_DIR/Hermes.app"
validate_user_path "Hermes.app" "$APP_PATH"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)-$$"
BACKUP_ROOT="$HERMES_HOME/offline-backups/$TIMESTAMP"
REPORT="$HERMES_HOME/offline-install-report.txt"
validate_user_path "Hermes 源码目录" "$INSTALL_DIR"
validate_user_path "Python runtime 目录" "$RUNTIME_DIR"
validate_user_path "Node 目录" "$NODE_DIR"
validate_user_path "Hermes bin 目录" "$BIN_DIR"
validate_user_path "备份目录" "$BACKUP_ROOT"
validate_user_path "安装报告" "$REPORT"
validate_user_path "Desktop bootstrap marker" "$BOOTSTRAP_MARKER"
mkdir -p "$HERMES_HOME" "$BACKUP_ROOT" "$APPLICATIONS_DIR" "$BIN_DIR"

restore_path() {
  backup_path_value="$1"
  destination="$2"
  if [ -e "$backup_path_value" ] || [ -L "$backup_path_value" ]; then
    mkdir -p "$(dirname "$destination")"
    mv "$backup_path_value" "$destination"
  fi
}

rollback() {
  status=$?
  trap - EXIT INT TERM
  set +e
  if [ "$status" -ne 0 ] && [ "$ROLLBACK_NEEDED" = true ]; then
    ROLLBACK_NEEDED=false
    printf '✗ 安装中断，正在恢复旧代码和运行时...\n' >&2
    if [ "$INSTALLATION_STARTED" = true ]; then
      rm -rf "$INSTALL_DIR" "$RUNTIME_DIR" "$NODE_DIR" "$APP_PATH"
      rm -rf "$BIN_DIR/uv" "$BIN_DIR/uvx" "$BIN_DIR/rg" "$BIN_DIR/hermes" \
        "$BIN_DIR/node" "$BIN_DIR/npm" "$BIN_DIR/npx"
      rm -rf "$COMMAND_DIR/hermes" "$COMMAND_DIR/node" \
        "$COMMAND_DIR/npm" "$COMMAND_DIR/npx" "$COMMAND_DIR/rg"
      rm -f "$REPORT"
    fi
    restore_path "$BACKUP_ROOT/hermes-agent" "$INSTALL_DIR"
    restore_path "$BACKUP_ROOT/runtime" "$RUNTIME_DIR"
    restore_path "$BACKUP_ROOT/node" "$NODE_DIR"
    restore_path "$BACKUP_ROOT/Hermes.app" "$APP_PATH"
    restore_path "$BACKUP_ROOT/bin/uv" "$BIN_DIR/uv"
    restore_path "$BACKUP_ROOT/bin/uvx" "$BIN_DIR/uvx"
    restore_path "$BACKUP_ROOT/bin/rg" "$BIN_DIR/rg"
    restore_path "$BACKUP_ROOT/bin/hermes" "$BIN_DIR/hermes"
    restore_path "$BACKUP_ROOT/bin/node" "$BIN_DIR/node"
    restore_path "$BACKUP_ROOT/bin/npm" "$BIN_DIR/npm"
    restore_path "$BACKUP_ROOT/bin/npx" "$BIN_DIR/npx"
    restore_path "$BACKUP_ROOT/local-bin/hermes" "$COMMAND_DIR/hermes"
    restore_path "$BACKUP_ROOT/local-bin/node" "$COMMAND_DIR/node"
    restore_path "$BACKUP_ROOT/local-bin/npm" "$COMMAND_DIR/npm"
    restore_path "$BACKUP_ROOT/local-bin/npx" "$COMMAND_DIR/npx"
    restore_path "$BACKUP_ROOT/local-bin/rg" "$COMMAND_DIR/rg"
    restore_path "$BACKUP_ROOT/install-report" "$REPORT"
  fi
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

backup_path() {
  source_path="$1"
  backup_name="$2"
  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    info "备份现有项目：$source_path"
    mkdir -p "$(dirname "$BACKUP_ROOT/$backup_name")"
    mv "$source_path" "$BACKUP_ROOT/$backup_name"
  fi
}

ROLLBACK_NEEDED=true
backup_path "$INSTALL_DIR" hermes-agent
backup_path "$RUNTIME_DIR" runtime
backup_path "$NODE_DIR" node
backup_path "$APP_PATH" Hermes.app
backup_path "$BIN_DIR/uv" bin/uv
backup_path "$BIN_DIR/uvx" bin/uvx
backup_path "$BIN_DIR/rg" bin/rg
backup_path "$BIN_DIR/hermes" bin/hermes
backup_path "$BIN_DIR/node" bin/node
backup_path "$BIN_DIR/npm" bin/npm
backup_path "$BIN_DIR/npx" bin/npx
backup_path "$COMMAND_DIR/hermes" local-bin/hermes
backup_path "$COMMAND_DIR/node" local-bin/node
backup_path "$COMMAND_DIR/npm" local-bin/npm
backup_path "$COMMAND_DIR/npx" local-bin/npx
backup_path "$COMMAND_DIR/rg" local-bin/rg
backup_path "$REPORT" install-report
INSTALLATION_STARTED=true

info "安装 Hermes Agent 源码和运行时..."
ditto "$PAYLOAD/hermes-agent" "$INSTALL_DIR"
ditto "$PAYLOAD/runtime" "$RUNTIME_DIR"
ditto "$PAYLOAD/node" "$NODE_DIR"
install -m 0755 "$PAYLOAD/bin/uv" "$BIN_DIR/uv"
install -m 0755 "$PAYLOAD/bin/uvx" "$BIN_DIR/uvx"
install -m 0755 "$PAYLOAD/bin/rg" "$BIN_DIR/rg"

PYTHON="$(find "$RUNTIME_DIR/python" \( -type f -o -type l \) -path '*/bin/python3.11' | head -1)"
[ -x "$PYTHON" ] || fail "安装后的 Python runtime 不可执行。"

info "在目标路径重新创建 Python venv..."
rm -rf "$INSTALL_DIR/venv"
UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never UV_PYTHON_INSTALL_DIR="$RUNTIME_DIR/python" \
  UV_PYTHON_PREFERENCE=only-managed "$BIN_DIR/uv" venv "$INSTALL_DIR/venv" \
  --python "$PYTHON" --no-project --offline
VENV_PYTHON="$INSTALL_DIR/venv/bin/python"
SITE_PACKAGES="$("$VENV_PYTHON" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
ditto "$PAYLOAD/site-packages" "$SITE_PACKAGES"
printf '%s\n' "$INSTALL_DIR" > "$SITE_PACKAGES/hermes_offline_source.pth"

cat > "$INSTALL_DIR/venv/bin/hermes" <<'EOF'
#!/bin/sh
BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$BIN_DIR/python" -m hermes_cli.main "$@"
EOF
chmod 0755 "$INSTALL_DIR/venv/bin/hermes"

COMMIT="$("$BUNDLE_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["hermesCommit"])' "$MANIFEST")"
BRANCH="$("$BUNDLE_PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["hermesRef"])' "$MANIFEST")"
cat > "$BOOTSTRAP_MARKER" <<EOF
{
  "schemaVersion": 1,
  "pinnedCommit": "$COMMIT",
  "pinnedBranch": "$BRANCH",
  "completedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "desktopVersion": "offline"
}
EOF
printf 'git\n' > "$INSTALL_DIR/.install_method"
if [ -d "$INSTALL_DIR/.git/info" ]; then
  {
    printf '\n# Hermes offline installer runtime markers\n'
    printf '.hermes-bootstrap-complete\n.install_method\n'
  } >> "$INSTALL_DIR/.git/info/exclude"
fi

info "安装 Hermes Desktop 到 $APP_PATH..."
ditto "$PAYLOAD/desktop/Hermes.app" "$APP_PATH"

info "执行安装后自检..."
HERMES_HOME="$HERMES_HOME" PYTHONPATH="$INSTALL_DIR" "$INSTALL_DIR/venv/bin/hermes" --version
"$VENV_PYTHON" -c 'import acp, aiohttp, fastapi, google_auth_httplib2, google_auth_oauthlib, googleapiclient.discovery, hermes_cli, mcp, openai, pydantic, simple_term_menu, uvicorn, yaml, youtube_transcript_api; print("python-imports: OK")'
"$NODE_DIR/bin/node" --version
"$BIN_DIR/rg" --version | head -1
codesign --verify --deep --strict "$APP_PATH"

# Switch user-visible command links only after the isolated runtime passes.
ln -sfn "$INSTALL_DIR/venv/bin/hermes" "$BIN_DIR/hermes"
ln -sfn "$NODE_DIR/bin/node" "$BIN_DIR/node"
ln -sfn "$NODE_DIR/bin/npm" "$BIN_DIR/npm"
ln -sfn "$NODE_DIR/bin/npx" "$BIN_DIR/npx"
mkdir -p "$COMMAND_DIR"
ln -sfn "$INSTALL_DIR/venv/bin/hermes" "$COMMAND_DIR/hermes"
ln -sfn "$NODE_DIR/bin/node" "$COMMAND_DIR/node"
ln -sfn "$NODE_DIR/bin/npm" "$COMMAND_DIR/npm"
ln -sfn "$NODE_DIR/bin/npx" "$COMMAND_DIR/npx"
ln -sfn "$BIN_DIR/rg" "$COMMAND_DIR/rg"

{
  printf 'Hermes macOS offline install: OK\n'
  printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'arch=%s\n' "$EXPECTED_ARCH"
  printf 'hermes_home=%s\n' "$HERMES_HOME"
  printf 'applications_dir=%s\n' "$APPLICATIONS_DIR"
  printf 'commit=%s\n' "$COMMIT"
  printf 'backup=%s\n' "$BACKUP_ROOT"
} > "$REPORT"

ROLLBACK_NEEDED=false
trap - EXIT INT TERM

if [ -d "$PAYLOAD/home-seed/skills" ]; then
  info "安装包内预置 bundled skills（保留已有用户 skills）..."
  if mkdir -p "$HERMES_HOME/skills"; then
    for skill_source in "$PAYLOAD/home-seed/skills"/*; do
      [ -e "$skill_source" ] || continue
      skill_name="$(basename "$skill_source")"
      if [ ! -e "$HERMES_HOME/skills/$skill_name" ] && \
         ! ditto "$skill_source" "$HERMES_HOME/skills/$skill_name"; then
        printf '⚠ 无法预置 skill：%s\n' "$skill_name" >&2
      fi
    done
    if [ -f "$PAYLOAD/home-seed/skills/.bundled_manifest" ] && \
       [ ! -e "$HERMES_HOME/skills/.bundled_manifest" ] && \
       ! cp "$PAYLOAD/home-seed/skills/.bundled_manifest" "$HERMES_HOME/skills/.bundled_manifest"; then
      printf '⚠ 无法写入 bundled skills manifest。\n' >&2
    fi
  else
    printf '⚠ 无法创建 skills 目录：%s\n' "$HERMES_HOME/skills" >&2
  fi
fi

if [ "$MODIFY_PATH" = true ]; then
  # Intentionally write a literal expression for future interactive shells.
  # shellcheck disable=SC2016
  PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
  for profile in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    if [ -L "$profile" ]; then
      printf '⚠ 跳过符号链接 shell profile：%s\n' "$profile" >&2
      continue
    fi
    if ! touch "$profile" || ! grep -Fq "$PATH_LINE" "$profile"; then
      if ! printf '\n# Hermes Agent offline installer\n%s\n' "$PATH_LINE" >> "$profile"; then
        printf '⚠ 无法更新 PATH profile：%s\n' "$profile" >&2
      fi
    fi
  done
fi

ok "Hermes Agent macOS 离线版安装完成"
printf '安装报告：%s\n' "$REPORT"
printf '命令行入口：%s\n' "$COMMAND_DIR/hermes"
printf '桌面应用：%s\n' "$APP_PATH"

if [ "$LAUNCH_APP" = true ]; then
  open "$APP_PATH" || true
fi
