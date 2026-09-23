FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    tar \
    bzip2 \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (including sherpa-onnx for embedded STT)
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
        sherpa-onnx \
        paho-mqtt \
        flask \
        flask-cors \
        watchdog \
        numpy \
        wyoming

# Fetch VoiceBM v2 (main branch, pinned) and copy the runtime scripts we use.
# Pinned commit 84ad28b (2026-06-17) includes the Active 2.1 fixes:
#   - dashboard enroll/reject now publish MQTT (was TODO stubs in v1/v2.0)
#   - pending.json list/dict normalization
#   - inject_identity wired to config.json as single source of truth
#   - global-scope topics (voicebm/current_speaker, transcript/debug+preferred)
# The old dashboard_patches.py + inline entrypoint patches are no longer needed.
ARG VOICEBM_SHA=84ad28b3257f
RUN curl -fsSL "https://codeload.github.com/cybericebyte/VoiceBM/tar.gz/${VOICEBM_SHA}" -o /tmp/vbm.tgz && \
    tar xzf /tmp/vbm.tgz -C /tmp && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/sherpa_embed.py            /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/voicebm_config.py          /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/voicebm_stt_service.py     /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/voicebm_global_publisher.py /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/audio_server.py            /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/enrollment_watcher.py      /app/ && \
    cp /tmp/VoiceBM-${VOICEBM_SHA}/VoiceBM/bin/voicebm_dashboard.py       /app/ && \
    rm -rf /tmp/VoiceBM-* /tmp/vbm.tgz

# The dashboard hardcodes app.run(host='0.0.0.0', port=5000, debug=True): on a
# host-network container that is the whole LAN, with no login and Werkzeug's
# interactive debugger on. Listen where VOICEBM_DASHBOARD_HOST says instead
# (compose.yml: the Docker bridge, which only Traefik — and so authentik —
# reaches), without the debugger. Fails the build if an upstream bump changes
# that line, rather than quietly shipping the open version again.
RUN grep -q "app.run(host='0.0.0.0', port=5000, debug=True)" /app/voicebm_dashboard.py && \
    sed -i "s/app.run(host='0.0.0.0', port=5000, debug=True)/app.run(host=os.environ.get('VOICEBM_DASHBOARD_HOST', '127.0.0.1'), port=int(os.environ.get('VOICEBM_DASHBOARD_PORT', '5000')), debug=False)/" /app/voicebm_dashboard.py && \
    grep -q "VOICEBM_DASHBOARD_HOST" /app/voicebm_dashboard.py

# Copy our scripts (built into the image at build time)
COPY voicebm_wyoming_proxy.py /app/voicebm_wyoming_proxy.py
COPY voicebm_stt_engine.py /app/voicebm_stt_engine.py
COPY voicebm_stt_model_registry.py /app/voicebm_stt_model_registry.py
COPY config_generator.py /app/config_generator.py
COPY config.json.sample /app/config.json.sample
COPY entrypoint.sh /app/entrypoint.sh
# The OpenAI-compatible transcription API and the script that starts it next
# to VoiceBM. On station these lived in the data directory; baked in here, so
# /data is only data.
COPY openai_api.py /app/openai_api.py
COPY start_services.sh /app/start_services.sh
RUN chmod +x /app/entrypoint.sh /app/config_generator.py /app/start_services.sh

# Data directory (mounted from host)
RUN mkdir -p /data

ENTRYPOINT ["/bin/bash", "/app/start_services.sh"]
