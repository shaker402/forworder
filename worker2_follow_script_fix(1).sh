#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT="/opt/TelegramForwarder-worker2"
SOURCE_ENV="/root/worker2.env"
WORKER1_ENV="/opt/TelegramForwarder-worker1/.env"
LIVE_ENV="$PROJECT/.env"
SERVICE="telegram-forwarder"
CONTAINER="telegram-forwarder-worker2"
WORKER1_CONTAINER="telegram-forwarder-worker1"
BACKUP_ENV=""
ROLLBACK_ARMED="false"
COMPLETED="false"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

finish() {
  local status=$?
  trap - EXIT
  set +e
  if [ "$status" -eq 0 ] && [ "$COMPLETED" != "true" ]; then
    status=97
  fi
  if [ "$status" -ne 0 ] && [ "$ROLLBACK_ARMED" = "true" ] && [ -f "$BACKUP_ENV" ]; then
    warn "Restoring the previous Worker 2 environment."
    cp -a -- "$BACKUP_ENV" "$LIVE_ENV"
    chmod 600 "$LIVE_ENV"
    (cd "$PROJECT" && docker compose up -d --force-recreate "$SERVICE") || true
  fi
  exit "$status"
}
trap finish EXIT

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this script as root."
for command_name in docker python3 grep; do
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

[ -f "$SOURCE_ENV" ] || die "Missing $SOURCE_ENV"
[ -f "$WORKER1_ENV" ] || die "Missing $WORKER1_ENV"
[ -f "$LIVE_ENV" ] || die "Missing $LIVE_ENV"
[ -f "$PROJECT/docker-compose.yml" ] || die "Worker 2 project is incomplete."
[ -f "$PROJECT/ai/gemini_runtime.py" ] || die "Worker 2 V9 queue runtime is missing."
[ -f "$PROJECT/model/shaker_weak_tfidf_triage.joblib" ] || die "Worker 2 V9 shadow model is missing."
grep -q 'PERSISTENT_GEMINI_QUEUE_V9' "$PROJECT/ai/gemini_provider.py" || die "Worker 2 is not the V9 durable build; install the V9 ZIP first."

python3 "$PROJECT/worker_tools/validate_env_structure.py" --env "$SOURCE_ENV" --required-keys 10
python3 "$PROJECT/worker_tools/compare_key_fingerprints.py" --env "$SOURCE_ENV" --other-env "$WORKER1_ENV" --required-keys 10

worker1_started_before="$(
  docker inspect "$WORKER1_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null
)" || die "Worker 1 is not running."

BACKUP_ENV="${LIVE_ENV}.backup-before-v9-enforcement-$(date +%Y%m%d-%H%M%S)"
cp -a -- "$LIVE_ENV" "$BACKUP_ENV"
ROLLBACK_ARMED="true"

python3 - "$SOURCE_ENV" "$LIVE_ENV" <<'PY'
import os
import re
import tempfile
import sys
from pathlib import Path

source = Path(sys.argv[1])
live = Path(sys.argv[2])

def parse_env(path):
    values = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.lstrip().startswith("#") or "=" not in raw:
            continue
        name, value = raw.split("=", 1)
        name = name.strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
            values[name] = value.strip()
    return values

source_values = parse_env(source)
before_values = parse_env(live)
raw_pool = source_values.get("GEMINI_API_KEYS", "")
candidates = []
for chunk in raw_pool.replace(";", ",").replace("\\n", ",").split(","):
    candidates.extend(chunk.split())
keys = list(dict.fromkeys(value for value in candidates if value))
if len(keys) != 10:
    raise SystemExit(
        f"Expected 10 configured and unique Gemini keys in {source}, found {len(keys)}"
    )

updates = {
    "GEMINI_API_KEYS": ",".join(keys),
    "GEMINI_API_KEY": "",
    "GEMINI_API_BASE": "",
    "GEMINI_REST_API_BASE": "https://generativelanguage.googleapis.com/v1beta",
    "GEMINI_REQUIRED_KEY_COUNT": "10",
    "WORKER_NAMESPACE": "worker2",
    "WORKER_INSTANCE": "worker2",
    "WORKER_LABEL": "Telegram Worker 2",
    "GEMINI_MAX_KEY_ATTEMPTS": "1",
    "GEMINI_MAX_PARALLEL_REQUESTS": "3",
    "MAX_CONCURRENT_MESSAGE_HANDLERS": "10",
    "GEMINI_REQUEST_TIMEOUT_SECONDS": "45",
    "GEMINI_PROJECT_TARGET_RPM": "12",
    "GEMINI_PROJECT_MIN_INTERVAL_SECONDS": "5",
    "GEMINI_PROJECT_INFLIGHT_LEASE_SECONDS": "120",
    "GEMINI_QUEUE_PATH": "/app/db/gemini_queue.sqlite3",
    "GEMINI_QUEUE_LEASE_SECONDS": "120",
    "GEMINI_QUEUE_MAX_WAIT_SECONDS": "180",
    "GEMINI_AUTH_FAILOVER_ATTEMPTS": "2",
    "GEMINI_TRANSIENT_MAX_ATTEMPTS": "3",
    "GEMINI_RETRY_BASE_SECONDS": "2",
    "GEMINI_RETRY_MAX_SECONDS": "60",
    "GEMINI_KEY_COOLDOWN_SECONDS": "60",
    "GEMINI_KEY_AUTH_COOLDOWN_SECONDS": "1800",
    "GEMINI_KEY_ERROR_COOLDOWN_SECONDS": "15",
    "GEMINI_POLICY_VERSION": "SHAKER_WANTED_V9",
    "GEMINI_FAIL_OPEN": "false",
    "LOCAL_SHADOW_ENABLED": "true",
    "LOCAL_SHADOW_MODEL_PATH": "/app/model/shaker_weak_tfidf_triage.joblib",
    "LOCAL_SHADOW_DB_PATH": "/app/db/local_shadow.sqlite3",
    "TELEGRAM_DELIVERY_DB_PATH": "/app/db/telegram_delivery_dedup.sqlite3",
    "NATIVE_QUOTE_FORWARD": "true",
    "NATIVE_QUOTE_FALLBACK_COPY": "true",
    "NATIVE_QUOTE_DETAILS": "true",
    "NATIVE_QUOTE_CAPTURED_BY": "Telegram Worker 2",
}
protected_names = (
    "API_ID",
    "API_HASH",
    "PHONE_NUMBER",
    "BOT_TOKEN",
    "USER_ID",
    "OUTPUT_GROUP_RAW_ID",
    "OUTPUT_GROUP_NAME",
    "NATIVE_QUOTE_TARGET",
    "AUTO_BIND_TARGET_ID",
)
protected_before = {name: before_values.get(name, "") for name in protected_names}

output = []
seen = set()
for raw in live.read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", raw)
    if not match:
        output.append(raw)
        continue
    name = match.group(1)
    if name in seen:
        continue
    seen.add(name)
    if name in updates:
        output.append(f"{name}={updates[name]}")
    else:
        output.append(raw)
missing = [name for name in updates if name not in seen]
if missing:
    output.extend(("", "# Enforced Worker 2 V9 durable AI configuration"))
    output.extend(f"{name}={updates[name]}" for name in missing)

with tempfile.NamedTemporaryFile(
    "w", encoding="utf-8", dir=live.parent, delete=False
) as handle:
    handle.write("\n".join(output).rstrip("\n") + "\n")
    temporary = Path(handle.name)
os.chmod(temporary, 0o600)
os.replace(temporary, live)

after_values = parse_env(live)
for name, expected in protected_before.items():
    if after_values.get(name, "") != expected:
        raise SystemExit(f"Protected setting changed unexpectedly: {name}")
print("GEMINI_POOL_INSTALLED=10")
print("GEMINI_MAX_KEY_ATTEMPTS=1")
print("GEMINI_PARALLEL_REQUESTS=3")
print("MESSAGE_HANDLER_LIMIT=10")
print("GEMINI_FAIL_OPEN=false")
print("TELEGRAM_AND_DESTINATION_SETTINGS_PRESERVED=YES")
print("CREDENTIAL_VALUES_PRINTED=NO")
PY

chmod 600 "$LIVE_ENV"
python3 "$PROJECT/worker_tools/validate_env_structure.py" --env "$LIVE_ENV" --required-keys 10
python3 "$PROJECT/worker_tools/compare_key_fingerprints.py" --env "$LIVE_ENV" --other-env "$WORKER1_ENV" --required-keys 10

cd "$PROJECT"
docker compose config --quiet
log "Recreating only Worker 2 with the V9 durable settings."
docker compose up -d --force-recreate "$SERVICE"

healthy="false"
for _attempt in $(seq 1 60); do
  running="$(docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null || true)"
  health="$(docker inspect "$CONTAINER" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)"
  if [ "$running" = "true" ] && [ "$health" = "healthy" ]; then
    healthy="true"
    break
  fi
  if [ "$running" = "false" ] || [ "$health" = "unhealthy" ]; then
    break
  fi
  sleep 2
done
if [ "$healthy" != "true" ]; then
  docker compose ps || true
  docker compose logs --tail=200 "$SERVICE" || true
  die "Worker 2 did not become healthy."
fi

docker compose exec -T "$SERVICE" python /app/worker_tools/verify_runtime.py
docker compose exec -T "$SERVICE" python /app/worker_tools/gemini_queue_status.py
docker compose exec -T "$SERVICE" python /app/worker_tools/local_shadow_status.py
docker compose exec -T "$SERVICE" python - <<'PY'
import os
expected = {
    "GEMINI_MAX_KEY_ATTEMPTS": "1",
    "GEMINI_MAX_PARALLEL_REQUESTS": "3",
    "MAX_CONCURRENT_MESSAGE_HANDLERS": "10",
    "GEMINI_PROJECT_TARGET_RPM": "12",
    "GEMINI_PROJECT_MIN_INTERVAL_SECONDS": "5",
    "GEMINI_FAIL_OPEN": "false",
}
for name, wanted in expected.items():
    actual = os.environ.get(name, "")
    if actual.lower() != wanted.lower():
        raise SystemExit(f"{name} must be {wanted}, found {actual or 'unset'}")
print("RUNNING_WORKER2_V9_LIMITS=OK")
print("API_REQUESTS_USED_BY_THIS_CHECK=0")
PY

worker1_started_after="$(
  docker inspect "$WORKER1_CONTAINER" --format '{{.State.StartedAt}}'
)"
[ "$worker1_started_after" = "$worker1_started_before" ] || die "Worker 1 was unexpectedly restarted."

ROLLBACK_ARMED="false"
COMPLETED="true"
printf '\n%s\n' "WORKER2_V9_ENFORCEMENT=SUCCESS" "WORKER1_RESTARTED=NO" "WORKER2_HEALTH=HEALTHY" "CROSS_WORKER_KEY_OVERLAP=0" "LIVE_GEMINI_REQUESTS=0" "Backup retained: $BACKUP_ENV"

if [ "${WORKER2_FOLLOW_LOGS:-true}" = "true" ]; then
  echo
  echo "Following fresh Worker 2 logs. Press Ctrl+C to stop watching."
  docker compose logs -f --since=2m --tail=120 "$SERVICE"
else
  docker compose logs --since=2m --tail=120 "$SERVICE"
fi
