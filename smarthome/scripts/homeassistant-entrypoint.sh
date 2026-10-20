#!/bin/sh
# Home Assistant start hook (smarthome/compose.yml runs it before the image's
# own /init).
#
# 1. Trust our root CA, mounted into /usr/local/share/ca-certificates: HA's
#    Python then verifies https://*.$TLD services (authentik, Plex, ...).
# 2. Wait for the recorder database — see below.
# 3. Wait for the Python package index (DNS) — see below.

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

# --- Wait for the Python package index before starting Home Assistant --------
# The HA-MCP integration's in-process server force-installs the `ha-mcp` Python
# package on every start while its channel auto-update is on, so it needs PyPI
# during bring-up. On a host reboot / docker daemon restart the daemon starts
# the whole stack in the same second — Home Assistant and, with it, the
# resolvers (unbound + pihole) — and the installer raced the resolver: the fetch
# failed, the in-process server stayed down, and Home Assistant filed a repair
# issue whose text misleadingly blames version requirements ("requires ha-mcp
# 7.10.0 ... and Home Assistant 2026.8.0 ...", both of which were satisfied);
# because logger.yaml sets `default: critical`, the true uv error — "Failed to
# fetch: https://pypi.org/simple/ha-mcp/" — was never logged (happened on the
# reference server, 2026-10-13). Block here until the index answers so the
# installer never races the resolver.
#
# Any HTTP response counts as reachable, 4xx included: this probes the
# DNS/TCP/TLS path, not what the index serves.
#
# Tunables:
#   PACKAGE_INDEX_WAIT_SECONDS  max seconds to wait (default 300; 0 = skip)
#   PACKAGE_INDEX_URL           URL probed (default https://pypi.org/simple/)
# If the index never answers we still start HA (the integration files a repair
# issue and a reload retries) rather than leaving the house without automations.
if [ "${PACKAGE_INDEX_WAIT_SECONDS:-300}" != "0" ]; then
  echo "⏳ Waiting for the Python package index..."
  PACKAGE_INDEX_URL="${PACKAGE_INDEX_URL:-https://pypi.org/simple/}" \
  PACKAGE_INDEX_WAIT_SECONDS="${PACKAGE_INDEX_WAIT_SECONDS:-300}" \
  python3 - <<'PY'
import os
import time
import urllib.error
import urllib.request

url = os.environ.get("PACKAGE_INDEX_URL", "https://pypi.org/simple/")
timeout = int(os.environ.get("PACKAGE_INDEX_WAIT_SECONDS", "300"))
interval = 5
print(f"   target {url}, timeout {timeout}s")

deadline = time.monotonic() + timeout
attempt = 0
while True:
    attempt += 1
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            resp.read(1)  # touch the body: a stalled transfer is not "ready"
        print(f"✅ Package index reachable after {attempt} attempt(s)")
        break
    except urllib.error.HTTPError as exc:
        # The server answered, so DNS/TCP/TLS all work; the status code is
        # irrelevant to whether the installer can fetch from the index.
        print(f"✅ Package index reachable after {attempt} attempt(s) (HTTP {exc.code})")
        break
    except Exception as exc:
        if time.monotonic() >= deadline:
            print(f"⚠️  Package index still unreachable after {timeout}s: {exc}")
            print("⚠️  Starting Home Assistant anyway; retry via the integration reload")
            break
        print(f"… index not ready (attempt {attempt}): {type(exc).__name__}, retrying in {interval}s")
        time.sleep(interval)
PY
fi

exec "$@"
