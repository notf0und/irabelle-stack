#!/bin/bash
echo "=== pocket-tts2 (2.1.0) ==="
echo "  Wyoming  : ${POCKET_TTS_WYOMING_PORT:-10215}"
echo "  Voice    : ${POCKET_TTS_VOICE:-alba}"
echo "  Language : ${POCKET_TTS_LANGUAGE:-english}"
echo "  Zeroconf : ${POCKET_TTS_ZEROCONF:-pocket-tts2}"
echo "  API port : ${POCKET_TTS_API_PORT:-10216}"

python3 /data/wyoming_server.py &
WYOMING_PID=$!

sleep 3

python3 /data/openai_api.py &
API_PID=$!

shutdown() {
    echo "Shutting down..."
    kill $WYOMING_PID $API_PID 2>/dev/null
    wait $WYOMING_PID $API_PID 2>/dev/null
    exit 0
}
trap shutdown SIGTERM SIGINT

echo "Services running. Waiting..."
wait -n
shutdown
