#!/usr/bin/env bash
set -Eeuo pipefail

archive="/root/Telegram_Worker_1_V9_Standalone.zip"
env_file="/root/worker1.env"
expected_sha="f831c12367d1978ac7dcee488556cd2cce2defc6562d41bea146e0f245073df8"
stage_dir=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_exit() {
  status=$?
  if [ "$status" -ne 0 ] && [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    printf 'Installer staging directory retained at: %s\n' "$stage_dir" >&2
  fi
  if [ "$status" -ne 0 ]; then
    printf 'Worker 1 update did not complete. Your SSH connection remains open.\n' >&2
  fi
}
trap on_exit EXIT

[ -f "$archive" ] || fail "Missing $archive"
[ -f "$env_file" ] || fail "Missing $env_file"
chmod 600 "$env_file"

actual_sha="$(sha256sum "$archive" | awk '{print $1}')"
if [ "$actual_sha" != "$expected_sha" ]; then
  printf 'Expected: %s\nActual:   %s\n' "$expected_sha" "$actual_sha" >&2
  fail "Incorrect Worker 1 V9 ZIP checksum"
fi
unzip -tq "$archive" || fail "The Worker 1 V9 ZIP is damaged"

stage_dir="$(mktemp -d /root/worker1-v9.XXXXXX)"
[ -n "$stage_dir" ] && [ -d "$stage_dir" ] \
  || fail "Could not create a staging directory"
unzip -q "$archive" -d "$stage_dir"

project_dir="$stage_dir/Telegram_Worker_1_V9_Standalone"
[ -f "$project_dir/install_worker1.sh" ] || fail "Installer is missing"
[ -f "$project_dir/MANIFEST.sha256" ] || fail "Project manifest is missing"
(cd "$project_dir" && sha256sum -c MANIFEST.sha256 >/dev/null) \
  || fail "Project manifest validation failed"

printf 'ZIP_CHECKSUM=OK\n'
printf 'ZIP_MANIFEST=OK\n'

python3 "$project_dir/worker_tools/validate_env_structure.py" \
  --env "$env_file" --required-keys 10
python3 "$project_dir/worker_tools/compare_key_fingerprints.py" \
  --env "$env_file" --required-keys 10

chmod +x "$project_dir/install_worker1.sh"
printf '\nStarting the Worker 1 V9 installation.\n'
printf 'Enter the Telegram login code and 2FA password if requested.\n'

(cd "$project_dir" && COMPOSE_BAKE=false ./install_worker1.sh --env-file "$env_file")
case "$stage_dir" in
  /root/worker1-v9.*)
    rm -rf -- "$stage_dir"
    stage_dir=""
    ;;
  *)
    fail "Refusing to remove an unexpected staging path"
    ;;
esac

printf '\nINSTALLATION_COMPLETED_SUCCESSFULLY\n'
cd /opt/TelegramForwarder-worker1

required_settings=(
  "GEMINI_MAX_KEY_ATTEMPTS=1"
  "GEMINI_MAX_PARALLEL_REQUESTS=3"
  "MAX_CONCURRENT_MESSAGE_HANDLERS=10"
  "GEMINI_PROJECT_TARGET_RPM=12"
  "GEMINI_PROJECT_MIN_INTERVAL_SECONDS=5"
  "GEMINI_FAIL_OPEN=false"
  "LOCAL_SHADOW_ENABLED=true"
)
for setting in "${required_settings[@]}"; do
  if ! grep -Fqx -- "$setting" .env; then
    fail "Installed .env is missing required setting: ${setting%%=*}"
  fi
done
printf 'V9_MITIGATION_SETTINGS=OK\n'

printf '\nContainer status:\n'
docker compose ps
docker inspect telegram-forwarder-worker1 \
  --format 'running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} image={{.Config.Image}}'

printf '\nRuntime verification:\n'
docker compose exec -T telegram-forwarder \
  python /app/worker_tools/verify_runtime.py

printf '\nGemini queue status:\n'
docker compose exec -T telegram-forwarder \
  python /app/worker_tools/gemini_queue_status.py

printf '\nLocal shadow status:\n'
docker compose exec -T telegram-forwarder \
  python /app/worker_tools/local_shadow_status.py

printf '\nRecent logs:\n'
docker compose logs --since=10m --tail=150 telegram-forwarder

trap - EXIT
exit 0
