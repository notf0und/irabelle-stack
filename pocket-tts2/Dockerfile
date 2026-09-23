FROM python:3.11-slim

RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

# Install CPU-only torch first (pocket-tts requires torch 2.5+, GPU not needed)
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

RUN pip install --no-cache-dir \
    pocket-tts==2.1.0 \
    wyoming \
    safetensors \
    zeroconf \
    flask \
    flask-cors \
    soundfile

WORKDIR /data
