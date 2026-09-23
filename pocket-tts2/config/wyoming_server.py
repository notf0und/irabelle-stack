#!/usr/bin/env python3
"""
Wyoming TTS server for Kyutai Pocket TTS.

Supports both legacy single-shot synthesis (Synthesize) and the native
Wyoming streaming protocol (SynthesizeStart / SynthesizeChunk / SynthesizeStop).

Sentence-level streaming: detects sentence boundaries as LLM tokens arrive
and starts synthesising each complete sentence immediately, so the satellite
starts playing before the full LLM response is ready. Clause-aware: long
sentences are split at clause punctuation (commas etc.) once a minimum length
is reached, and a partial-flush fallback speaks accumulated text if no
punctuation arrives within a max length — so the first audio lands as early
as possible without mid-word cuts.

Sacrificial prefix (2.x: disabled by default via POCKET_TTS_PREFIX=''): with
voice states loaded from safetensors there is no audio-prompt blend region, so
the first word starts cleanly without a prefix and audio streams immediately
(~150 ms first audio). Set POCKET_TTS_PREFIX='... ' to restore the 1.x-style
prefix + adaptive silence-gap trimming (adds latency).

Voice caching: voice states are exported to safetensors on first load and
reloaded from disk on subsequent starts (much faster than recomputing from wav).

Zeroconf: registers with mDNS so Home Assistant can auto-discover the server.

Environment variables:
  POCKET_TTS_WYOMING_PORT  Wyoming TCP port (default: 10213)
  POCKET_TTS_HOST          Bind address (default: 0.0.0.0)
  POCKET_TTS_VOICE         Default built-in voice (default: alba)
  POCKET_TTS_ZEROCONF      mDNS service name, empty to disable (default: pocket-tts2)
  POCKET_TTS_LANGUAGE        Pocket TTS 2.x language model (default: english)
  HF_HOME                  HuggingFace cache directory (default: /data/models)
  HF_TOKEN                 Optional HuggingFace token for faster downloads
  PREFIX_MIN_DURATION      Min seconds before searching for silence gap (default: 0.15)
  PREFIX_MAX_DURATION      Max seconds to search for prefix end (default: 1.0)
  PREFIX_SILENCE_GAP       Min silence duration to identify gap after prefix (default: 0.08)
  POCKET_TTS_CLAUSE_MIN_CHARS
                           Min buffered chars before splitting at clause
                           punctuation ,;:—… (default: 40)
  POCKET_TTS_PARTIAL_MAX_CHARS
                           Speak buffered text after this many chars without
                           any punctuation, cut at last space (default: 80)
  POCKET_TTS_VOLUME        Output gain multiplier, e.g. 1.5 to boost by 50% (default: 1.0)
  POCKET_TTS_VOLUME        Linear volume multiplier applied after synthesis (default: 1.0)
                           Values > 1.0 boost volume; audio is clipped at ±1.0 after gain.
                           Try 1.5–2.0 if the output is too quiet.
"""

import asyncio
import logging
import os
import re
import socket
from functools import partial
from pathlib import Path

import numpy as np
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.error import Error
from wyoming.info import Attribution, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer, AsyncTcpServer
from wyoming.tts import (
    Synthesize,
    SynthesizeChunk,
    SynthesizeStart,
    SynthesizeStop,
    SynthesizeStopped,
)

_LOGGER = logging.getLogger(__name__)

SAMPLE_RATE = 24000
CHUNK_BYTES = 4096  # ~85 ms at 24 kHz s16le mono

VOICES_DIR = Path("/data/voices")

# Sacrificial prefix tunables (technique from ikidd/pocket-tts-wyoming)
PREFIX_MIN_DURATION = float(os.environ.get("PREFIX_MIN_DURATION", "0.15"))
PREFIX_MAX_DURATION = float(os.environ.get("PREFIX_MAX_DURATION", "1.0"))
PREFIX_SILENCE_GAP = float(os.environ.get("PREFIX_SILENCE_GAP", "0.08"))

VOLUME = float(os.environ.get("POCKET_TTS_VOLUME", "1.0"))
VOLUME_GAIN = float(os.environ.get("POCKET_TTS_VOLUME", "1.0"))

# Sacrificial prefix: '' for pocket-tts 2.x (voice = safetensors embedding, no
# blend region, clean word starts). Set to '... ' if the first word ever sounds
# swallowed (1.x behaviour, adds ~0.2-0.5s first-audio latency).
PREFIX = os.environ.get("POCKET_TTS_PREFIX", "")

# Smarter chunking tunables: when to split at clauses, when to speak partials
CLAUSE_MIN_CHARS = int(os.environ.get("POCKET_TTS_CLAUSE_MIN_CHARS", "40"))
PARTIAL_MAX_CHARS = int(os.environ.get("POCKET_TTS_PARTIAL_MAX_CHARS", "80"))

_DECIMAL_PLACEHOLDER = "\x00DEC\x00"

# Shared voice state cache: voice_name -> model state dict
_VOICE_STATES: dict = {}
_VOICE_LOCK = asyncio.Lock()


def _split_chunk(safe: str, end: int) -> tuple:
    """Split *safe* at *end* into (chunk, rest), restoring decimal points."""
    chunk = safe[:end].replace(_DECIMAL_PLACEHOLDER, ".").strip()
    rest = safe[end:].replace(_DECIMAL_PLACEHOLDER, ".").strip()
    return chunk, rest


def _extract_chunk(buffer: str) -> tuple:
    """Extract the next speechable chunk from the streaming buffer.

    Three tiers, in priority order:
      1. Sentence punctuation ([.!?]) — always split here.
      2. Clause punctuation (,;:—…) once the buffer is at least
         CLAUSE_MIN_CHARS long — clause boundaries are natural speech
         pauses, so the listener hears the first clause while the rest
         of the sentence is still being generated.
      3. Partial flush: if no punctuation of any kind within
         PARTIAL_MAX_CHARS, speak the accumulated text anyway (cut at
         the last space) rather than staying silent.

    Returns (chunk, remaining_buffer); ("", buffer) when nothing
    should be spoken yet.
    """
    if not buffer:
        return "", ""
    safe = re.sub(r"(\d)\.(\d)", r"\g<1>" + _DECIMAL_PLACEHOLDER + r"\g<2>", buffer)
    m = re.search(r"[.!?]", safe)
    if m:
        return _split_chunk(safe, m.start() + 1)
    if len(safe) >= CLAUSE_MIN_CHARS:
        m = re.search(r"[,;:\u2014\u2026]", safe)
        if m:
            return _split_chunk(safe, m.start() + 1)
    if len(safe) >= PARTIAL_MAX_CHARS:
        cut = safe.rfind(" ", 0, PARTIAL_MAX_CHARS)
        if cut == -1:
            cut = PARTIAL_MAX_CHARS
        return _split_chunk(safe, cut)
    return "", buffer


def _trim_prefix(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Remove the sacrificial prefix audio and leading/trailing silence.

    Adaptively detects the silence gap after "... " rather than using a
    fixed duration, so it works across different voice speeds.
    """
    if len(audio) == 0:
        return audio

    silence_threshold = 0.01
    max_amplitude = np.abs(audio).max()
    threshold = max_amplitude * silence_threshold

    min_prefix_samples = int(sample_rate * PREFIX_MIN_DURATION)
    max_prefix_samples = int(sample_rate * PREFIX_MAX_DURATION)
    min_silence_samples = int(sample_rate * PREFIX_SILENCE_GAP)

    prefix_end = 0
    if len(audio) > min_prefix_samples:
        search_end = min(len(audio), max_prefix_samples)
        is_silent = np.abs(audio[:search_end]) < threshold
        i = min_prefix_samples
        while i < search_end:
            if is_silent[i]:
                silence_start = i
                while i < search_end and is_silent[i]:
                    i += 1
                if (i - silence_start) >= min_silence_samples:
                    prefix_end = i
                    break
            else:
                i += 1

    if prefix_end > 0:
        _LOGGER.debug("Trimmed prefix: %d samples (%.3fs)", prefix_end, prefix_end / sample_rate)
        audio = audio[prefix_end:]

    # Trim leading and trailing silence, keeping 50 ms of padding
    padding = int(sample_rate * 0.05)
    non_silent = np.where(np.abs(audio) > threshold)[0]
    if len(non_silent) > 0:
        start = max(0, non_silent[0] - padding)
        end = min(len(audio), non_silent[-1] + padding + 1)
        audio = audio[start:end]

    return audio


def _find_prefix_gap(audio: np.ndarray, sample_rate: int):
    """Return audio after the sacrificial-prefix silence gap, or None if not found yet.

    Used by the streaming path: once the gap is detected we can start sending
    audio while the rest of the sentence is still being generated.
    """
    if len(audio) == 0:
        return None

    silence_threshold = 0.01
    max_amplitude = np.abs(audio).max()
    if max_amplitude == 0:
        return None
    threshold = max_amplitude * silence_threshold

    min_prefix_samples = int(sample_rate * PREFIX_MIN_DURATION)
    max_prefix_samples = int(sample_rate * PREFIX_MAX_DURATION)
    min_silence_samples = int(sample_rate * PREFIX_SILENCE_GAP)

    if len(audio) <= min_prefix_samples:
        return None
    search_end = min(len(audio), max_prefix_samples)
    is_silent = np.abs(audio[:search_end]) < threshold
    i = min_prefix_samples
    while i < search_end:
        if is_silent[i]:
            silence_start = i
            while i < search_end and is_silent[i]:
                i += 1
            if (i - silence_start) >= min_silence_samples:
                return audio[i:]
        else:
            i += 1
    return None


def _trim_leading_silence(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Trim leading silence only, keeping 50 ms of padding."""
    if len(audio) == 0:
        return audio
    silence_threshold = 0.01
    max_amplitude = np.abs(audio).max()
    if max_amplitude == 0:
        return audio
    threshold = max_amplitude * silence_threshold
    padding = int(sample_rate * 0.05)
    non_silent = np.where(np.abs(audio) > threshold)[0]
    if len(non_silent) > 0:
        start = max(0, non_silent[0] - padding)
        audio = audio[start:]
    return audio


def _load_voice_state(model, language: str, voice_name: str):
    """Load voice state, using safetensors cache for fast subsequent starts."""
    safetensors_path = VOICES_DIR / f"{voice_name}.safetensors"
    if safetensors_path.exists():
        _LOGGER.info("Loading voice %r from safetensors cache", voice_name)
        return model.get_state_for_audio_prompt(str(safetensors_path))
    _LOGGER.info("Loading voice %r from HuggingFace (will cache for next start)...", voice_name)
    # pocket-tts 2.x resolves predefined voice names against the language config
    state = model.get_state_for_audio_prompt(voice_name)
    VOICES_DIR.mkdir(parents=True, exist_ok=True)
    from pocket_tts import export_model_state
    export_model_state(state, str(safetensors_path))
    _LOGGER.info("Voice %r cached -> %s", voice_name, safetensors_path)
    return state


class PocketTTSHandler(AsyncEventHandler):
    def __init__(self, wyoming_info, args, model, predefined_voices, *handler_args, **kwargs):
        super().__init__(*handler_args, **kwargs)
        self._wyoming_info = wyoming_info
        self._args = args
        self._model = model
        self._predefined_voices = predefined_voices
        self._streaming = False
        self._stream_voice = ""
        self._stream_buffer = ""

    def _resolve_voice(self, name):
        if name and name in self._predefined_voices:
            return name
        # HA / streaming_tts_proxy may prefix the service name
        if name and name.startswith("pocket-tts-"):
            stripped = name[len("pocket-tts-"):]
            if stripped in self._predefined_voices:
                return stripped
        if name and name != self._args.default_voice:
            _LOGGER.warning("Unknown voice %r, using %s", name, self._args.default_voice)
        return self._args.default_voice

    async def _get_voice_state(self, voice_name):
        """Return cached voice state, loading on demand if necessary."""
        async with _VOICE_LOCK:
            if voice_name not in _VOICE_STATES:
                loop = asyncio.get_event_loop()
                model = self._model
                language = self._args.language
                state = await loop.run_in_executor(
                    None, lambda: _load_voice_state(model, language, voice_name)
                )
                _VOICE_STATES[voice_name] = state
            return _VOICE_STATES[voice_name]

    async def handle_event(self, event):
        try:
            return await self._handle_event(event)
        except (ConnectionResetError, BrokenPipeError, OSError):
            _LOGGER.debug("Client disconnected mid-event")
            return False

    async def _handle_event(self, event):
        if event.type == "describe":
            await self.write_event(self._wyoming_info.event())
            return True

        if Synthesize.is_type(event.type):
            synthesize = Synthesize.from_event(event)
            voice_name = self._resolve_voice(
                synthesize.voice.name if synthesize.voice else self._args.default_voice
            )
            _LOGGER.info("Synthesize (legacy): %d chars | voice=%s", len(synthesize.text), voice_name)
            voice_state = await self._get_voice_state(voice_name)
            try:
                await self._do_synthesize(synthesize.text, voice_state)
            except Exception as exc:
                _LOGGER.exception("Error during synthesis")
                await self.write_event(Error(text=str(exc), code=type(exc).__name__).event())
                return False
            return True

        if SynthesizeStart.is_type(event.type):
            start = SynthesizeStart.from_event(event)
            self._stream_voice = self._resolve_voice(
                start.voice.name if start.voice else self._args.default_voice
            )
            self._stream_buffer = ""
            self._streaming = True
            _LOGGER.info("Stream session started (voice=%s)", self._stream_voice)
            return True

        if SynthesizeChunk.is_type(event.type):
            if not self._streaming:
                return True
            self._stream_buffer += SynthesizeChunk.from_event(event).text
            while True:
                sentence, rest = _extract_chunk(self._stream_buffer)
                if not sentence:
                    break
                self._stream_buffer = rest
                voice_state = await self._get_voice_state(self._stream_voice)
                try:
                    await self._do_synthesize(sentence, voice_state)
                except Exception as exc:
                    _LOGGER.exception("Error synthesising sentence")
                    await self.write_event(Error(text=str(exc), code=type(exc).__name__).event())
            return True

        if SynthesizeStop.is_type(event.type):
            if not self._streaming:
                return True
            remaining = self._stream_buffer.strip()
            if remaining:
                voice_state = await self._get_voice_state(self._stream_voice)
                try:
                    await self._do_synthesize(remaining, voice_state)
                except Exception as exc:
                    _LOGGER.exception("Error synthesising final fragment")
                    await self.write_event(Error(text=str(exc), code=type(exc).__name__).event())
            self._streaming = False
            self._stream_buffer = ""
            await self.write_event(SynthesizeStopped().event())
            _LOGGER.info("Stream session complete")
            return True

        return True

    async def _do_synthesize(self, text: str, voice_state):
        """Synthesise one sentence, streaming audio out as tokens are generated.

        The sacrificial prefix ("... ") is trimmed on the fly: chunks are
        buffered only until the prefix silence gap is detected, then audio
        streams to the satellite immediately as later chunks arrive
        (in-sentence streaming, ~120-200 ms to first audio). Falls back to
        full-buffer+trim for utterances too short to find the gap.
        """
        _LOGGER.info("Synthesising %d chars", len(text))
        loop = asyncio.get_event_loop()
        model = self._model

        # Prefix prevents voice-prompt blend region from swallowing the first word
        text_with_prefix = PREFIX + text

        def to_audio_bytes(audio: np.ndarray) -> bytes:
            if VOLUME_GAIN != 1.0:
                audio = audio * VOLUME_GAIN
            audio_int16 = (np.clip(audio * VOLUME, -1.0, 1.0) * 32767).astype(np.int16)
            return audio_int16.tobytes()

        async def write_chunks(audio_bytes: bytes):
            for offset in range(0, len(audio_bytes), CHUNK_BYTES):
                await self.write_event(
                    AudioChunk(
                        audio=audio_bytes[offset: offset + CHUNK_BYTES],
                        rate=SAMPLE_RATE, width=2, channels=1,
                    ).event()
                )

        # Generate in a background thread, stream in the event loop
        import queue
        from concurrent.futures import ThreadPoolExecutor

        q = queue.Queue(maxsize=4)

        def producer():
            try:
                for c in model.generate_audio_stream(
                    voice_state, text_with_prefix, copy_state=True
                ):
                    q.put(c.detach().cpu().numpy().astype(np.float32))
            except Exception as exc:  # noqa: BLE001 - forwarded to consumer
                q.put(exc)
            finally:
                q.put(None)

        started = False
        pending = np.zeros(0, dtype=np.float32)
        max_buf_samples = int(SAMPLE_RATE * (PREFIX_MAX_DURATION + 0.25))

        with ThreadPoolExecutor(max_workers=1) as pool:
            fut = pool.submit(producer)
            while True:
                chunk = await loop.run_in_executor(None, q.get)
                if chunk is None:
                    break
                if isinstance(chunk, Exception):
                    raise chunk

                if PREFIX:
                    # gap-detection streaming: buffer until prefix silence gap found
                    if not started:
                        pending = np.concatenate([pending, chunk])
                        after_gap = _find_prefix_gap(pending, SAMPLE_RATE)
                        if after_gap is None and len(pending) < max_buf_samples:
                            continue
                        if after_gap is None:
                            # gap never found: emit everything, trimmed, keep streaming
                            after_gap = _trim_prefix(pending, SAMPLE_RATE)
                        else:
                            after_gap = _trim_leading_silence(after_gap, SAMPLE_RATE)
                        if len(after_gap) == 0:
                            continue
                        started = True
                        await self.write_event(AudioStart(rate=SAMPLE_RATE, width=2, channels=1).event())
                        await write_chunks(to_audio_bytes(after_gap))
                        continue

                    await write_chunks(to_audio_bytes(chunk))
                else:
                    # direct streaming: emit every chunk immediately (~150 ms first audio)
                    if not started:
                        chunk = _trim_leading_silence(chunk, SAMPLE_RATE)
                        if len(chunk) == 0:
                            continue
                        started = True
                        await self.write_event(AudioStart(rate=SAMPLE_RATE, width=2, channels=1).event())
                    await write_chunks(to_audio_bytes(chunk))

            if not started:
                # gap never found (very short utterance): fall back to full-buffer trim
                if len(pending) > 0:
                    full_audio = _trim_prefix(pending, SAMPLE_RATE)
                    if len(full_audio) > 0:
                        await self.write_event(AudioStart(rate=SAMPLE_RATE, width=2, channels=1).event())
                        await write_chunks(to_audio_bytes(full_audio))
            fut.result()
        await self.write_event(AudioStop().event())


async def main():
    import argparse
    parser = argparse.ArgumentParser(description="Pocket TTS Wyoming Server")
    parser.add_argument("--port", type=int,
                        default=int(os.environ.get("POCKET_TTS_WYOMING_PORT", "10213")))
    parser.add_argument("--host", default=os.environ.get("POCKET_TTS_HOST", "0.0.0.0"))
    parser.add_argument("--default-voice",
                        default=os.environ.get("POCKET_TTS_VOICE", "alba"))
    parser.add_argument("--language",
                        default=os.environ.get("POCKET_TTS_LANGUAGE", "english"))
    parser.add_argument("--zeroconf",
                        default=os.environ.get("POCKET_TTS_ZEROCONF", "pocket-tts2"))
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [pocket-tts] %(levelname)s %(message)s",
    )

    from pocket_tts import TTSModel

    # English predefined voices (pocket-tts 2.x, resolved via get_predefined_voice)
    predefined_voices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "estelle", "eve", "fantine", "george",
        "giovanni", "jane", "javert", "jean", "juergen", "lola", "marius",
        "mary", "michael", "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    if args.default_voice not in predefined_voices:
        _LOGGER.warning(
            "POCKET_TTS_VOICE=%r not in known voices %s, falling back to alba",
            args.default_voice, predefined_voices,
        )
        args.default_voice = "alba"

    _LOGGER.info("Loading Pocket TTS model (language=%s)...", args.language)
    model = TTSModel.load_model(language=args.language)
    _LOGGER.info("Model loaded (sample_rate=%d Hz)", model.sample_rate)

    # Pre-load default voice (safetensors cache used on subsequent starts)
    _VOICE_STATES[args.default_voice] = _load_voice_state(model, args.language, args.default_voice)

    wyoming_info = Info(
        tts=[
            TtsProgram(
                name="pocket-tts2",
                description="Kyutai Pocket TTS 2.1 - 100M param streaming TTS (~200ms latency)",
                attribution=Attribution(
                    name="Kyutai",
                    url="https://github.com/kyutai-labs/pocket-tts",
                ),
                installed=True,
                version=None,
                voices=[
                    TtsVoice(
                        name=v,
                        description=v,
                        attribution=Attribution(
                            name="Kyutai",
                            url="https://huggingface.co/kyutai/tts-voices",
                        ),
                        installed=True,
                        version=None,
                        languages=["en"],
                    )
                    for v in sorted(predefined_voices)
                ],
                supports_synthesize_streaming=True,
            )
        ]
    )

    _LOGGER.info(
        "Starting Wyoming server on port %d (default_voice=%s)",
        args.port, args.default_voice,
    )
    server = AsyncServer.from_uri(f"tcp://{args.host}:{args.port}")

    # Zeroconf registration for HA auto-discovery
    if args.zeroconf and isinstance(server, AsyncTcpServer):
        from wyoming.zeroconf import HomeAssistantZeroconf
        zeroconf_host = args.host
        if zeroconf_host in ("0.0.0.0", ""):
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.connect(("8.8.8.8", 80))
                zeroconf_host = s.getsockname()[0]
                s.close()
            except Exception:
                zeroconf_host = "127.0.0.1"
        hass_zc = HomeAssistantZeroconf(
            name=args.zeroconf, port=server.port, host=zeroconf_host
        )
        await hass_zc.register_server()
        _LOGGER.info(
            "Zeroconf registered: name=%s host=%s port=%d",
            args.zeroconf, zeroconf_host, server.port,
        )

    _LOGGER.info("Available voices: %s", ", ".join(sorted(predefined_voices)))
    await server.run(
        partial(PocketTTSHandler, wyoming_info, args, model, predefined_voices)
    )


if __name__ == "__main__":
    asyncio.run(main())
