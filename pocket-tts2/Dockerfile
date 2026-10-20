FROM python:3.11-slim

RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

# Install CPU-only torch first (pocket-tts requires torch 2.5+, GPU not needed)
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

# pocket-tts git main (2026-10-20): 3.3.0 + english_2026-09_2 (not in a release yet)
ARG POCKET_TTS_REF=28c604373ffc5cf1ae71734b988d944ec6b8e040
RUN pip install --no-cache-dir \
    "pocket-tts @ https://github.com/kyutai-labs/pocket-tts/archive/${POCKET_TTS_REF}.tar.gz" \
    wyoming \
    safetensors \
    zeroconf \
    flask \
    flask-cors \
    soundfile

WORKDIR /data
