#!/usr/bin/env bash
# Install the deployment timer, script, and directories.
# Does not log in to GHCR, does not deploy, and does not enable the timer.
set -euo pipefail

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
PREFIX=${LICHESS_GUARD_ROOT:-}

if [[ -z "$PREFIX" && "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root on the Ubuntu server." >&2
  exit 1
fi

ETC="${PREFIX}/etc/lichess-guard"
LIB="${PREFIX}/var/lib/lichess-guard"
SBIN="${PREFIX}/usr/local/sbin"
UNIT_DIR="${PREFIX}/etc/systemd/system"

say() {
  printf '%s\n' "$*"
}

copy_file() {
  local mode=$1 src=$2 dest=$3
  cp "$src" "$dest"
  if [[ -z "$PREFIX" ]]; then
    chmod "$mode" "$dest"
  else
    chmod "$mode" "$dest" 2>/dev/null || true
  fi
}

install_packages() {
  if [[ -n "$PREFIX" ]]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    apt-get update
    apt-get install -y python3
  fi
  if ! command -v docker >/dev/null 2>&1; then
    apt-get update
    apt-get install -y docker.io
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker.service
    systemctl start docker.service
  fi
}

decision_time() {
  local file=$1 line
  line=$(grep -E '^DECISION_TIME=' "$file" | tail -n 1 || true)
  line=${line#DECISION_TIME=}
  line=${line//\"/}
  if [[ ! "$line" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "DECISION_TIME in $file must be HH:MM" >&2
    exit 1
  fi
  printf '%s' "$line"
}

install_packages

mkdir -p "$ETC" "$LIB" "$SBIN" "$UNIT_DIR"
if [[ -z "$PREFIX" ]]; then
  chmod 0750 "$ETC" "$LIB"
else
  chmod 0750 "$ETC" "$LIB" 2>/dev/null || true
fi

copy_file 0755 "$SOURCE_DIR/deploy.sh" "$SBIN/lichess-guard-deploy"

if [[ ! -f "$ETC/deploy.env" ]]; then
  copy_file 0640 "$SOURCE_DIR/deploy.env.example" "$ETC/deploy.env"
  say "created $ETC/deploy.env"
else
  say "kept existing $ETC/deploy.env"
fi

if [[ ! -f "$ETC/app.env" ]]; then
  copy_file 0600 "$SOURCE_DIR/app.env.example" "$ETC/app.env"
  say "created $ETC/app.env from the empty template"
else
  say "kept existing $ETC/app.env"
fi

if [[ ! -f "$LIB/state.json" ]]; then
  printf '%s\n' '{"current_digest":"","previous_digest":"","deployment_target_digest":"","window_id":"","deployment_time":"","deployment_result":"","rollback_result":"","last_error":""}' > "$LIB/state.json"
  chmod 0640 "$LIB/state.json"
  say "created $LIB/state.json"
else
  say "kept existing $LIB/state.json"
fi

when=$(decision_time "$ETC/deploy.env")
copy_file 0644 "$SOURCE_DIR/lichess-guard-deploy.service" "$UNIT_DIR/lichess-guard-deploy.service"
copy_file 0644 "$SOURCE_DIR/lichess-guard-deploy.timer" "$UNIT_DIR/lichess-guard-deploy.timer"
sed -i "s/^OnCalendar=.*/OnCalendar=*-*-* ${when}:00/" "$UNIT_DIR/lichess-guard-deploy.timer"

if [[ -z "$PREFIX" && "$(id -u)" -eq 0 ]]; then
  chown root:root "$ETC/deploy.env" "$ETC/app.env" "$LIB/state.json" "$SBIN/lichess-guard-deploy" \
    "$UNIT_DIR/lichess-guard-deploy.service" "$UNIT_DIR/lichess-guard-deploy.timer" || true
  chmod 0750 "$ETC" "$LIB"
  chmod 0640 "$ETC/deploy.env" "$LIB/state.json"
  chmod 0600 "$ETC/app.env"
fi

if [[ -z "$PREFIX" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

if [[ -z "$PREFIX" ]] && command -v timedatectl >/dev/null 2>&1; then
  zone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  configured=$(grep -E '^TIMEZONE=' "$ETC/deploy.env" | tail -n 1 | cut -d= -f2- | tr -d '"')
  if [[ -n "$zone" && -n "$configured" && "$zone" != "$configured" ]]; then
    say "warning: system timezone is ${zone} and TIMEZONE=${configured}. The timer uses the system timezone."
  fi
fi

say "The deployment timer is installed and not enabled."
say "Log in to GHCR manually before the first deployment:"
say "  docker login ghcr.io"
say "Use a read-only package credential. Do not use PR_AUTOMATION_TOKEN or a publish token."
say "Put application secrets in $ETC/app.env and keep that file unreadable by other users."
say "Activate the timer when the configuration is ready:"
say "  systemctl enable --now lichess-guard-deploy.timer"
