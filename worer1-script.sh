cd /root
set +e

archive="/root/Telegram_Worker_1_V8_Standalone_Fixed.zip"
env_file="/root/worker1.env"
expected_sha="db290342b10c67e96e2052c559c08da598a8cf70849389718c816c0c61e2bd86"
stage_dir=""

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
    echo "Download and upload the latest updated ZIP."
  elif ! unzip -tq "$archive"; then
    echo "ERROR: The ZIP is damaged."
  else
    stage_dir="$(mktemp -d /root/worker1-v8-fixed.XXXXXX)"

    if [ -z "$stage_dir" ] || [ ! -d "$stage_dir" ]; then
      echo "ERROR: Could not create staging directory."
    elif ! unzip -q "$archive" -d "$stage_dir"; then
      echo "ERROR: Could not extract the ZIP."
      echo "Staging directory retained at: $stage_dir"
    else
      project_dir="$stage_dir/Telegram_Worker_1_V8_Standalone"

      if [ ! -f "$project_dir/install_worker1.sh" ]; then
        echo "ERROR: Installer is missing."
        echo "Extracted files retained at: $stage_dir"
      elif ! (cd "$project_dir" && sha256sum -c MANIFEST.sha256 >/dev/null); then
        echo "ERROR: Project manifest validation failed."
        echo "Extracted files retained at: $stage_dir"
      else
        echo "ZIP_CHECKSUM=OK"
        echo "ZIP_MANIFEST=OK"

        python3 "$project_dir/worker_tools/validate_env_structure.py" --env "$env_file" --required-keys 10
        env_result="$?"

        if [ "$env_result" -ne 0 ]; then
          echo "ERROR: worker1.env validation failed."
          echo "Nothing was installed."
          echo "Extracted files retained at: $stage_dir"
        else
          cd "$project_dir"
          chmod +x install_worker1.sh

          echo
          echo "Starting fresh Worker 1 installation."
          echo "Enter the Telegram login code and 2FA password when requested."

          COMPOSE_BAKE=false ./install_worker1.sh --env-file "$env_file"
          install_result="$?"

          if [ "$install_result" -eq 0 ]; then
            cd /root
            rm -rf -- "$stage_dir"

            echo
            echo "INSTALLATION COMPLETED SUCCESSFULLY"

            cd /opt/TelegramForwarder-worker1

            echo
            echo "Information-reply configuration:"

            if grep -qx 'NATIVE_QUOTE_FORWARD=true' .env; then
              echo "NATIVE_FORWARD=ENABLED"
            else
              echo "WARNING: NATIVE_QUOTE_FORWARD is not enabled."
            fi

            if grep -qx 'NATIVE_QUOTE_DETAILS=true' .env; then
              echo "INFORMATION_REPLY=ENABLED"
            else
              echo "WARNING: NATIVE_QUOTE_DETAILS is not enabled."
            fi

            echo
            echo "Container status:"

            docker compose ps

            docker inspect telegram-forwarder-worker1 --format 'running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} image={{.Config.Image}}'

            echo
            echo "Runtime verification:"

            docker compose exec -T telegram-forwarder python /app/worker_tools/verify_runtime.py

            echo
            echo "Recent logs:"

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
fi
