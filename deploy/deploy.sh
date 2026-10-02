#!/usr/bin/env bash
# Resolve ghcr.io/...:latest once per window, then run that immutable digest.
# A reboot does not run this script. Docker restarts the pinned container.
set -euo pipefail

DEPLOY_ENV=${DEPLOY_ENV:-/etc/lichess-guard/deploy.env}
STATE_FILE=${STATE_FILE:-/var/lib/lichess-guard/state.json}
APP_ENV_FILE=${APP_ENV_FILE:-/etc/lichess-guard/app.env}
DOCKER_BIN=${DOCKER_BIN:-docker}

DECISION_TIME=00:00
WINDOW_MINUTES=7
TIMEZONE=UTC
IMAGE_NAME=ghcr.io/lesetjaricco-png/server
CONTAINER_NAME=lichess-guard
HOST_PORT=8080
CONTAINER_PORT=8080
HEALTH_URL=
STARTUP_WAIT=30

current_digest=
previous_digest=
deployment_target_digest=
window_id=
deployment_time=
deployment_result=
rollback_result=
last_error=

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

load_deploy_env() {
  [[ -f "$DEPLOY_ENV" ]] || die "missing $DEPLOY_ENV"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "invalid config line in $DEPLOY_ENV"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      DECISION_TIME) DECISION_TIME=$value ;;
      WINDOW_MINUTES) WINDOW_MINUTES=$value ;;
      TIMEZONE) TIMEZONE=$value ;;
      IMAGE_NAME) IMAGE_NAME=$value ;;
      CONTAINER_NAME) CONTAINER_NAME=$value ;;
      HOST_PORT) HOST_PORT=$value ;;
      CONTAINER_PORT) CONTAINER_PORT=$value ;;
      HEALTH_URL) HEALTH_URL=$value ;;
      STARTUP_WAIT) STARTUP_WAIT=$value ;;
    esac
  done < "$DEPLOY_ENV"
  if [[ -z "$HEALTH_URL" ]]; then
    HEALTH_URL="http://127.0.0.1:${HOST_PORT}/health"
  fi
}

validate_config() {
  [[ "$DECISION_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "DECISION_TIME must be HH:MM"
  [[ "$WINDOW_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "WINDOW_MINUTES must be a positive integer"
  [[ "$HOST_PORT" =~ ^[0-9]+$ && "$CONTAINER_PORT" =~ ^[0-9]+$ ]] || die "ports must be integers"
  [[ "$STARTUP_WAIT" =~ ^[1-9][0-9]*$ ]] || die "STARTUP_WAIT must be a positive integer"
  [[ "$IMAGE_NAME" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "IMAGE_NAME contains unsupported characters"
  [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "CONTAINER_NAME is invalid"
  [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "TIMEZONE is invalid"
  local hh mm start_min
  IFS=: read -r hh mm <<< "$DECISION_TIME"
  start_min=$((10#$hh * 60 + 10#$mm))
  if (( start_min + WINDOW_MINUTES > 1440 )); then
    die "deployment window must not cross midnight"
  fi
}

require_commands() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "docker is required ($DOCKER_BIN)"
}

state_load() {
  python3 - "$STATE_FILE" <<'PY'
import json, os, shlex, sys
path = sys.argv[1]
keys = [
    "current_digest", "previous_digest", "deployment_target_digest",
    "window_id", "deployment_time", "deployment_result",
    "rollback_result", "last_error",
]
data = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict):
        data = loaded
for key in keys:
    print(f"{key}={shlex.quote(str(data.get(key) or ''))}")
PY
}

state_write() {
  python3 - "$STATE_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
keys = [
    "current_digest", "previous_digest", "deployment_target_digest",
    "window_id", "deployment_time", "deployment_result",
    "rollback_result", "last_error",
]
data = {key: os.environ.get(key, "") for key in keys}
directory = os.path.dirname(path) or "."
os.makedirs(directory, mode=0o750, exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(tmp, 0o640)
os.replace(tmp, path)
os.chmod(path, 0o640)
PY
}

save_state() {
  current_digest="$current_digest" \
  previous_digest="$previous_digest" \
  deployment_target_digest="$deployment_target_digest" \
  window_id="$window_id" \
  deployment_time="$deployment_time" \
  deployment_result="$deployment_result" \
  rollback_result="$rollback_result" \
  last_error="$last_error" \
  state_write
}

now_stamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

window_bounds() {
  local today decision_epoch
  today=$(TZ="$TIMEZONE" date +%Y-%m-%d)
  window_id="${today}T${DECISION_TIME}"
  decision_epoch=$(TZ="$TIMEZONE" date -d "${today} ${DECISION_TIME}:00" +%s)
  window_start=$decision_epoch
  window_end=$((decision_epoch + WINDOW_MINUTES * 60))
  now_epoch=$(TZ="$TIMEZONE" date +%s)
}

inside_window() {
  (( now_epoch >= window_start && now_epoch < window_end ))
}

terminal_result() {
  case "$deployment_result" in
    no-change|success|pull-failed|rolled-back|rollback-failed|first-deploy-failed|manual-rollback) return 0 ;;
    *) return 1 ;;
  esac
}

container_exists() {
  "$DOCKER_BIN" inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
  local state
  state=$("$DOCKER_BIN" inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)
  [[ "$state" == "true" ]]
}

container_digest() {
  "$DOCKER_BIN" inspect -f '{{index .Config.Labels "lichess-guard.digest"}}' "$CONTAINER_NAME" 2>/dev/null || true
}

remove_container() {
  if container_exists; then
    "$DOCKER_BIN" rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

resolve_latest() {
  local out
  if out=$("$DOCKER_BIN" buildx imagetools inspect --format '{{.Manifest.Digest}}' "${IMAGE_NAME}:latest" 2>/dev/null); then
    out=${out//\"/}
    out=${out//$'\r'/}
    if [[ "$out" == sha256:* ]]; then
      printf '%s' "$out"
      return 0
    fi
  fi
  log "step=resolve fallback=docker-pull-latest image=${IMAGE_NAME}"
  "$DOCKER_BIN" pull "${IMAGE_NAME}:latest" >/dev/null
  out=$("$DOCKER_BIN" image inspect --format '{{index .RepoDigests 0}}' "${IMAGE_NAME}:latest")
  out=${out##*@}
  [[ "$out" == sha256:* ]] || return 1
  printf '%s' "$out"
}

pull_digest() {
  local digest=$1
  log "step=pull digest=${digest}"
  "$DOCKER_BIN" pull "${IMAGE_NAME}@${digest}" >&2
}

start_container() {
  local digest=$1
  log "step=start container=${CONTAINER_NAME} digest=${digest} port=${HOST_PORT}:${CONTAINER_PORT}"
  "$DOCKER_BIN" run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --label "lichess-guard.digest=${digest}" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    --env-file "$APP_ENV_FILE" \
    -e HOST=0.0.0.0 \
    -e "PORT=${CONTAINER_PORT}" \
    "${IMAGE_NAME}@${digest}" >/dev/null
}

health_once() {
  python3 - "$HEALTH_URL" <<'PY'
import json, sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=3) as response:
        code = response.status
        body = response.read().decode("utf-8", "replace")
except Exception as exc:
    print(f"health-error {type(exc).__name__}")
    sys.exit(1)
if code != 200:
    print(f"health-status {code}")
    sys.exit(1)
try:
    payload = json.loads(body)
except Exception:
    print("health-not-json")
    sys.exit(1)
if payload.get("ok") is not True:
    print("health-ok-not-true")
    sys.exit(1)
print("health-ok")
PY
}

verify_running() {
  local deadline detail
  deadline=$((SECONDS + STARTUP_WAIT))
  while (( SECONDS < deadline )); do
    if container_running; then
      if detail=$(health_once); then
        log "step=health result=pass url=${HEALTH_URL}"
        return 0
      fi
      log "step=health result=waiting detail=${detail}"
    else
      log "step=startup result=waiting"
    fi
    sleep 1
  done
  if container_running; then
    log "step=health result=fail url=${HEALTH_URL}"
  else
    log "step=startup result=fail container=${CONTAINER_NAME}"
  fi
  return 1
}

cleanup_images() {
  local repo digest id
  while read -r repo digest id; do
    [[ "$repo" == "$IMAGE_NAME" ]] || continue
    [[ "$digest" == sha256:* ]] || continue
    [[ -n "$current_digest" && "$digest" == "$current_digest" ]] && continue
    [[ -n "$previous_digest" && "$digest" == "$previous_digest" ]] && continue
    if container_exists && [[ "$(container_digest)" == "$digest" ]]; then
      continue
    fi
    if "$DOCKER_BIN" image rm "${IMAGE_NAME}@${digest}" >/dev/null 2>&1; then
      log "step=cleanup removed=${digest}"
    else
      log "step=cleanup skipped=${digest}"
    fi
  done < <("$DOCKER_BIN" image ls --digests --format '{{.Repository}} {{.Digest}} {{.ID}}' 2>/dev/null || true)
}

record() {
  local result=$1 error=${2:-}
  deployment_time=$(now_stamp)
  deployment_result=$result
  last_error=$error
  save_state
  log "step=record result=${result} target=${deployment_target_digest} current=${current_digest} previous=${previous_digest} rollback=${rollback_result} window=${window_id}${error:+ error=${error}}"
}

rollback() {
  local reason=$1
  log "step=rollback reason=${reason} previous=${previous_digest}"
  remove_container || true
  if [[ -z "$previous_digest" ]]; then
    rollback_result=not-applicable
    record first-deploy-failed "$reason"
    return 1
  fi
  if ! pull_digest "$previous_digest"; then
    rollback_result=failed
    record rollback-failed "rollback pull failed after: ${reason}"
    return 1
  fi
  if ! start_container "$previous_digest"; then
    rollback_result=failed
    record rollback-failed "rollback start failed after: ${reason}"
    return 1
  fi
  if ! verify_running; then
    rollback_result=failed
    record rollback-failed "rollback health failed after: ${reason}"
    return 1
  fi
  current_digest=$previous_digest
  rollback_result=success
  record rolled-back "$reason"
  return 1
}

deploy_target() {
  local target=$1
  if [[ ! -f "$APP_ENV_FILE" ]]; then
    last_error="missing ${APP_ENV_FILE}"
    log "step=config result=fail error=${last_error}"
    exit 1
  fi
  if [[ -n "$current_digest" && "$target" == "$current_digest" ]]; then
    if container_running && [[ "$(container_digest)" == "$current_digest" ]]; then
      record no-change
      return 0
    fi
    log "step=restore digest=${current_digest}"
    pull_digest "$current_digest" || die "could not pull current digest ${current_digest}"
    remove_container
    start_container "$current_digest" || die "could not start current digest ${current_digest}"
    verify_running || die "current digest failed health after restore"
    record no-change
    return 0
  fi

  if ! pull_digest "$target"; then
    record pull-failed "pull failed for ${target}"
    log "step=pull result=fail digest=${target} action=left-current-container"
    return 1
  fi

  if [[ "$deployment_result" != "in-progress" && -n "$current_digest" ]]; then
    previous_digest=$current_digest
  fi
  deployment_result=in-progress
  rollback_result=
  last_error=
  save_state

  remove_container
  if ! start_container "$target"; then
    rollback "container start failed for ${target}"
    return 1
  fi
  if ! verify_running; then
    rollback "verification failed for ${target}"
    return 1
  fi
  current_digest=$target
  rollback_result=
  record success
  cleanup_images
  return 0
}

manual_rollback() {
  require_commands
  eval "$(state_load)"
  [[ -n "$previous_digest" ]] || die "no previous_digest to restore"
  [[ -f "$APP_ENV_FILE" ]] || die "missing $APP_ENV_FILE"
  log "step=manual-rollback previous=${previous_digest} current=${current_digest}"
  pull_digest "$previous_digest" || die "manual rollback pull failed"
  remove_container
  start_container "$previous_digest" || die "manual rollback start failed"
  verify_running || die "manual rollback health failed"
  current_digest=$previous_digest
  deployment_time=$(now_stamp)
  deployment_result=manual-rollback
  rollback_result=success
  last_error=
  save_state
  log "step=manual-rollback result=success digest=${current_digest}"
}

main() {
  local mode=${1:-} computed_window target saved_window
  if [[ "$mode" == "--rollback" ]]; then
    acquire_lock
    load_deploy_env
    validate_config
    manual_rollback
    exit 0
  fi
  if [[ -n "$mode" ]]; then
    die "unknown argument: $mode"
  fi

  acquire_lock
  load_deploy_env
  validate_config
  window_bounds
  computed_window=$window_id
  if ! inside_window; then
    log "step=window result=outside window=${computed_window} timezone=${TIMEZONE}"
    exit 0
  fi
  require_commands
  eval "$(state_load)"
  saved_window=$window_id
  window_id=$computed_window

  if [[ "$saved_window" == "$computed_window" && -n "$deployment_target_digest" ]]; then
    target=$deployment_target_digest
    log "step=snapshot result=frozen window=${window_id} target=${target} current=${current_digest}"
    if terminal_result; then
      log "step=window result=already-finished result=${deployment_result} target=${target}"
      exit 0
    fi
  else
    if ! target=$(resolve_latest); then
      last_error="could not resolve ${IMAGE_NAME}:latest"
      log "step=snapshot result=fail error=${last_error}"
      exit 1
    fi
    deployment_target_digest=$target
    deployment_result=
    rollback_result=
    last_error=
    deployment_time=$(now_stamp)
    save_state
    log "step=snapshot result=frozen window=${window_id} target=${target} current=${current_digest}"
  fi

  deploy_target "$target"
}

acquire_lock() {
  local dir lock_path
  dir=$(dirname "$STATE_FILE")
  mkdir -p "$dir"
  chmod 0750 "$dir" 2>/dev/null || true
  exec 9>>"${dir}/deploy.lock"
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { log "step=lock result=busy"; exit 0; }
    return 0
  fi
  lock_path="${dir}/deploy.lock.d"
  if ! mkdir "$lock_path" 2>/dev/null; then
    local holder=""
    if [[ -f "$lock_path/pid" ]]; then
      holder=$(cat "$lock_path/pid" 2>/dev/null || true)
    fi
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$lock_path"
      mkdir "$lock_path" 2>/dev/null || { log "step=lock result=busy"; exit 0; }
    else
      log "step=lock result=busy"
      exit 0
    fi
  fi
  printf '%s\n' "$$" > "$lock_path/pid"
  # Expand the path now. A local variable is gone when the EXIT trap runs.
  trap "rm -rf $(printf '%q' "$lock_path") 2>/dev/null || true" EXIT
}

main "$@"
