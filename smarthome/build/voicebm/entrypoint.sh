#!/bin/bash
set -e

DATA_DIR="${VOICEBM_BASE:-/data}"
MODELS_DIR="${DATA_DIR}/models"
SHERPA_MODEL_NAME="${SHERPA_MODEL_NAME:-nemo_en_titanet_small.onnx}"
SHERPA_MODEL="${SHERPA_MODEL:-${MODELS_DIR}/${SHERPA_MODEL_NAME}}"
MQTT_BROKER="${MQTT_BROKER:-localhost}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
# HOST_AUDIO is full URL (e.g., http://<host-ip>:9090)
HOST_AUDIO="${HOST_AUDIO:-http://localhost:9090}"

# STT config
VOICEBM_STT_MODEL="${VOICEBM_STT_MODEL:-cohere-transcribe}"
VOICEBM_STT_LANGUAGE="${VOICEBM_STT_LANGUAGE:-en}"
VOICEBM_STT_THREADS="${VOICEBM_STT_THREADS:-4}"
STT_MODELS_DIR="${DATA_DIR}/stt-models"

# ---------------------------------------------------------------------------
# Ensure runtime directories exist
# ---------------------------------------------------------------------------
mkdir -p \
    "${DATA_DIR}/enroll" \
    "${DATA_DIR}/recordings" \
    "${DATA_DIR}/embeddings" \
    "${DATA_DIR}/pending_active/recordings" \
    "${DATA_DIR}/meta" \
    "${MODELS_DIR}" \
    "${DATA_DIR}/stt_requests" \
    "${DATA_DIR}/bin" \
    "${STT_MODELS_DIR}"

# Create the Sherpa embedding wrapper
cat > "${DATA_DIR}/bin/embed_stt.sh" << EOF
#!/usr/bin/env bash
set -euo pipefail
INPUT="\$1"
OUTPUT="\$2"
exec python3 /app/sherpa_embed.py --model "${SHERPA_MODEL}" --wav "\$INPUT" --out "\$OUTPUT"
EOF
chmod +x "${DATA_DIR}/bin/embed_stt.sh"

# ---------------------------------------------------------------------------
# Generate or update config.json from environment variables
# ---------------------------------------------------------------------------
echo "[voicebm] Configuring VoiceBM from environment variables..."
python3 /app/config_generator.py

# ---------------------------------------------------------------------------
# Download Sherpa-ONNX speaker recognition model (first run only)
# ---------------------------------------------------------------------------
if [ ! -f "${SHERPA_MODEL}" ]; then
    echo "[voicebm] Downloading speaker model: ${SHERPA_MODEL_NAME}"
    MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/${SHERPA_MODEL_NAME}"
    curl -fsSL -o "${SHERPA_MODEL}" "${MODEL_URL}"
    echo "[voicebm] Speaker model ready"
fi

# ---------------------------------------------------------------------------
# Download STT model (first run only)
# ---------------------------------------------------------------------------
echo "[voicebm] Downloading STT model: ${VOICEBM_STT_MODEL}"
python3 - << PYEOF
import sys
sys.path.insert(0, "/app")
import voicebm_stt_engine
try:
    voicebm_stt_engine.download_stt_model("${VOICEBM_STT_MODEL}", "${STT_MODELS_DIR}")
    print("[voicebm] STT model ready")
except Exception as e:
    print(f"[voicebm] ERROR downloading STT model: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ---------------------------------------------------------------------------
# Adapt VoiceBM v2 scripts to this container (they hardcode /home/user/voicebm)
# ---------------------------------------------------------------------------
for f in /app/*.py; do
    sed -i "s|/home/user/voicebm|${DATA_DIR}|g" "$f"
    sed -i "s|sys.path.insert(0, '${DATA_DIR}')|sys.path.insert(0, '/app')|g" "$f"
done

# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Start services
# ---------------------------------------------------------------------------
echo "[voicebm] Starting voicebm_stt_service..."
python3 /app/voicebm_stt_service.py &

echo "[voicebm] Starting voicebm_global_publisher..."
python3 /app/voicebm_global_publisher.py &

if [ -f /app/audio_server.py ]; then
    echo "[voicebm] Starting audio_server..."
    python3 /app/audio_server.py &
fi

if [ -f /app/enrollment_watcher.py ]; then
    echo "[voicebm] Starting enrollment_watcher..."
    python3 /app/enrollment_watcher.py &
fi

if [ -f /app/voicebm_dashboard.py ]; then
    echo "[voicebm] Starting voicebm_dashboard..."
    python3 /app/voicebm_dashboard.py &
fi

echo "[voicebm] Starting Wyoming proxy (in-process speaker ID)..."
env VOICEBM_STT_MODEL="${VOICEBM_STT_MODEL}" \
    VOICEBM_STT_LANGUAGE="${VOICEBM_STT_LANGUAGE}" \
    VOICEBM_STT_THREADS="${VOICEBM_STT_THREADS}" \
    VOICEBM_STT_MODEL_DIR="${STT_MODELS_DIR}" \
    SHERPA_MODEL="${SHERPA_MODEL}" \
    HOST_AUDIO="${HOST_AUDIO}" \
    python3 /app/voicebm_wyoming_proxy.py

wait
