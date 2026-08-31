cd /root
set +e

archive="/root/Telegram_Worker_1_V8_Standalone_Fixed.zip"
env_file="/root/worker1.env"
expected_sha="a3e6cb5fbe939551b867afa6b179879f19975891c5d8fa3736b3c3927745d2d4"

if [ ! -f "$archive" ]; then
  echo "ERROR: Missing $archive"
elif [ ! -f "$env_file" ]; then
  echo "ERROR: Missing $env_file"
else
  chmod 600 "$env_file"

  actual_sha="$(sha256sum "$archive" | awk '{print $1}')"

  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "ERROR: Incorrect ZIP checksum."
    echo "Expected: $expected_sha"
    echo "Actual:   $actual_sha"
  elif ! unzip -tq "$archive"; then
    echo "ERROR: The ZIP is damaged."
  else
    stage_dir="$(mktemp -d /root/worker1-v8-fixed.XXXXXX)"
    unzip -q "$archive" -d "$stage_dir"

    project_dir="$stage_dir/Telegram_Worker_1_V8_Standalone"

    if [ ! -f "$project_dir/install_worker1.sh" ]; then
      echo "ERROR: Installer is missing."
    elif ! (cd "$project_dir" && sha256sum -c MANIFEST.sha256 >/dev/null); then
      echo "ERROR: Project manifest validation failed."
    else
      python3 "$project_dir/worker_tools/validate_env_structure.py" --env "$env_file" --required-keys 10

      if [ "$?" -ne 0 ]; then
        echo "ERROR: worker1.env validation failed."
        echo "Nothing was installed."
      else
        cd "$project_dir"
        chmod +x install_worker1.sh

        echo
        echo "Starting fresh installation."
        echo "Enter the Telegram login code and 2FA password when requested."

        COMPOSE_BAKE=false ./install_worker1.sh --env-file "$env_file"
        install_result="$?"

        if [ "$install_result" -eq 0 ]; then
          cd /root
          rm -rf -- "$stage_dir"

          echo
          echo "INSTALLATION COMPLETED SUCCESSFULLY"

          cd /opt/TelegramForwarder-worker1
          docker compose ps
          docker inspect telegram-forwarder-worker1 --format 'running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} image={{.Config.Image}}'
          docker compose exec -T telegram-forwarder python /app/worker_tools/verify_runtime.py
          docker compose logs --since=10m --tail=150 telegram-forwarder
        else
          echo
          echo "INSTALLATION FAILED."
          echo "Diagnostic project retained at: /opt/TelegramForwarder-worker1"
          echo "Installer source retained at: $stage_dir"
          echo "Your SSH connection remains open."
        fi
      fi
    fi
  fi
fi
