#!/usr/bin/env python3
"""
VoiceBM Configuration Generator
================================
Generates or updates config.json from environment variables.

Uses VoiceBM's official config.json.sample as the base structure, then:
  - If config.json exists: merges env vars with existing config (preserves custom settings)
  - If config.json doesn't exist: creates from sample template with env var overrides

This ensures all VoiceBM-expected fields are present with proper defaults.

Environment variables supported:
  
  VoiceBM Settings (written to config.json):
    VOICEBM_ENABLED              - Enable/disable VoiceBM (true/false)
    SHERPA_MODEL_NAME            - Speaker recognition model filename
  
  MQTT Configuration (written to config.json):
    MQTT_BROKER                  - MQTT broker hostname/IP
    MQTT_PORT                    - MQTT broker port
    MQTT_USER                    - MQTT username
    MQTT_PASS                    - MQTT password
  
  Host Configuration (written to config.json, parsed from URLs):
    HOST_URL                     - Dashboard frontend URL (e.g., http://<host-ip>:5000)
                                   Sets: dashboard.port (extracted from port in URL)
                                   Used for: determining what port the UI listens on
    HOST_AUDIO                   - Audio server URL for pending audio playback and RTSP (e.g., http://<host-ip>:9090)
                                   Sets: audio_server.host, audio_server.port, audio_server.base_url
                                   Used for: pending audio URLs, room RTSP URLs in Home Assistant
    HOME_ASSISTANT_HOST          - Home Assistant URL (e.g., http://localhost:8123)
                                   Sets: hosts.home_assistant (with default ports: 80 for http, 443 for https)
  
  Speaker Recognition Thresholds (written to config.json):
    VOICEBM_THRESHOLD_PASSIVE    - Passive speaker ID threshold (0.0-1.0, default 0.22)
    VOICEBM_THRESHOLD_ACTIVE     - Active speaker ID threshold (0.0-1.0, default 0.50)
  
  Rooms Configuration (written to config.json):
    VOICEBM_ROOMS_JSON           - Rooms config as JSON (e.g., '{"living": {...}, "bedroom": {...}}')
  
  STT Configuration (NOT written to config.json - runtime only):
    VOICEBM_STT_MODEL            - STT model name (default: cohere-transcribe)
                                   Used for: model download, Wyoming proxy configuration
    VOICEBM_STT_LANGUAGE         - STT language code (default: en)
    VOICEBM_STT_THREADS          - Number of STT threads (default: 4)

The generated config.json is used by voicebm services for runtime configuration.
"""

import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse


def get_env_int(key, default):
    """Get integer from environment variable."""
    val = os.environ.get(key)
    return int(val) if val else default


def get_env_float(key, default):
    """Get float from environment variable."""
    val = os.environ.get(key)
    return float(val) if val else default


def get_env_str(key, default=""):
    """Get string from environment variable."""
    return os.environ.get(key, default)


def get_env_bool(key, default=True):
    """Get boolean from environment variable."""
    val = os.environ.get(key, str(default)).lower()
    return val in ("true", "1", "yes", "on")


def parse_url_to_host_port(url_string):
    """
    Parse a URL string and return (host, port).
    
    Examples:
      http://10.50.60.58:9090 → ('10.50.60.58', 9090)
      https://voicebm.example → ('voicebm.example', 443)
      http://voicebm.example → ('voicebm.example', 80)
    
    Returns:
      tuple: (host, port) or (None, None) if parsing fails
    """
    try:
        parsed = urlparse(url_string)
        host = parsed.hostname
        
        if not host:
            print(f"[voicebm] WARNING: Could not parse hostname from URL: {url_string}", file=sys.stderr)
            return None, None
        
        # Use explicit port if provided, otherwise use scheme default
        if parsed.port:
            port = parsed.port
        else:
            port = 443 if parsed.scheme == "https" else 80
        
        return host, port
    except Exception as e:
        print(f"[voicebm] WARNING: Error parsing URL '{url_string}': {e}", file=sys.stderr)
        return None, None


def load_or_create_config(config_path):
    """Load existing config.json or create minimal structure."""
    config_path = Path(config_path)
    
    if config_path.exists():
        try:
            with open(config_path) as f:
                return json.load(f)
        except json.JSONDecodeError as e:
            print(f"[voicebm] WARNING: config.json is invalid JSON: {e}", file=sys.stderr)
            print(f"[voicebm] Creating new config from scratch", file=sys.stderr)
            return get_default_config()
    else:
        return get_default_config()


def get_default_config():
    """Load default config from VoiceBM's config.json.sample.
    
    This ensures we have all the expected fields and structures that VoiceBM
    expects, rather than relying on hardcoded minimal defaults.
    """
    sample_config_path = Path("/app/config.json.sample")
    
    if sample_config_path.exists():
        try:
            with open(sample_config_path) as f:
                config = json.load(f)
                print(f"[voicebm] Loaded default config from VoiceBM sample", file=sys.stderr)
                return config
        except json.JSONDecodeError as e:
            print(f"[voicebm] WARNING: config.json.sample is invalid JSON: {e}", file=sys.stderr)
            print(f"[voicebm] Falling back to minimal defaults", file=sys.stderr)
    
    # Fallback: minimal defaults if sample not found
    print(f"[voicebm] WARNING: config.json.sample not found at {sample_config_path}", file=sys.stderr)
    return {
        "mqtt": {
            "broker": "localhost",
            "port": 1883,
            "user": "",
            "password": ""
        },
        "voicebm": {
            "enabled": True,
            "sherpa_model": "nemo_en_titanet_small.onnx",
            "stt_model": "cohere-transcribe",
            "stt_language": "en",
            "stt_threads": 4
        }
    }


def update_config_from_env(config):
    """Update config dictionary with values from environment variables."""
    
    # MQTT configuration
    config.setdefault("mqtt", {})
    if os.environ.get("MQTT_BROKER"):
        config["mqtt"]["broker"] = get_env_str("MQTT_BROKER")
    if os.environ.get("MQTT_PORT"):
        config["mqtt"]["port"] = get_env_int("MQTT_PORT", 1883)
    if os.environ.get("MQTT_USER"):
        config["mqtt"]["user"] = get_env_str("MQTT_USER")
    if os.environ.get("MQTT_PASS"):
        config["mqtt"]["password"] = get_env_str("MQTT_PASS")
    
    # VoiceBM core settings
    config.setdefault("voicebm", {})
    if os.environ.get("VOICEBM_ENABLED"):
        config["voicebm"]["enabled"] = get_env_bool("VOICEBM_ENABLED", True)
    if os.environ.get("SHERPA_MODEL_NAME"):
        config["voicebm"]["sherpa_model"] = get_env_str("SHERPA_MODEL_NAME")
    
    # NOTE: VOICEBM_STT_MODEL, VOICEBM_STT_LANGUAGE, VOICEBM_STT_THREADS are NOT written to config.json
    # because they are not part of VoiceBM's official config structure.
    # They are custom for our Docker setup and used only for:
    #   1. Downloading the STT model during entrypoint
    #   2. Configuring the embedded STT in Wyoming proxy
    #   3. Preserving parallel STT + speaker ID processing when inject=disabled
    
    # Hosts configuration
    config.setdefault("hosts", {})
    
    # Parse HOME_ASSISTANT_HOST (e.g., http://localhost:8123)
    if os.environ.get("HOME_ASSISTANT_HOST"):
        ha_url = get_env_str("HOME_ASSISTANT_HOST")
        host, port = parse_url_to_host_port(ha_url)
        if host:
            config["hosts"]["home_assistant"] = host
            print(f"[voicebm] Set hosts.home_assistant from HOME_ASSISTANT_HOST: {host}", file=sys.stderr)
    
    # Dashboard configuration (port extracted from HOST_URL)
    config.setdefault("dashboard", {})
    if os.environ.get("HOST_URL"):
        host_url = get_env_str("HOST_URL")
        host, port = parse_url_to_host_port(host_url)
        if host and port:
            config["dashboard"]["port"] = port
            print(f"[voicebm] Set dashboard.port from HOST_URL: {port}", file=sys.stderr)
    
    # Audio server configuration (parsed from HOST_AUDIO)
    # HOST_AUDIO is for audio playback and RTSP streaming (separate from frontend URL)
    config.setdefault("audio_server", {})
    if os.environ.get("HOST_AUDIO"):
        host_audio = get_env_str("HOST_AUDIO")
        host, port = parse_url_to_host_port(host_audio)
        if host and port:
            config["audio_server"]["host"] = host
            config["audio_server"]["port"] = port
            config["audio_server"]["base_url"] = host_audio
            print(f"[voicebm] Set audio_server from HOST_AUDIO: {host}:{port}", file=sys.stderr)
    
    # Speaker recognition thresholds
    config.setdefault("thresholds", {})
    if os.environ.get("VOICEBM_THRESHOLD_PASSIVE"):
        config["thresholds"]["passive"] = get_env_float("VOICEBM_THRESHOLD_PASSIVE", 0.22)
    if os.environ.get("VOICEBM_THRESHOLD_ACTIVE"):
        config["thresholds"]["active"] = get_env_float("VOICEBM_THRESHOLD_ACTIVE", 0.50)
    
    # Rooms configuration (JSON)
    if os.environ.get("VOICEBM_ROOMS_JSON"):
        try:
            rooms_json = get_env_str("VOICEBM_ROOMS_JSON")
            config["rooms"] = json.loads(rooms_json)
            print(f"[voicebm] Set rooms from VOICEBM_ROOMS_JSON", file=sys.stderr)
        except json.JSONDecodeError as e:
            print(f"[voicebm] WARNING: Invalid JSON in VOICEBM_ROOMS_JSON: {e}", file=sys.stderr)
    
    return config


def main():
    """Generate or update config.json from environment variables."""
    data_dir = os.environ.get("DATA_DIR", "/data")
    config_path = Path(data_dir) / "config.json"
    
    # Load existing config or create new one
    is_new = not config_path.exists()
    config = load_or_create_config(config_path)
    
    # Update with environment variables
    config = update_config_from_env(config)
    
    # Save config
    config_path.parent.mkdir(parents=True, exist_ok=True)
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    # Log what was done
    if is_new:
        print(f"[voicebm] Created new config.json at {config_path}")
    else:
        print(f"[voicebm] Updated config.json at {config_path}")
    
    # Print current configuration (for debugging)
    print(f"[voicebm] Current configuration:")
    
    if "mqtt" in config:
        mqtt = config["mqtt"]
        print(f"[voicebm]   MQTT: {mqtt.get('broker')}:{mqtt.get('port')}")
    
    if "hosts" in config:
        hosts = config["hosts"]
        if hosts.get("home_assistant"):
            print(f"[voicebm]   Home Assistant: {hosts['home_assistant']}")
    
    if "audio_server" in config:
        audio = config["audio_server"]
        print(f"[voicebm]   Audio Server: {audio.get('base_url')}")
    
    if "dashboard" in config:
        dashboard = config["dashboard"]
        print(f"[voicebm]   Dashboard port: {dashboard.get('port', 5000)}")
    
    if "voicebm" in config:
        vb = config["voicebm"]
        print(f"[voicebm]   VoiceBM enabled: {vb.get('enabled', True)}")
        print(f"[voicebm]   Speaker model: {vb.get('sherpa_model')}")
    
    if "thresholds" in config:
        thresh = config["thresholds"]
        print(f"[voicebm]   Thresholds - Passive: {thresh.get('passive')}, Active: {thresh.get('active')}")
    
    if "rooms" in config and config["rooms"]:
        rooms = config["rooms"]
        print(f"[voicebm]   Rooms configured: {', '.join(rooms.keys())}")
    
    # STT settings are environment variables, not in config.json
    print(f"[voicebm]   STT model (env): {os.environ.get('VOICEBM_STT_MODEL', 'cohere-transcribe')}")


if __name__ == "__main__":
    main()
