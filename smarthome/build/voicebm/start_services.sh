#!/bin/bash
# The OpenAI-compatible transcription API (openai_api.py, :10302), next to
# VoiceBM itself: it forwards to VoiceBM's own Wyoming proxy (:10301).
python3 /app/openai_api.py &
exec /bin/bash /app/entrypoint.sh
