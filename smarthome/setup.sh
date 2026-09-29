#!/usr/bin/env bash
# smarthome/setup.sh — per-stack setup hook called by the top-level setup.sh
#
# Generates the passwords that Home Assistant and Mosquitto need.
# It only creates them the first time; subsequent runs leave existing values
# untouched (same behavior as the Authentik hook).

set -euo pipefail

STACK_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$STACK_DIR/.env"

# Load the shared helpers (host_env_get / host_env_set)
# shellcheck source=../lib/host.sh
. "$STACK_DIR/../lib/host.sh"

need_password() {
  local key="$1"
  local val
  val=$(env_var "$ENV_FILE" "$key" 2>/dev/null || true)
  [ -z "$val" ]
}

generate_password() {
  head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1
}

created_any=false

if need_password HA_DB_PASSWORD; then
  pw=$(generate_password)
  host_env_set HA_DB_PASSWORD "$pw"
  created_any=true
fi

if need_password HA_DB_ROOT_PASSWORD; then
  pw=$(generate_password)
  host_env_set HA_DB_ROOT_PASSWORD "$pw"
  created_any=true
fi

if need_password MQTT_PASSWORD; then
  pw=$(generate_password)
  host_env_set MQTT_PASSWORD "$pw"
  created_any=true
fi

if [ "$created_any" = true ]; then
  echo "smarthome: generated missing passwords (HA_DB_PASSWORD, HA_DB_ROOT_PASSWORD, MQTT_PASSWORD)"
else
  echo "smarthome: passwords already present — left untouched"
fi
