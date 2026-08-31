#!/usr/bin/env bash
set -Eeuo pipefail

archive="/root/Telegram_Worker_2_V9_Standalone.zip"
env_file="/root/worker2.env"
worker1_dir="/opt/TelegramForwarder-worker1"
worker2_dir="/opt/TelegramForwarder-worker2"
worker1_container="telegram-forwarder-worker1"
worker2_container="telegram-forwarder-worker2"
expected_zip_sha="89d19d5bfd6298e5d74c05ab4d9a5873ce933606e2fc5c06f6f73c7e536eb886"
stage=""
completed="false"

log()  { printf '\n[+] %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

env_value() {
  local file="$1"
  local name="$2"
  awk -v wanted="$name" '
    index($0, wanted "=") == 1 { value=substr($0, length(wanted)+2) }
    END { print value }
  ' "$file"
}

mount_source() {
  local container="$1"
  local destination="$2"
  docker inspect "$container" --format '{{range .Mounts}}{{printf "%s|%s\n" .Destination .Source}}{{end}}' | awk -F '|' -v wanted="$destination" '$1 == wanted { print $2 }'
}

finish() {
  local status=$?
  trap - EXIT
  set +e
  if [ "$status" -eq 0 ] && [ "$completed" != "true" ]; then
    status=97
    warn "Installer ended before completing coexistence verification."
  fi
  if [ "$status" -eq 0 ] && [ -n "$stage" ] && [ -d "$stage" ]; then
    case "$stage" in
      /root/worker2-v9-install.*) rm -rf -- "$stage" ;;
      *) warn "Unexpected staging path retained: $stage" ;;
    esac
  elif [ "$status" -ne 0 ]; then
    warn "Worker 2 installation failed. Worker 1 was not intentionally changed."
    [ -z "$stage" ] || warn "Extracted installer retained at: $stage"
  fi
  exit "$status"
}
trap finish EXIT

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run this installer as root."
for command_name in docker python3 sha256sum unzip awk; do
  command -v "$command_name" >/dev/null 2>&1 || die "Missing required command: $command_name"
done
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

[ -f "$archive" ] || die "Missing $archive"
[ -f "$env_file" ] || die "Missing $env_file"
[ -f "$worker1_dir/.env" ] || die "Worker 1 environment is missing."

actual_zip_sha="$(sha256sum "$archive" | awk '{print $1}')"
[ "$actual_zip_sha" = "$expected_zip_sha" ] || die "Worker 2 V9 ZIP checksum does not match this installer."
chmod 600 "$env_file"
unzip -tq "$archive"

worker1_running="$(docker inspect -f '{{.State.Running}}' "$worker1_container" 2>/dev/null || true)"
worker1_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$worker1_container" 2>/dev/null || true)"
[ "$worker1_running" = "true" ] || die "Worker 1 must be running."
case "$worker1_health" in healthy|none) ;; *) die "Worker 1 is not healthy: $worker1_health" ;; esac
worker1_started_before="$(docker inspect -f '{{.State.StartedAt}}' "$worker1_container")"

worker1_output_id="$(env_value "$worker1_dir/.env" OUTPUT_GROUP_RAW_ID)"
worker1_output_name="$(env_value "$worker1_dir/.env" OUTPUT_GROUP_NAME)"
worker2_output_id="$(env_value "$env_file" OUTPUT_GROUP_RAW_ID)"
worker2_output_name="$(env_value "$env_file" OUTPUT_GROUP_NAME)"
[ -n "$worker1_output_id" ] && [ "$worker1_output_id" = "$worker2_output_id" ] || die "Worker 1 and Worker 2 OUTPUT_GROUP_RAW_ID values differ."
[ -n "$worker1_output_name" ] && [ "$worker1_output_name" = "$worker2_output_name" ] || die "Worker 1 and Worker 2 OUTPUT_GROUP_NAME values differ."

for identity_name in PHONE_NUMBER BOT_TOKEN USER_ID; do
  worker1_identity="$(env_value "$worker1_dir/.env" "$identity_name")"
  worker2_identity="$(env_value "$env_file" "$identity_name")"
  [ -n "$worker2_identity" ] && [ "$worker1_identity" != "$worker2_identity" ] || die "Worker 2 $identity_name is not distinct from Worker 1."
done

stage="$(mktemp -d /root/worker2-v9-install.XXXXXX)"
unzip -q "$archive" -d "$stage"
project="$stage/Telegram_Worker_2_V9_Standalone"
[ -f "$project/install_worker2.sh" ] || die "Worker 2 V9 installer is missing."
(
  cd "$project"
  sha256sum -c MANIFEST.sha256 >/dev/null
)

python3 "$project/worker_tools/validate_env_structure.py" --env "$env_file" --required-keys 10
python3 "$project/worker_tools/compare_key_fingerprints.py" --env "$env_file" --other-env "$worker1_dir/.env" --required-keys 10
python3 "$project/worker_tools/worker2_coexistence_selftest.py"

cd "$project"
chmod +x install_worker2.sh
install_args=(--env-file "$env_file")
if [ "${WORKER2_RUN_LIVE_GEMINI_HEALTH:-false}" != "true" ]; then
  install_args+=(--skip-live-gemini-check)
  warn "Live Gemini health calls are disabled by default."
fi

log "Installing Worker 2 V9. Worker 1 remains online."
printf '%s\n' "Enter the Worker 2 Telegram login code and 2FA password if requested."
COMPOSE_BAKE=false ./install_worker2.sh "${install_args[@]}"

worker1_running_after="$(docker inspect -f '{{.State.Running}}' "$worker1_container" 2>/dev/null || true)"
worker1_started_after="$(docker inspect -f '{{.State.StartedAt}}' "$worker1_container" 2>/dev/null || true)"
worker2_running="$(docker inspect -f '{{.State.Running}}' "$worker2_container" 2>/dev/null || true)"
worker2_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$worker2_container" 2>/dev/null || true)"
[ "$worker1_running_after" = "true" ] || die "Worker 1 stopped during installation."
[ "$worker1_started_after" = "$worker1_started_before" ] || die "Worker 1 was unexpectedly restarted."
[ "$worker2_running" = "true" ] || die "Worker 2 is not running."
[ "$worker2_health" = "healthy" ] || die "Worker 2 is not healthy: $worker2_health"

installed_worker2_output_id="$(env_value "$worker2_dir/.env" OUTPUT_GROUP_RAW_ID)"
worker1_native_target="$(env_value "$worker1_dir/.env" NATIVE_QUOTE_TARGET)"
worker2_native_target="$(env_value "$worker2_dir/.env" NATIVE_QUOTE_TARGET)"
[ "$installed_worker2_output_id" = "$worker1_output_id" ] || die "Installed Worker 2 destination differs from Worker 1."
[ -n "$worker1_native_target" ] && [ "$worker1_native_target" = "$worker2_native_target" ] || die "Worker 1 and Worker 2 marked native destinations differ."

python3 "$worker2_dir/worker_tools/compare_key_fingerprints.py" --env "$worker2_dir/.env" --other-env "$worker1_dir/.env" --required-keys 10

worker1_db="$(mount_source "$worker1_container" /app/db)"
worker2_db="$(mount_source "$worker2_container" /app/db)"
worker1_sessions="$(mount_source "$worker1_container" /app/sessions)"
worker2_sessions="$(mount_source "$worker2_container" /app/sessions)"
[ -n "$worker1_db" ] && [ -n "$worker2_db" ] && [ "$worker1_db" != "$worker2_db" ] || die "Worker database mounts are not isolated."
[ -n "$worker1_sessions" ] && [ -n "$worker2_sessions" ] && [ "$worker1_sessions" != "$worker2_sessions" ] || die "Worker session mounts are not isolated."

cd "$worker2_dir"
docker compose exec -T telegram-forwarder python /app/worker_tools/verify_runtime.py
docker compose exec -T telegram-forwarder python /app/worker_tools/gemini_queue_status.py
docker compose exec -T telegram-forwarder python /app/worker_tools/local_shadow_status.py
docker compose exec -T telegram-forwarder python - <<'PY'
import os
expected = {
    "WORKER_NAMESPACE": "worker2",
    "WORKER_INSTANCE": "worker2",
    "GEMINI_MAX_KEY_ATTEMPTS": "1",
    "GEMINI_MAX_PARALLEL_REQUESTS": "3",
    "MAX_CONCURRENT_MESSAGE_HANDLERS": "10",
    "GEMINI_PROJECT_TARGET_RPM": "12",
    "GEMINI_PROJECT_MIN_INTERVAL_SECONDS": "5",
    "GEMINI_FAIL_OPEN": "false",
    "LOCAL_SHADOW_ENABLED": "true",
}
for name, wanted in expected.items():
    actual = os.environ.get(name, "")
    if actual.lower() != wanted.lower():
        raise SystemExit(f"{name} must be {wanted}, found {actual or 'unset'}")
print("WORKER2_V9_SETTINGS=OK")
print("API_REQUESTS_USED_BY_THIS_CHECK=0")
PY

printf '\n%s\n' "WORKER2_V9_INSTALLATION=SUCCESS" "WORKER1_RESTARTED=NO" "BOTH_WORKERS_RUNNING=YES" "CROSS_WORKER_KEY_OVERLAP=0" "DATABASE_MOUNTS_ISOLATED=YES" "SESSION_MOUNTS_ISOLATED=YES" "LIVE_GEMINI_HEALTH=${WORKER2_RUN_LIVE_GEMINI_HEALTH:-false}"

echo
docker ps --filter "name=telegram-forwarder-worker" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
echo
docker compose logs --since=5m --tail=120 telegram-forwarder || true
completed="true"
