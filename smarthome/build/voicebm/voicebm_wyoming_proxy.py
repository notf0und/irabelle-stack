#!/usr/bin/env python3
"""VoiceBM Wyoming Proxy with Embedded STT + In-Process Speaker ID.

VoiceBM handles both:
1. Speaker identification (Sherpa-ONNX SpeakerEmbeddingExtractor, in-process)
2. Speech-to-text transcription (embedded Sherpa-ONNX offline recognizer)

This makes voicebm completely self-contained — no dependency on external
parakeet/sherpa-onnx-asr services, and no MQTT round-trip for speaker ID.

Optimization summary vs original:
  - Eliminated: disk write before speaker ID, subprocess spawn (~200-500ms),
    MQTT round-trip with 20s timeout
  - Added: in-process SpeakerEmbeddingExtractor (same sherpa-onnx library),
    async WAV write AFTER processing (enrollment UI unaffected),
    Phase 2 early speaker ID after ~1.5s of audio chunks

Flow:
  HA → voicebm:10301 → [in-process speaker ID + embedded STT in parallel] → transcript
                                                                                  ↓
                                                          publishes to voicebm/living/current_speaker
                                                          (HA reads this for personalized intents)

STT model selection via environment variables:
  VOICEBM_STT_MODEL    - Model name (default: cohere-transcribe)
  VOICEBM_STT_LANGUAGE - Language code (default: en)
  VOICEBM_STT_THREADS  - CPU threads (default: 4)

Speaker ID model via environment variable:
  SHERPA_MODEL         - Full path to .onnx model (default: /data/models/nemo_en_titanet_small.onnx)

All settings come from environment variables in docker-compose.yml.
To change: update docker-compose.yml → docker-compose up -d --force-recreate voicebm
"""

import asyncio
import concurrent.futures
import json
import logging
import os
import sys
import time
import uuid
import wave
from pathlib import Path
from typing import Optional

import numpy as np
import paho.mqtt.client as mqtt
import sherpa_onnx
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.asr import Transcribe, Transcript
from wyoming.event import Event
from wyoming.info import Describe, Info, AsrModel, AsrProgram, Attribution
from wyoming.server import AsyncEventHandler, AsyncServer

# Import embedded STT engine
sys.path.insert(0, "/app")
import voicebm_stt_engine

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
_LOGGER = logging.getLogger("voicebm.proxy")

# ---------------------------------------------------------------------------
# Configuration (all from docker-compose.yml environment section)
# ---------------------------------------------------------------------------
VOICEBM_WYOMING_PORT   = int(os.getenv("VOICEBM_WYOMING_PORT", "10301"))
VOICEBM_SERVICE_NAME   = "voicebm"
MQTT_BROKER            = os.getenv("MQTT_BROKER", "localhost")
MQTT_PORT              = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER              = os.getenv("MQTT_USER", "")
MQTT_PASS              = os.getenv("MQTT_PASS", "")
SHARED_AUDIO_DIR       = os.getenv("SHARED_AUDIO_DIR", "/data/stt_requests")
SETTINGS_FILE          = "/data/meta/settings.json"
THRESHOLD_FILE         = "/data/out/thresholds.json"
ENROLL_DIR             = "/data/enroll"
PENDING_DIR            = "/data/pending_active"
HOST_AUDIO             = os.getenv("HOST_AUDIO", "http://localhost:9090")

# STT configuration (embedded engine)
VOICEBM_STT_MODEL      = os.getenv("VOICEBM_STT_MODEL", "cohere-transcribe")
VOICEBM_STT_LANGUAGE   = os.getenv("VOICEBM_STT_LANGUAGE", "en")
VOICEBM_STT_THREADS    = int(os.getenv("VOICEBM_STT_THREADS", "4"))
VOICEBM_STT_MODEL_DIR  = os.getenv("VOICEBM_STT_MODEL_DIR", "/data/stt-models")

# Speaker ID configuration
SHERPA_MODEL           = os.getenv("SHERPA_MODEL", "/data/models/nemo_en_titanet_small.onnx")
DEFAULT_THRESHOLD      = 0.50
EARLY_SPEAKER_ID_SECS  = 1.5   # kick off early speaker ID after this many seconds of audio
PENDING_BUFFER_SIZE    = 5
PENDING_EXPIRE_HOURS   = 1

# VoiceBM 2.x MQTT contract (global scope):
#   voicebm/current_speaker       - JSON {speaker_id, display_name, confidence}
#   voicebm/transcript/debug      - raw transcript JSON w/ identity (always published)
#   voicebm/transcript/preferred  - gate-checked plain text (empty when blocked)
#   voicebm/active/identity       - full identity verdict JSON
MQTT_TOPICS = {
    "current_speaker": "voicebm/current_speaker",
    "transcript_debug":   "voicebm/transcript/debug",
    "transcript_preferred": "voicebm/transcript/preferred",
    "active_identity": "voicebm/active/identity",
    "active_event_id": "voicebm/active/current_event_id",
    "pending":         "voicebm/pending_active",
    "pending_cur_id":  "voicebm/pending_active/current_id",
    "pending_audio":   "voicebm/pending_active/audio_url",
}

# ---------------------------------------------------------------------------
# Global singletons (initialised in main())
# ---------------------------------------------------------------------------
_STT_ENGINE: Optional[object] = None
_SPEAKER_EXTRACTOR: Optional[sherpa_onnx.SpeakerEmbeddingExtractor] = None
_GALLERY: dict = {}          # {(person_id, display_name): centroid_np_array}
_BLOCKED: set = set()        # person_ids on blocklist (populated via MQTT)
_INJECT_ENABLED: bool = True # inject_identity toggle (from MQTT)
_PERSON_THRESHOLDS: dict = {}  # per-person threshold overrides


# ---------------------------------------------------------------------------
# Gallery helpers
# ---------------------------------------------------------------------------

def load_gallery() -> dict:
    """Load enrolled speakers from /data/enroll and compute per-person centroids."""
    enroll_path = Path(ENROLL_DIR)
    if not enroll_path.exists():
        _LOGGER.warning("Enrollment directory not found: %s", ENROLL_DIR)
        return {}

    people: dict = {}
    try:
        for person_dir in enroll_path.iterdir():
            if not person_dir.is_dir():
                continue
            person_id = person_dir.name
            embeddings_dir = person_dir / "embeddings"
            metadata_file = person_dir / "metadata.json"

            display_name = person_id.replace("_", " ").title()
            if metadata_file.exists():
                try:
                    with open(metadata_file) as f:
                        display_name = json.load(f).get("display_name", display_name)
                except Exception:
                    pass

            if not embeddings_dir.exists():
                continue

            vectors = []
            for emb_file in embeddings_dir.glob("*.txt"):
                try:
                    v = np.loadtxt(emb_file)
                    if v is not None and len(v) > 0:
                        vectors.append(v)
                except Exception as exc:
                    _LOGGER.debug("Skip bad embedding %s: %s", emb_file.name, exc)

            if vectors:
                centroid = np.mean(vectors, axis=0)
                people[(person_id, display_name)] = centroid

    except Exception as exc:
        _LOGGER.error("Error loading gallery: %s", exc)
        return {}

    _LOGGER.info("Gallery loaded: %d enrolled speakers", len(people))
    return people


def _cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if na == 0 or nb == 0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def _get_threshold() -> float:
    """Read MATCH_T_ACTIVE from thresholds.json, fall back to DEFAULT_THRESHOLD."""
    try:
        if os.path.exists(THRESHOLD_FILE):
            with open(THRESHOLD_FILE) as f:
                return float(json.load(f).get("MATCH_T_ACTIVE", DEFAULT_THRESHOLD))
    except Exception:
        pass
    return DEFAULT_THRESHOLD


def _raw_to_f32(raw: bytes, width: int, channels: int) -> np.ndarray:
    """Convert raw PCM bytes → float32 mono numpy array."""
    if width == 2:
        pcm = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif width == 4:
        pcm = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unsupported sample width: {width}")
    if channels > 1:
        pcm = pcm.reshape(-1, channels).mean(axis=1)
    return pcm


def _compute_embedding(raw_audio: bytes, rate: int, width: int, channels: int) -> Optional[np.ndarray]:
    """Compute speaker embedding from raw PCM bytes (runs in thread executor)."""
    global _SPEAKER_EXTRACTOR
    if _SPEAKER_EXTRACTOR is None:
        return None
    try:
        pcm = _raw_to_f32(raw_audio, width, channels)
        stream = _SPEAKER_EXTRACTOR.create_stream()
        stream.accept_waveform(rate, pcm)
        stream.input_finished()
        emb = _SPEAKER_EXTRACTOR.compute(stream)
        return np.array(emb)
    except Exception as exc:
        _LOGGER.error("Embedding computation failed: %s", exc)
        return None


def _identify_speaker_inline(
    raw_audio: bytes, rate: int, width: int, channels: int
) -> tuple:
    """
    In-process speaker identification. No disk I/O, no subprocess, no MQTT.

    Returns (speaker_id, display_name, confidence, inject_enabled, is_blocked, embedding).
    Falls back to ("unknown", "unknown", 0.0, True, False, None) on error.
    """
    global _GALLERY, _BLOCKED, _INJECT_ENABLED, _PERSON_THRESHOLDS

    embedding = _compute_embedding(raw_audio, rate, width, channels)
    if embedding is None:
        return "unknown", "unknown", 0.0, _INJECT_ENABLED, False, None

    threshold = _get_threshold()
    gallery = _GALLERY  # snapshot reference (safe: dict replaced atomically on reload)

    best_sid = None
    best_name = None
    best_sim = -1.0

    for (person_id, display_name), centroid in gallery.items():
        sim = _cosine_similarity(embedding, centroid)
        if sim > best_sim:
            best_sim = sim
            best_sid = person_id
            best_name = display_name

    # Apply global threshold
    if best_sim < threshold:
        _LOGGER.info("No match (best=%.4f < threshold=%.2f)", best_sim, threshold)
        best_sid = None
        best_name = None

    # Apply per-person threshold override
    if best_sid and best_sid in _PERSON_THRESHOLDS:
        custom = _PERSON_THRESHOLDS[best_sid]
        if best_sim < custom:
            _LOGGER.info(
                "Custom threshold FAILED for %s: %.4f < %.2f", best_sid, best_sim, custom
            )
            best_sid = None
            best_name = None

    # Blocklist check (map unknown → "user" virtual ID, same as voicebm_stt_service)
    effective_id = best_sid if best_sid else "user"
    is_blocked = effective_id in _BLOCKED

    speaker_id = best_sid if best_sid else "unknown"
    display_name = best_name if best_name else "unknown"
    confidence = best_sim if best_sim > 0 else 0.0

    _LOGGER.info(
        "Speaker: %r conf=%.3f blocked=%s inject=%s",
        display_name, confidence, is_blocked, _INJECT_ENABLED,
    )
    return speaker_id, display_name, confidence, _INJECT_ENABLED, is_blocked, embedding


# ---------------------------------------------------------------------------
# Settings helpers
# ---------------------------------------------------------------------------

def get_inject_identity_setting() -> bool:
    """Read inject_identity from config.json (VoiceBM 2.x single source of
    truth, shared with the dashboard and HA), falling back to the legacy
    settings.json mirror. Default True."""
    try:
        sys.path.insert(0, "/app")
        from voicebm_config import get_inject_identity
        return bool(get_inject_identity())
    except Exception:
        pass
    try:
        if os.path.exists(SETTINGS_FILE):
            with open(SETTINGS_FILE) as f:
                return bool(json.load(f).get("inject_identity", True))
    except Exception as exc:
        _LOGGER.warning("Failed to read settings: %s", exc)
    return True


# ---------------------------------------------------------------------------
# MQTT helpers (publish-only, fire-and-forget)
# ---------------------------------------------------------------------------

def _make_mqtt_client() -> mqtt.Client:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    if MQTT_USER:
        client.username_pw_set(MQTT_USER, MQTT_PASS)
    return client


def publish_speaker_state(
    speaker_id: str, display_name: str, confidence: float, transcript: str,
    request_id: str
) -> None:
    """Publish current speaker + transcript + active identity to MQTT for HA sensors."""
    try:
        client = _make_mqtt_client()
        client.connect(MQTT_BROKER, MQTT_PORT, 60)
        client.loop_start()

        client.publish(MQTT_TOPICS["current_speaker"], json.dumps({
            "speaker_id": speaker_id,
            "display_name": display_name,
            "confidence": round(confidence, 4),
        }), qos=1, retain=True)

        if transcript:
            # VoiceBM 2.x: raw diagnostic feed (JSON w/ identity) + gated plain text
            client.publish(MQTT_TOPICS["transcript_debug"], json.dumps({
                "speaker": display_name,
                "text": transcript,
                "timestamp": time.time(),
            }), qos=1, retain=True)
            client.publish(MQTT_TOPICS["transcript_preferred"], transcript, qos=1, retain=True)

        decision = "accepted" if speaker_id not in ("unknown", "") else "unknown"
        client.publish(MQTT_TOPICS["active_identity"], json.dumps({
            "speaker_id": speaker_id,
            "display_name": display_name if display_name not in ("unknown", "") else "Unknown",
            "confidence": round(confidence, 4),
            "decision": decision,
            "score": round(confidence, 4),
        }), qos=1, retain=True)
        client.publish(MQTT_TOPICS["active_event_id"], request_id, qos=1, retain=True)

        # Binary sensor ON for identified speaker
        if speaker_id not in ("unknown", ""):
            client.publish(f"{speaker_id}/voice", "ON", qos=1, retain=True)
            # Attributes
            enroll_dir = Path(ENROLL_DIR) / speaker_id / "embeddings"
            gallery_size = len(list(enroll_dir.glob("*.txt"))) if enroll_dir.exists() else 0
            client.publish(f"{speaker_id}/voice/attributes", json.dumps({
                "confidence": round(confidence, 4),
                "source": "active",
                "gallery_size": gallery_size,
                "last_updated": time.strftime("%Y-%m-%d %H:%M:%S"),
            }), qos=1, retain=True)

        time.sleep(0.1)
        client.loop_stop()
        client.disconnect()
    except Exception as exc:
        _LOGGER.warning("Failed to publish speaker state: %s", exc)


def _write_wav_sync(audio_path: str, chunks: list, rate: int, width: int, channels: int) -> None:
    """Write WAV file synchronously (called from thread executor)."""
    try:
        Path(audio_path).parent.mkdir(parents=True, exist_ok=True)
        with wave.open(audio_path, "wb") as wf:
            wf.setnchannels(channels)
            wf.setsampwidth(width)
            wf.setframerate(rate)
            for chunk in chunks:
                wf.writeframes(chunk.audio)
    except Exception as exc:
        _LOGGER.warning("Failed to write WAV %s: %s", audio_path, exc)


def _add_to_pending_sync(
    audio_path: str, embedding: Optional[np.ndarray], request_id: str
) -> None:
    """
    Add recording to pending_active buffer for enrollment UI.
    Mirrors voicebm_stt_service logic but runs in-process after audio is processed.
    """
    import datetime, shutil
    pending_recordings = Path(PENDING_DIR) / "recordings"
    pending_embeddings = Path(PENDING_DIR) / "embeddings"
    pending_json = Path(PENDING_DIR) / "pending.json"

    try:
        pending_recordings.mkdir(parents=True, exist_ok=True)
        pending_embeddings.mkdir(parents=True, exist_ok=True)

        # Load buffer
        buffer = []
        if pending_json.exists():
            try:
                buffer = json.loads(pending_json.read_text())
                if not isinstance(buffer, list):
                    buffer = buffer.get("entries", [])
            except Exception:
                buffer = []

        # Expire old entries
        now_ts = time.time()
        expire_sec = PENDING_EXPIRE_HOURS * 3600
        valid = []
        for e in buffer:
            if now_ts - e.get("timestamp", 0) < expire_sec:
                valid.append(e)
            else:
                for suffix, d in [(".wav", pending_recordings), (".txt", pending_embeddings)]:
                    p = d / f"{e['id']}{suffix}"
                    if p.exists():
                        p.unlink(missing_ok=True)
        buffer = valid

        pending_id = f"active_{int(time.time() * 1000)}"
        wav_dst = pending_recordings / f"{pending_id}.wav"
        emb_dst = pending_embeddings / f"{pending_id}.txt"

        # Copy WAV (already written to SHARED_AUDIO_DIR by this point)
        if os.path.exists(audio_path):
            shutil.copy2(audio_path, wav_dst)
        else:
            _LOGGER.warning("Pending: source WAV not found: %s", audio_path)
            return

        if embedding is not None:
            np.savetxt(emb_dst, embedding)

        entry = {
            "id": pending_id,
            "request_id": request_id,
            "timestamp": time.time(),
            "ts_iso": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
            "audio_url": f"{HOST_AUDIO}/pending/{pending_id}.wav",
            "source": "active_node",
        }
        buffer.append(entry)

        # Trim to max size
        while len(buffer) > PENDING_BUFFER_SIZE:
            removed = buffer.pop(0)
            for suffix, d in [(".wav", pending_recordings), (".txt", pending_embeddings)]:
                p = d / f"{removed['id']}{suffix}"
                p.unlink(missing_ok=True)

        pending_json.write_text(json.dumps(buffer, indent=2))
        _LOGGER.info("Added to pending buffer: %s (size=%d)", pending_id, len(buffer))

        # Publish pending status via MQTT
        _publish_pending_status(buffer)

    except Exception as exc:
        _LOGGER.warning("Failed to add to pending buffer: %s", exc, exc_info=True)


def _publish_pending_status(buffer: list) -> None:
    """Publish pending buffer count/current to MQTT."""
    try:
        client = _make_mqtt_client()
        client.connect(MQTT_BROKER, MQTT_PORT, 60)
        client.loop_start()

        payload = {
            "count": len(buffer),
            "max_size": PENDING_BUFFER_SIZE,
            "expire_hours": PENDING_EXPIRE_HOURS,
            "entries": buffer,
        }
        client.publish(MQTT_TOPICS["pending"], json.dumps(payload), qos=1, retain=True)

        if buffer:
            current = buffer[-1]
            client.publish(MQTT_TOPICS["pending_cur_id"], current.get("id", ""), qos=1, retain=True)
            client.publish(MQTT_TOPICS["pending_audio"], current.get("audio_url", ""), qos=1, retain=True)
        else:
            client.publish(MQTT_TOPICS["pending_cur_id"], "none", qos=1, retain=True)
            client.publish(MQTT_TOPICS["pending_audio"], "", qos=1, retain=True)

        time.sleep(0.1)
        client.loop_stop()
        client.disconnect()
    except Exception as exc:
        _LOGGER.warning("Failed to publish pending status: %s", exc)


# ---------------------------------------------------------------------------
# Wyoming proxy handler (one instance per HA connection)
# ---------------------------------------------------------------------------

class VoiceBMProxyHandler(AsyncEventHandler):

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._audio_chunks: list[AudioChunk] = []
        self._rate: int = 16000
        self._width: int = 2
        self._channels: int = 1
        self._language: Optional[str] = None
        self._request_id: str = str(uuid.uuid4())

        # Phase 2: early speaker ID state
        self._early_speaker_task: Optional[asyncio.Task] = None
        self._early_speaker_result: Optional[tuple] = None
        self._early_speaker_started: bool = False
        self._accumulated_audio_secs: float = 0.0

        Path(SHARED_AUDIO_DIR).mkdir(parents=True, exist_ok=True)

    async def _safe_write(self, event: Event) -> None:
        """Write an event, tolerating a client that disconnected mid-request.

        Clients (HA pipeline, test scripts) may close the socket while STT is
        still processing long audio. The final Transcript write then fails with
        ConnectionResetError — log it at info level instead of letting it
        escape into the unretrieved asyncio task. The transcript was already
        persisted to the pending buffer and MQTT before this write.
        """
        try:
            await self.write_event(event)
        except (ConnectionResetError, BrokenPipeError, OSError) as exc:
            _LOGGER.info("Client disconnected while writing %s event: %s", event.type, exc)

    async def run(self) -> None:
        """Run the event loop, tolerating client disconnects.

        wyoming's AsyncEventHandler.run() lets ConnectionResetError escape when
        a client aborts mid-request (read OR write), and AsyncServer never
        retrieves the task exception — asyncio then logs a spurious ERROR. The
        base run() already tears down the connection in its finally block, so
        we only need to swallow the exception here.
        """
        try:
            await super().run()
        except (ConnectionResetError, BrokenPipeError, OSError) as exc:
            _LOGGER.info("Wyoming client connection ended: %s", exc)

    async def handle_event(self, event: Event) -> bool:
        if Describe.is_type(event.type):
            try:
                info = Info(
                    asr=[
                        AsrProgram(
                            name=VOICEBM_SERVICE_NAME,
                            description="VoiceBM (embedded STT + in-process speaker ID)",
                            version="1.0",
                            attribution=Attribution(
                                name="VoiceBM + sherpa-onnx",
                                url="https://github.com/cybericebyte/VoiceBM",
                            ),
                            installed=True,
                            models=[
                                AsrModel(
                                    name=VOICEBM_STT_MODEL,
                                    description=VOICEBM_STT_MODEL,
                                    version="1.0",
                                    attribution=Attribution(
                                        name="k2-fsa", url="https://github.com/k2-fsa/sherpa-onnx"
                                    ),
                                    installed=True,
                                    languages=[VOICEBM_STT_LANGUAGE],
                                )
                            ],
                        )
                    ]
                )
                await self._safe_write(info.event())
            except Exception as exc:
                _LOGGER.warning("Error building Describe response: %s", exc)
            return True

        if Transcribe.is_type(event.type):
            self._language = Transcribe.from_event(event).language
            return True

        if AudioStart.is_type(event.type):
            a = AudioStart.from_event(event)
            self._rate, self._width, self._channels = a.rate, a.width, a.channels
            self._audio_chunks = []
            self._accumulated_audio_secs = 0.0
            self._early_speaker_task = None
            self._early_speaker_result = None
            self._early_speaker_started = False
            self._request_id = str(uuid.uuid4())
            return True

        if AudioChunk.is_type(event.type):
            chunk = AudioChunk.from_event(event)
            self._audio_chunks.append(chunk)
            # Track accumulated duration for Phase 2 early trigger
            samples = len(chunk.audio) // self._width // self._channels
            self._accumulated_audio_secs += samples / self._rate
            # Phase 2: kick off early speaker ID once we have enough audio
            if (
                not self._early_speaker_started
                and self._accumulated_audio_secs >= EARLY_SPEAKER_ID_SECS
            ):
                self._early_speaker_started = True
                self._early_speaker_task = asyncio.create_task(
                    self._run_early_speaker_id()
                )
            return True

        if AudioStop.is_type(event.type):
            try:
                await self._process_audio()
            except (ConnectionResetError, BrokenPipeError, OSError) as exc:
                _LOGGER.info("Client disconnected during audio processing: %s", exc)
            except Exception as exc:
                _LOGGER.warning("Error processing audio: %s", exc, exc_info=True)
            return True

        return True

    async def _run_early_speaker_id(self) -> None:
        """Phase 2: run speaker ID on audio accumulated so far (background task)."""
        try:
            raw_audio = b"".join(c.audio for c in self._audio_chunks)
            loop = asyncio.get_running_loop()
            result = await loop.run_in_executor(
                None,
                _identify_speaker_inline,
                raw_audio, self._rate, self._width, self._channels,
            )
            self._early_speaker_result = result
            _LOGGER.debug(
                "Early speaker ID complete: %s (%.1fs of audio)",
                result[1], self._accumulated_audio_secs,
            )
        except Exception as exc:
            _LOGGER.warning("Early speaker ID failed: %s", exc)

    async def _process_audio(self) -> None:
        if not self._audio_chunks:
            await self._safe_write(Transcript(text="").event())
            return

        loop = asyncio.get_running_loop()
        request_id = self._request_id
        filename = f"{request_id}.wav"
        audio_path = os.path.join(SHARED_AUDIO_DIR, filename)

        # Combine audio now (used for both STT and speaker ID)
        raw_audio = b"".join(c.audio for c in self._audio_chunks)

        # If early speaker ID is still running, wait for it (it should be nearly done)
        # Otherwise run speaker ID fresh on full audio
        if self._early_speaker_task is not None and not self._early_speaker_task.done():
            _LOGGER.debug("Waiting for early speaker ID task...")
            try:
                await asyncio.wait_for(self._early_speaker_task, timeout=5.0)
            except asyncio.TimeoutError:
                _LOGGER.warning("Early speaker ID timed out, running fresh")
                self._early_speaker_result = None

        if self._early_speaker_result is not None:
            # Phase 2: use early result (avoids redundant inference)
            speaker_result = self._early_speaker_result
            # Re-run on full audio if utterance is significantly longer than early window
            # (adds very little overhead — only if there's meaningfully more audio)
            extra_secs = self._accumulated_audio_secs - EARLY_SPEAKER_ID_SECS
            if extra_secs > 1.0:
                _LOGGER.debug(
                    "Utterance %.1fs, re-running speaker ID on full audio (extra=%.1fs)",
                    self._accumulated_audio_secs, extra_secs,
                )
                speaker_result = await loop.run_in_executor(
                    None,
                    _identify_speaker_inline,
                    raw_audio, self._rate, self._width, self._channels,
                )
        else:
            # No early result — run on full audio now (in parallel with STT)
            speaker_result = None

        # Run STT and (if needed) speaker ID in parallel
        if speaker_result is None:
            speaker_result, transcript = await asyncio.gather(
                loop.run_in_executor(
                    None,
                    _identify_speaker_inline,
                    raw_audio, self._rate, self._width, self._channels,
                ),
                self._get_embedded_transcript(raw_audio),
            )
        else:
            transcript = await self._get_embedded_transcript(raw_audio)

        speaker_id, display_name, confidence, inject_enabled, is_blocked, embedding = speaker_result

        _LOGGER.info(
            "Speaker: %r conf=%.3f blocked=%s duration=%.1fs",
            display_name, confidence, is_blocked, self._accumulated_audio_secs,
        )

        if is_blocked:
            _LOGGER.info("Blocked speaker %r — returning empty transcript", display_name)
            await self._safe_write(Transcript(text="").event())
            # Still write WAV async (enrollment UI needs it even for blocked speakers)
            chunks_snap = list(self._audio_chunks)
            r, w, ch = self._rate, self._width, self._channels
            async def _blocked_save():
                await loop.run_in_executor(None, _write_wav_sync, audio_path, chunks_snap, r, w, ch)
            asyncio.create_task(_blocked_save())
            return

        # Prepend speaker name if injection enabled
        inject_speaker = get_inject_identity_setting()
        if (
            inject_speaker
            and inject_enabled
            and speaker_id not in ("unknown", "")
            and display_name not in ("unknown", "", None)
        ):
            final_text = f"{display_name}: {transcript}"
        else:
            final_text = transcript

        # Publish speaker state to MQTT BEFORE the transcript reaches HA, so
        # intents reading sensor.voicebm_current_speaker always see a fresh state
        # (fire-and-forget-after could serve a stale sensor to a racing intent).
        await loop.run_in_executor(
            None,
            publish_speaker_state,
            speaker_id, display_name, confidence, final_text, request_id,
        )

        _LOGGER.info("Transcript: %r", final_text)
        await self._safe_write(Transcript(text=final_text).event())

        # --- Fire-and-forget async tasks (non-blocking) ---

        # 1. Write WAV to disk (for enrollment UI)
        chunks_snapshot = list(self._audio_chunks)
        rate, width, channels = self._rate, self._width, self._channels

        async def _save_and_add_pending():
            await loop.run_in_executor(
                None, _write_wav_sync, audio_path, chunks_snapshot, rate, width, channels
            )
            await loop.run_in_executor(
                None, _add_to_pending_sync, audio_path, embedding, request_id
            )

        asyncio.create_task(_save_and_add_pending())

    async def _get_embedded_transcript(self, raw_audio: bytes) -> str:
        """Recognize speech using embedded STT engine."""
        if not raw_audio or not _STT_ENGINE:
            return ""
        try:
            loop = asyncio.get_running_loop()
            text = await loop.run_in_executor(
                None, _STT_ENGINE.recognize, raw_audio, self._rate
            )
            return text
        except Exception as exc:
            _LOGGER.error("Embedded STT error: %s", exc, exc_info=True)
            return ""


# ---------------------------------------------------------------------------
# MQTT background listener (blocklist + inject toggle + gallery reload)
# ---------------------------------------------------------------------------

def _start_mqtt_listener() -> None:
    """Start a background MQTT client to receive blocklist/inject toggle updates."""
    global _BLOCKED, _INJECT_ENABLED, _GALLERY

    def on_connect(client, userdata, flags, rc, properties=None):
        if rc == 0:
            client.subscribe("voicebm/blocklist/+", qos=1)
            client.subscribe("voicebm/inject_identity", qos=1)
            client.subscribe("voicebm/gallery/reload", qos=1)
            _LOGGER.info("MQTT listener subscribed (blocklist, inject toggle, gallery reload)")
        else:
            _LOGGER.warning("MQTT listener connect failed: rc=%s", rc)

    def on_message(client, userdata, msg):
        global _BLOCKED, _INJECT_ENABLED, _GALLERY
        topic = msg.topic
        payload = msg.payload.decode("utf-8", errors="replace").strip()

        if topic.startswith("voicebm/blocklist/"):
            person_id = topic.split("/")[2]
            if payload == "ON":
                _BLOCKED.add(person_id)
                _LOGGER.info("Blocklist: added %s", person_id)
            else:
                _BLOCKED.discard(person_id)
                _LOGGER.info("Blocklist: removed %s", person_id)

        elif topic == "voicebm/inject_identity":
            _INJECT_ENABLED = (payload == "ON")
            _LOGGER.info("Inject identity: %s", _INJECT_ENABLED)

        elif topic == "voicebm/gallery/reload":
            _LOGGER.info("Gallery reload requested via MQTT")
            _GALLERY = load_gallery()

    client = _make_mqtt_client()
    client.on_connect = on_connect
    client.on_message = on_message

    def _run():
        while True:
            try:
                client.connect(MQTT_BROKER, MQTT_PORT, 60)
                client.loop_forever()
            except Exception as exc:
                _LOGGER.warning("MQTT listener error: %s — retrying in 10s", exc)
                time.sleep(10)

    import threading
    t = threading.Thread(target=_run, daemon=True, name="mqtt-listener")
    t.start()
    _LOGGER.info("MQTT background listener started")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main() -> None:
    global _STT_ENGINE, _SPEAKER_EXTRACTOR, _GALLERY

    _LOGGER.info(
        "VoiceBM Proxy  port=%d  STT=%s  speaker_model=%s",
        VOICEBM_WYOMING_PORT, VOICEBM_STT_MODEL, SHERPA_MODEL,
    )

    # Initialize embedded STT engine
    try:
        _STT_ENGINE = voicebm_stt_engine.init_stt_engine(
            model_name=VOICEBM_STT_MODEL,
            model_dir=VOICEBM_STT_MODEL_DIR,
            language=VOICEBM_STT_LANGUAGE,
            num_threads=VOICEBM_STT_THREADS,
        )
        _LOGGER.info("Embedded STT engine ready")
    except Exception as exc:
        _LOGGER.error("Failed to initialize STT engine: %s", exc)
        raise

    # Initialize in-process speaker embedding extractor
    if os.path.exists(SHERPA_MODEL):
        try:
            cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=SHERPA_MODEL,
                num_threads=2,
                debug=False,
            )
            _SPEAKER_EXTRACTOR = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)
            _LOGGER.info("In-process speaker extractor ready: %s", SHERPA_MODEL)
        except Exception as exc:
            _LOGGER.error("Failed to load speaker model %s: %s", SHERPA_MODEL, exc)
            _LOGGER.warning("Speaker ID will be disabled (all speakers = unknown)")
    else:
        _LOGGER.warning("Speaker model not found: %s — speaker ID disabled", SHERPA_MODEL)

    # Load gallery
    _GALLERY = load_gallery()

    # Start MQTT background listener (blocklist / inject toggle / gallery reload)
    _start_mqtt_listener()

    inject_status = get_inject_identity_setting()
    _LOGGER.info("Speaker injection=%s (from %s)", inject_status, SETTINGS_FILE)
    _LOGGER.info("Early speaker ID trigger: %.1fs of audio", EARLY_SPEAKER_ID_SECS)

    server = AsyncServer.from_uri(f"tcp://0.0.0.0:{VOICEBM_WYOMING_PORT}")
    _LOGGER.info("Ready")
    await server.run(VoiceBMProxyHandler)


if __name__ == "__main__":
    asyncio.run(main())
