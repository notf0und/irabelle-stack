#!/bin/sh
# Home Assistant start hook (smarthome/compose.yml runs it before the image's
# own /init).
#
# 1. Trust our root CA, mounted into /usr/local/share/ca-certificates: HA's
#    Python then verifies https://*.$TLD services (authentik, Plex, ...).
# 2. Wait for the recorder database — see below.

update-ca-certificates >/dev/null 2>&1 && echo "✅ Updated CA certificates"

# --- Wait for the recorder database before starting Home Assistant -----------
# `depends_on: condition: service_healthy` in compose.yaml is only honoured by
# `docker compose up`. On a host reboot / docker daemon restart the daemon
# starts containers by `restart:` policy and ignores depends_on, so HA can come
# up before MariaDB is ready. The recorder only connects at startup and gives up
# after `db_max_retries`, leaving history dead until HA is restarted (happened on
# the reference server). Block here until the DB really answers a query, so the recorder
# never burns its retries on a race.
#
# Tunables:
#   RECORDER_DB_WAIT_SECONDS  max seconds to wait (default 600; 0 = skip the wait)
#   RECORDER_DB_URL           the SQLAlchemy URL (smarthome/compose.yml sets it;
#                             configuration.yaml reads it with !env_var)
# If the DB never becomes ready we still start HA (recorder falls back to its
# own retries) rather than leaving the whole house without automations.
if [ "${RECORDER_DB_WAIT_SECONDS:-600}" != "0" ]; then
  echo "⏳ Waiting for recorder database..."
  python3 - <<'PY'
import os
import re
import sys
import time

try:
    from sqlalchemy import create_engine, text
except Exception as exc:  # tooling missing, do not block boot
    print(f"⚠️  sqlalchemy unavailable ({exc}); skipping database wait")
    sys.exit(0)

timeout = int(os.environ.get("RECORDER_DB_WAIT_SECONDS", "600"))
interval = 5


def resolve_url():
    url = os.environ.get("RECORDER_DB_URL")
    if url:
        return url, "RECORDER_DB_URL"
    conf = "/config/configuration.yaml"
    try:
        with open(conf) as fh:
            for line in fh:
                match = re.match(r"\s*db_url:\s*(\S+)\s*$", line)
                if match:
                    return match.group(1), conf
    except OSError as exc:
        print(f"⚠️  Could not read {conf}: {exc}")
    user = os.environ.get("MARIADB_USER", "homeassistant")
    password = os.environ.get("MARIADB_PASSWORD", "")
    database = os.environ.get("MARIADB_DATABASE", "homeassistant")
    return f"mysql://{user}:{password}@127.0.0.1:3306/{database}", "env fallback"


url, source = resolve_url()
host = url.rsplit("@", 1)[-1]
print(f"   target {host} (from {source}), timeout {timeout}s")

deadline = time.monotonic() + timeout
attempt = 0
while True:
    attempt += 1
    try:
        engine = create_engine(url, connect_args={"connect_timeout": 5})
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
        finally:
            engine.dispose()
        print(f"✅ Recorder database ready after {attempt} attempt(s)")
        break
    except Exception as exc:
        if time.monotonic() >= deadline:
            print(f"⚠️  Database still unreachable after {timeout}s: {exc}")
            print("⚠️  Starting Home Assistant anyway; recorder will retry on its own")
            break
        print(f"… database not ready (attempt {attempt}): {type(exc).__name__}, retrying in {interval}s")
        time.sleep(interval)
PY
fi

exec "$@"
