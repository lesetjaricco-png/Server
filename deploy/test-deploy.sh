#!/usr/bin/env bash
# Exercise deploy.sh with a fake docker. Does not contact a registry.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

if ! python3 -c 'import json' >/dev/null 2>&1; then
  PY_EXE=""
  for candidate in /c/Users/*/AppData/Local/Programs/Python/Python3*/python.exe; do
    if [[ -x "$candidate" ]] && "$candidate" -c 'import json' >/dev/null 2>&1; then
      PY_EXE=$candidate
      break
    fi
  done
  if [[ -z "$PY_EXE" ]]; then
    echo "python3 is required to run these tests" >&2
    exit 1
  fi
  PY_BIN=$(mktemp -d)
  cat > "$PY_BIN/python3" <<EOF
#!/usr/bin/env bash
exec "$PY_EXE" "\$@"
EOF
  chmod +x "$PY_BIN/python3"
  export PATH="$PY_BIN:$PATH"
fi

IMAGE=ghcr.io/example/server
DIGEST_A=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST_B=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DIGEST_C=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
DIGEST_D=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
DIGEST_E=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
DIGEST_U=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
PASS=0
FAIL=0

say() { printf '%s\n' "$*"; }

pass() { PASS=$((PASS + 1)); say "PASS $*"; }
die_test() { FAIL=$((FAIL + 1)); say "FAIL $*"; }

bash -n "$ROOT/deploy/deploy.sh"
bash -n "$ROOT/deploy/setup-ubuntu.sh"
pass "shell syntax"

python3 - <<PY
import pathlib, sys
root = pathlib.Path(r"$ROOT") / "deploy"
service = (root / "lichess-guard-deploy.service").read_text(encoding="utf-8")
timer = (root / "lichess-guard-deploy.timer").read_text(encoding="utf-8")
problems = []
if "Type=oneshot" not in service:
    problems.append("service type")
if "/usr/local/sbin/lichess-guard-deploy" not in service:
    problems.append("exec start")
for secret in ("AUTH_SHARED", "LICHESS_TOKEN", "ghp_", "github_pat"):
    if secret in service or secret in timer:
        problems.append("secret in unit: " + secret)
if "Persistent=false" not in timer:
    problems.append("persistent")
if "OnBootSec" in timer or "OnBootSec" in service:
    problems.append("boot trigger")
if "[Install]" in service:
    problems.append("service would start from boot target")
if problems:
    sys.exit("unit check failed: " + ", ".join(problems))
PY
pass "systemd unit constraints"

new_work() {
  WORK=$(mktemp -d)
  MOCK=$WORK/mock
  mkdir -p "$MOCK/bin"
  export MOCK
  export DEPLOY_ENV=$WORK/deploy.env
  export STATE_FILE=$WORK/state.json
  export APP_ENV_FILE=$WORK/app.env
  export DOCKER_BIN=$MOCK/bin/docker
  export PATH="$MOCK/bin:$PATH"
  cat > "$APP_ENV_FILE" <<'EOF'
AUTH_SHARED=SECRET_CANARY_VALUE
LICHESS_TOKEN=SECRET_CANARY_VALUE
EOF
  printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
  : > "$MOCK/calls.log"
  : > "$MOCK/images"
  cat > "$DOCKER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK/calls.log"
if [[ "${1:-}" == "buildx" ]]; then
  cat "$MOCK/latest"
  exit 0
fi
if [[ "${1:-}" == "pull" ]]; then
  ref=${2:-}
  if [[ -f "$MOCK/fail_pull" ]] && grep -Fxq "$ref" "$MOCK/fail_pull"; then
    echo "mock pull failed" >&2
    exit 1
  fi
  exit 0
fi
if [[ "${1:-}" == "image" ]]; then
  sub=${2:-}
  if [[ "$sub" == "inspect" ]]; then
    printf '%s@%s\n' "$IMAGE_NAME_MOCK" "$(cat "$MOCK/latest")"
    exit 0
  fi
  if [[ "$sub" == "ls" ]]; then
    cat "$MOCK/images"
    exit 0
  fi
  if [[ "$sub" == "rm" ]]; then
    ref=${3:-}
    digest=${ref##*@}
    grep -Fv "$digest" "$MOCK/images" > "$MOCK/images.tmp" || true
    mv "$MOCK/images.tmp" "$MOCK/images"
    exit 0
  fi
  echo "unexpected image command" >&2
  exit 1
fi
if [[ "${1:-}" == "rm" ]]; then
  rm -f "$MOCK/container_name" "$MOCK/container_running" "$MOCK/container_digest"
  exit 0
fi
if [[ "${1:-}" == "inspect" ]]; then
  if [[ ! -f "$MOCK/container_name" ]]; then
    exit 1
  fi
  if [[ "${2:-}" == "-f" ]]; then
    fmt=${3:-}
    if [[ "$fmt" == *Running* ]]; then
      cat "$MOCK/container_running"
      exit 0
    fi
    cat "$MOCK/container_digest"
    exit 0
  fi
  echo "{}"
  exit 0
fi
if [[ "${1:-}" == "run" ]]; then
  image=${*: -1}
  digest=${image##*@}
  if [[ -f "$MOCK/fail_start" ]] && grep -Fxq "$digest" "$MOCK/fail_start"; then
    echo "mock start failed" >&2
    exit 1
  fi
  printf '%s\n' "lichess-guard" > "$MOCK/container_name"
  printf '%s\n' "true" > "$MOCK/container_running"
  printf '%s\n' "$digest" > "$MOCK/container_digest"
  exit 0
fi
echo "unexpected docker command: $*" >&2
exit 1
EOF
  chmod +x "$DOCKER_BIN"
  # The mock reads IMAGE_NAME_MOCK from the environment of the test, not deploy.sh.
  export IMAGE_NAME_MOCK=$IMAGE
}

write_env() {
  local decision=${1:-00:00} window=${2:-1440} wait=${3:-5}
  cat > "$DEPLOY_ENV" <<EOF
DECISION_TIME=${decision}
WINDOW_MINUTES=${window}
TIMEZONE=UTC
IMAGE_NAME=${IMAGE}
CONTAINER_NAME=lichess-guard
HOST_PORT=8080
CONTAINER_PORT=8080
HEALTH_URL=${HEALTH_URL}
STARTUP_WAIT=${wait}
EOF
}

start_health() {
  HEALTH_PORT=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  HEALTH_URL="http://127.0.0.1:${HEALTH_PORT}/health"
  python3 - "$HEALTH_PORT" "$MOCK" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
port = int(sys.argv[1])
mock = Path(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        digest = (mock / "container_digest").read_text(encoding="utf-8").strip() if (mock / "container_digest").exists() else ""
        bad = (mock / "fail_health").read_text(encoding="utf-8").split() if (mock / "fail_health").exists() else []
        body = json.dumps({"ok": digest not in bad and digest != "", "ready": None}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
  HEALTH_PID=$!
}

stop_health() {
  if [[ -n "${HEALTH_PID:-}" ]]; then
    kill "$HEALTH_PID" >/dev/null 2>&1 || true
    wait "$HEALTH_PID" 2>/dev/null || true
    HEALTH_PID=
  fi
}

seed_container() {
  local digest=$1
  printf '%s\n' "lichess-guard" > "$MOCK/container_name"
  printf '%s\n' "true" > "$MOCK/container_running"
  printf '%s\n' "$digest" > "$MOCK/container_digest"
}

write_state() {
  python3 - "$STATE_FILE" <<PY
import json, sys
json.dump({
  "current_digest": "$1",
  "previous_digest": "$2",
  "deployment_target_digest": "$3",
  "window_id": "$4",
  "deployment_time": "",
  "deployment_result": "$5",
  "rollback_result": "",
  "last_error": "",
}, open(sys.argv[1], "w"), indent=2)
PY
}

today_window() {
  printf '%sT00:00' "$(TZ=UTC date +%Y-%m-%d)"
}

run_deploy() {
  set +e
  bash "$ROOT/deploy/deploy.sh" "$@" >"$WORK/deploy.log" 2>&1
  RUN_CODE=$?
  set -e
}

state_field() {
  python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data.get(sys.argv[2], ""))
PY
}

assert_eq() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    pass "$name"
  else
    die_test "$name expected [$expected] got [$actual]"
    say "----- log -----"
    cat "$WORK/deploy.log" || true
  fi
}

assert_no_canary() {
  if grep -q SECRET_CANARY_VALUE "$WORK/deploy.log"; then
    die_test "$1 logged app.env contents"
  else
    pass "$1 does not log secrets"
  fi
}

cleanup_case() {
  stop_health
  rm -rf "$WORK"
}

outside_decision() {
  local hour
  hour=$(TZ=UTC date +%H)
  printf '%02d:00' $(( (10#$hour + 3) % 24 ))
}

say "running deployment script tests"
new_work
start_health
write_env
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "$(today_window)" ""
printf '%s\n' "$DIGEST_A" > "$MOCK/latest"
printf '%s %s ida\n' "$IMAGE" "$DIGEST_A" >> "$MOCK/images"
run_deploy
assert_eq "same digest does not replace the container" "0" "$RUN_CODE"
assert_eq "same digest result" "no-change" "$(state_field deployment_result)"
if grep -q '^run ' "$MOCK/calls.log"; then
  die_test "same digest invoked docker run"
else
  pass "same digest does not run a container"
fi
assert_no_canary "same digest"
cleanup_case

new_work
start_health
write_env
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "" ""
printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
printf '%s %s idb\n%s %s idc\n%s %s idd\n%s %s ide\n%s %s ida\n%s %s unused\n' \
  "$IMAGE" "$DIGEST_B" "$IMAGE" "$DIGEST_C" "$IMAGE" "$DIGEST_D" "$IMAGE" "$DIGEST_E" "$IMAGE" "$DIGEST_A" "$IMAGE" "$DIGEST_U" \
  > "$MOCK/images"
run_deploy
assert_eq "snapshot deploys latest digest" "0" "$RUN_CODE"
assert_eq "current digest is the snapshot" "$DIGEST_E" "$(state_field current_digest)"
assert_eq "previous digest is the old release" "$DIGEST_A" "$(state_field previous_digest)"
runs=$(grep -c '^run ' "$MOCK/calls.log" || true)
assert_eq "only the snapshot image is started" "1" "$runs"
if grep '^run ' "$MOCK/calls.log" | grep -q "$DIGEST_E" && ! grep '^run ' "$MOCK/calls.log" | grep -Eq "$DIGEST_B|$DIGEST_C|$DIGEST_D"; then
  pass "intermediate images are not started"
else
  die_test "intermediate images were started"
fi
if grep -q "$DIGEST_A" "$MOCK/images" && grep -q "$DIGEST_E" "$MOCK/images" && ! grep -q "$DIGEST_U" "$MOCK/images"; then
  pass "cleanup keeps current and previous images"
else
  die_test "cleanup removed a protected image or kept an unused one"
  cat "$MOCK/images" || true
fi
assert_no_canary "successful deploy"
# latest moves after the snapshot
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
: > "$MOCK/calls.log"
run_deploy
assert_eq "later publish in the same window is ignored" "0" "$RUN_CODE"
assert_eq "frozen result stays success" "success" "$(state_field deployment_result)"
assert_eq "current digest stays the snapshot" "$DIGEST_E" "$(state_field current_digest)"
if grep -q 'buildx ' "$MOCK/calls.log"; then
  die_test "latest was resolved again inside the window"
else
  pass "latest is not resolved again inside the window"
fi
if [[ ! -f "$STATE_FILE.tmp" ]]; then
  pass "state write leaves no temporary file"
else
  die_test "state temporary file was left behind"
fi
python3 - "$STATE_FILE" <<'PY'
import json, sys
json.load(open(sys.argv[1], encoding="utf-8"))
PY
pass "state file remains valid json"
cleanup_case

new_work
start_health
write_env
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "" ""
printf '%s\n' "${IMAGE}@${DIGEST_B}" > "$MOCK/fail_pull"
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
run_deploy
assert_eq "pull failure exits non-zero" "1" "$RUN_CODE"
assert_eq "pull failure result" "pull-failed" "$(state_field deployment_result)"
assert_eq "pull failure keeps the current digest" "$DIGEST_A" "$(state_field current_digest)"
assert_eq "running container is still the old digest" "$DIGEST_A" "$(cat "$MOCK/container_digest")"
if grep -q '^rm ' "$MOCK/calls.log" || grep -q '^run ' "$MOCK/calls.log"; then
  die_test "pull failure stopped or replaced the container"
else
  pass "pull failure leaves the container in place"
fi
cleanup_case

new_work
start_health
write_env 00:00 1440 2
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "" ""
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
printf '%s\n' "$DIGEST_B" > "$MOCK/fail_start"
run_deploy
assert_eq "startup failure exits non-zero" "1" "$RUN_CODE"
assert_eq "startup failure rolls back" "rolled-back" "$(state_field deployment_result)"
assert_eq "startup rollback restores the previous digest" "$DIGEST_A" "$(state_field current_digest)"
assert_eq "startup rollback container digest" "$DIGEST_A" "$(cat "$MOCK/container_digest")"
assert_eq "startup rollback flag" "success" "$(state_field rollback_result)"
cleanup_case

new_work
start_health
write_env 00:00 1440 2
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "" ""
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
printf '%s\n' "$DIGEST_B" > "$MOCK/fail_health"
run_deploy
assert_eq "health failure exits non-zero" "1" "$RUN_CODE"
assert_eq "health failure rolls back" "rolled-back" "$(state_field deployment_result)"
assert_eq "health rollback restores the exact previous digest" "$DIGEST_A" "$(state_field current_digest)"
assert_eq "health rollback container" "$DIGEST_A" "$(cat "$MOCK/container_digest")"
if grep '^run ' "$MOCK/calls.log" | grep -Eq "$DIGEST_C|$DIGEST_D|$DIGEST_E"; then
  die_test "rollback tried an intermediate image"
else
  pass "rollback does not try intermediate images"
fi
cleanup_case

new_work
start_health
write_env 00:00 1440 2
seed_container "$DIGEST_A"
write_state "$DIGEST_A" "" "" "" ""
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
printf '%s\n' "$DIGEST_B" > "$MOCK/fail_start"
printf '%s\n' "${IMAGE}@${DIGEST_A}" > "$MOCK/fail_pull"
run_deploy
assert_eq "rollback failure exits non-zero" "1" "$RUN_CODE"
assert_eq "rollback failure result" "rollback-failed" "$(state_field deployment_result)"
assert_eq "rollback failure flag" "failed" "$(state_field rollback_result)"
if [[ -n "$(state_field last_error)" ]]; then
  pass "rollback failure records last_error"
else
  die_test "rollback failure left last_error empty"
fi
if grep '^run ' "$MOCK/calls.log" | grep -Eq "$DIGEST_C|$DIGEST_D|$DIGEST_E"; then
  die_test "rollback failure tried another published image"
else
  pass "rollback failure does not try another image"
fi
cleanup_case

new_work
start_health
write_env 00:00 1440 2
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
printf '%s\n' "$DIGEST_B" > "$MOCK/fail_health"
run_deploy
assert_eq "failed first deployment exits non-zero" "1" "$RUN_CODE"
assert_eq "failed first deployment result" "first-deploy-failed" "$(state_field deployment_result)"
assert_eq "failed first deployment has no current digest" "" "$(state_field current_digest)"
if [[ -f "$MOCK/container_name" ]]; then
  die_test "failed first deployment left a container"
else
  pass "failed first deployment removes the container"
fi
cleanup_case

new_work
start_health
write_env
printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
run_deploy
assert_eq "first deployment exits zero" "0" "$RUN_CODE"
assert_eq "first deployment current digest" "$DIGEST_E" "$(state_field current_digest)"
assert_eq "first deployment container digest" "$DIGEST_E" "$(cat "$MOCK/container_digest")"
if grep '^run ' "$MOCK/calls.log" | grep -q "${IMAGE}@${DIGEST_E}" && grep '^run ' "$MOCK/calls.log" | grep -q -- '--restart unless-stopped'; then
  pass "container is pinned to the digest with unless-stopped"
else
  die_test "container was not pinned with unless-stopped"
  cat "$MOCK/calls.log"
fi
if grep '^run ' "$MOCK/calls.log" | grep -q ':latest'; then
  die_test "container was started from :latest"
else
  pass "container is not started from :latest"
fi
cleanup_case

new_work
start_health
decision=$(outside_decision)
write_env "$decision" 7
printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
printf '%s\n' '{"current_digest":"sha256:unchanged"}' > "$STATE_FILE"
before=$(cat "$STATE_FILE")
run_deploy
assert_eq "missed window exits zero" "0" "$RUN_CODE"
assert_eq "missed window does not change state" "$before" "$(cat "$STATE_FILE")"
if [[ -s "$MOCK/calls.log" ]]; then
  die_test "missed window contacted docker"
else
  pass "missed window does not pull or deploy"
fi
cleanup_case

new_work
start_health
write_env
printf '%s\n' "$DIGEST_B" > "$MOCK/latest"
write_state "$DIGEST_A" "$DIGEST_A" "$DIGEST_E" "$(today_window)" "in-progress"
seed_container "$DIGEST_A"
run_deploy
assert_eq "interrupted deployment continues" "0" "$RUN_CODE"
assert_eq "interrupted deployment uses the frozen digest" "$DIGEST_E" "$(state_field current_digest)"
if grep -q 'buildx ' "$MOCK/calls.log"; then
  die_test "interrupted deployment resolved latest again"
else
  pass "interrupted deployment does not resolve latest again"
fi
if grep '^run ' "$MOCK/calls.log" | grep -q "$DIGEST_E" && ! grep '^run ' "$MOCK/calls.log" | grep -q "$DIGEST_B"; then
  pass "interrupted deployment does not chase the new latest"
else
  die_test "interrupted deployment chased latest"
fi
cleanup_case

new_work
start_health
write_env "$(outside_decision)" 7 5
write_state "$DIGEST_B" "$DIGEST_A" "$DIGEST_B" "$(today_window)" "success"
run_deploy --rollback
assert_eq "manual rollback exits zero" "0" "$RUN_CODE"
assert_eq "manual rollback current digest" "$DIGEST_A" "$(state_field current_digest)"
assert_eq "manual rollback container" "$DIGEST_A" "$(cat "$MOCK/container_digest")"
if grep -q 'buildx ' "$MOCK/calls.log"; then
  die_test "manual rollback resolved latest"
else
  pass "manual rollback does not resolve latest"
fi
cleanup_case

new_work
start_health
write_env
printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
if command -v flock >/dev/null 2>&1; then
  flock -n "$WORK/deploy.lock" -c "sleep 20" &
  LOCK_PID=$!
  LOCK_HELD=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! flock -n "$WORK/deploy.lock" -c "true"; then
      LOCK_HELD=1
      break
    fi
    sleep 0.1
  done
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    run_deploy
    assert_eq "second deployment exits while the lock is held" "0" "$RUN_CODE"
    if grep -q 'step=lock result=busy' "$WORK/deploy.log"; then
      pass "second deployment does not run beside the first"
    else
      die_test "second deployment did not report a busy lock"
    fi
  else
    die_test "could not hold the deployment lock"
  fi
  kill "$LOCK_PID" >/dev/null 2>&1 || true
  wait "$LOCK_PID" 2>/dev/null || true
else
  mkdir "$WORK/deploy.lock.d"
  run_deploy
  assert_eq "second deployment exits while the lock is held" "0" "$RUN_CODE"
  if grep -q 'step=lock result=busy' "$WORK/deploy.log"; then
    pass "second deployment does not run beside the first"
  else
    die_test "second deployment did not report a busy lock"
  fi
fi
if [[ -s "$MOCK/calls.log" ]]; then
  die_test "locked deployment contacted docker"
else
  pass "locked deployment does not change the container"
fi
cleanup_case

new_work
start_health
write_env
printf '%s\n' "$DIGEST_E" > "$MOCK/latest"
cat > "$MOCK/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$MOCK/bin/flock"
run_deploy
assert_eq "flock refusal exits zero" "0" "$RUN_CODE"
if grep -q 'step=lock result=busy' "$WORK/deploy.log" && [[ ! -s "$MOCK/calls.log" ]]; then
  pass "flock refusal does not deploy"
else
  die_test "flock refusal still deployed"
  cat "$WORK/deploy.log" || true
fi
cleanup_case

# setup twice preserves configuration
SETUP=$WORK
# previous cleanup removed WORK. Make a fresh prefix.
SETUP=$(mktemp -d)
cat > "$SETUP/pre-app.env" <<'EOF'
AUTH_SHARED=SECRET_CANARY_VALUE
LICHESS_TOKEN=keep-me
EOF
mkdir -p "$SETUP/etc/lichess-guard" "$SETUP/var/lib/lichess-guard"
cp "$SETUP/pre-app.env" "$SETUP/etc/lichess-guard/app.env"
cat > "$SETUP/etc/lichess-guard/deploy.env" <<'EOF'
DECISION_TIME=03:30
WINDOW_MINUTES=7
TIMEZONE=UTC
IMAGE_NAME=ghcr.io/example/server
CONTAINER_NAME=lichess-guard
HOST_PORT=8080
CONTAINER_PORT=8080
HEALTH_URL=
STARTUP_WAIT=30
EOF
printf '%s\n' '{"current_digest":"sha256:keep"}' > "$SETUP/var/lib/lichess-guard/state.json"
LICHESS_GUARD_ROOT="$SETUP" bash "$ROOT/deploy/setup-ubuntu.sh" >"$SETUP/setup1.log"
LICHESS_GUARD_ROOT="$SETUP" bash "$ROOT/deploy/setup-ubuntu.sh" >"$SETUP/setup2.log"
if grep -q SECRET_CANARY_VALUE "$SETUP/etc/lichess-guard/app.env" && grep -q 'keep-me' "$SETUP/etc/lichess-guard/app.env"; then
  pass "setup preserves app.env"
else
  die_test "setup changed app.env"
fi
if grep -q 'DECISION_TIME=03:30' "$SETUP/etc/lichess-guard/deploy.env"; then
  pass "setup preserves deploy.env"
else
  die_test "setup changed deploy.env"
fi
if grep -q 'sha256:keep' "$SETUP/var/lib/lichess-guard/state.json"; then
  pass "setup preserves state.json"
else
  die_test "setup changed state.json"
fi
if grep -q 'OnCalendar=\*-\*-\* 03:30:00' "$SETUP/etc/systemd/system/lichess-guard-deploy.timer"; then
  pass "setup writes the decision time into the timer"
else
  die_test "timer OnCalendar was not updated"
  cat "$SETUP/etc/systemd/system/lichess-guard-deploy.timer" || true
fi
if grep -q 'systemctl enable' "$SETUP/setup1.log" && ! grep -q 'enable --now' "$ROOT/deploy/setup-ubuntu.sh"; then
  die_test "setup enables the timer"
else
  if grep -q 'systemctl enable --now lichess-guard-deploy.timer' "$SETUP/setup1.log"; then
    pass "setup prints the activation command and does not run it"
  else
    die_test "setup did not document activation"
  fi
fi
if [[ -x "$SETUP/usr/local/sbin/lichess-guard-deploy" ]]; then
  pass "setup installs the deployment script"
else
  die_test "deployment script was not installed"
fi
rm -rf "$SETUP"

say "passed=$PASS failed=$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
