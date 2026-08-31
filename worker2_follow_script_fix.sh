bash <<'WORKER2_FIX'
set -Eeuo pipefail

PROJECT="/opt/TelegramForwarder-worker2"
SOURCE_ENV="/root/worker2.env"
LIVE_ENV="$PROJECT/.env"
SERVICE="telegram-forwarder"
CONTAINER="telegram-forwarder-worker2"
WORKER1_CONTAINER="telegram-forwarder-worker1"
BACKUP_ENV=""
ROLLBACK_ARMED="false"

fail() {
  printf '\n[ERROR] %s\n' "$*" >&2
  return 1
}

rollback() {
  status=$?
  trap - ERR
  set +e

  if [ "$ROLLBACK_ARMED" = "true" ] && [ -f "$BACKUP_ENV" ]; then
    echo
    echo "[!] Restoring the previous Worker 2 environment."
    cp -a "$BACKUP_ENV" "$LIVE_ENV"
    chmod 600 "$LIVE_ENV"
    cd "$PROJECT"
    docker compose up -d --force-recreate "$SERVICE"
  fi

  exit "$status"
}

trap rollback ERR

[ "$(id -u)" -eq 0 ] || fail "Run this as root."
[ -f "$SOURCE_ENV" ] || fail "Missing $SOURCE_ENV"
[ -f "$LIVE_ENV" ] || fail "Missing $LIVE_ENV"
[ -f "$PROJECT/docker-compose.yml" ] || fail "Worker 2 project is incomplete."

worker1_started_before="$(
  docker inspect "$WORKER1_CONTAINER" --format '{{.State.StartedAt}}' 2>/dev/null
)" || fail "Worker 1 is not running."

BACKUP_ENV="${LIVE_ENV}.backup-before-gemini-enforcement-$(date +%Y%m%d-%H%M%S)"
cp -a "$LIVE_ENV" "$BACKUP_ENV"
ROLLBACK_ARMED="true"

python3 - "$SOURCE_ENV" "$LIVE_ENV" <<'PY'
import os
import re
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
keys = [
    value
    for value in re.split(r"[,;\s]+", raw_pool)
    if value
]
keys = list(dict.fromkeys(keys))

if len(keys) != 10:
    raise SystemExit(
        f"Expected 10 unique Gemini keys in {source}, found {len(keys)}"
    )

if not all(re.fullmatch(r"AQ\.[A-Za-z0-9_-]{50}", key) for key in keys):
    raise SystemExit("One or more Gemini keys has an invalid AQ format")

updates = {
    "GEMINI_API_KEYS": ",".join(keys),
    "GEMINI_API_KEY": "",
    "GEMINI_API_BASE": "",
    "GEMINI_REST_API_BASE":
        "https://generativelanguage.googleapis.com/v1beta",
    "GEMINI_REQUIRED_KEY_COUNT": "10",
    "GEMINI_MAX_KEY_ATTEMPTS": "10",
    "GEMINI_MAX_PARALLEL_REQUESTS": "2",
    "GEMINI_REQUEST_TIMEOUT_SECONDS": "45",
    "GEMINI_KEY_COOLDOWN_SECONDS": "90",
    "GEMINI_KEY_AUTH_COOLDOWN_SECONDS": "1800",
    "GEMINI_KEY_ERROR_COOLDOWN_SECONDS": "30",
    "GEMINI_FAIL_OPEN": "true",
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

protected_before = {
    name: before_values.get(name, "")
    for name in protected_names
}

output = []
updated = set()

for raw in live.read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", raw)

    if match and match.group(1) in updates:
        name = match.group(1)

        if name not in updated:
            output.append(f"{name}={updates[name]}")
            updated.add(name)
        continue

    output.append(raw)

missing = [name for name in updates if name not in updated]

if missing:
    output.append("")
    output.append("# Enforced Worker 2 Gemini configuration")
    for name in missing:
        output.append(f"{name}={updates[name]}")

temporary = live.with_name(live.name + ".worker2-update")
temporary.write_text(
    "\n".join(output).rstrip("\n") + "\n",
    encoding="utf-8",
)
os.chmod(temporary, 0o600)
os.replace(temporary, live)

after_values = parse_env(live)

for name, expected in protected_before.items():
    if after_values.get(name, "") != expected:
        raise SystemExit(f"Protected setting changed unexpectedly: {name}")

print("GEMINI_POOL_INSTALLED=10")
print("GEMINI_PARALLEL_REQUESTS=2")
print("GEMINI_429_COOLDOWN_SECONDS=90")
print("TELEGRAM_AND_DESTINATION_SETTINGS_PRESERVED=YES")
print("CREDENTIAL_VALUES_PRINTED=NO")
PY

chmod 600 "$LIVE_ENV"

python3 "$PROJECT/worker_tools/validate_env_structure.py" \
  --env "$LIVE_ENV" \
  --required-keys 10

cd "$PROJECT"
docker compose config --quiet

echo
echo "[+] Recreating only Worker 2 with the enforced configuration."
docker compose up -d --force-recreate "$SERVICE"

echo
echo "[+] Waiting for Worker 2 health."
healthy="false"

for attempt in $(seq 1 60); do
  running="$(
    docker inspect "$CONTAINER" \
      --format '{{.State.Running}}' 2>/dev/null || true
  )"

  health="$(
    docker inspect "$CONTAINER" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
      2>/dev/null || true
  )"

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
  fail "Worker 2 did not become healthy."
fi

docker compose exec -T "$SERVICE" \
  python /app/worker_tools/verify_runtime.py

docker compose exec -T "$SERVICE" python - <<'PY'
import os
import re

keys = [
    value
    for value in re.split(
        r"[,;\s]+",
        os.environ.get("GEMINI_API_KEYS", ""),
    )
    if value
]
keys = list(dict.fromkeys(keys))

assert len(keys) == 10
assert os.environ.get("GEMINI_MAX_PARALLEL_REQUESTS") == "2"
assert os.environ.get("GEMINI_KEY_COOLDOWN_SECONDS") == "90"

print("RUNNING_GEMINI_POOL=10")
print("RUNNING_PARALLEL_LIMIT=2")
print("RUNNING_COOLDOWN=90")
print("API_REQUESTS_USED_BY_THIS_CHECK=0")
PY

worker1_started_after="$(
  docker inspect "$WORKER1_CONTAINER" --format '{{.State.StartedAt}}'
)"

[ "$worker1_started_after" = "$worker1_started_before" ] \
  || fail "Worker 1 was unexpectedly restarted."

ROLLBACK_ARMED="false"
trap - ERR

echo
echo "WORKER2_ENFORCEMENT=SUCCESS"
echo "WORKER1_RESTARTED=NO"
echo "WORKER2_HEALTH=HEALTHY"
echo "Backup retained: $BACKUP_ENV"
echo
echo "Only fresh Worker 2 logs will now be displayed."
echo "Press Ctrl+C to stop watching; Worker 2 will keep running."
echo

docker compose logs -f --since=2m --tail=120 "$SERVICE"
WORKER2_FIX