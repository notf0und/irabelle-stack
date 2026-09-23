#!/usr/bin/env python3
"""
Embedded STT engine for voicebm using sherpa-onnx OfflineRecognizer.

This allows voicebm to handle speech-to-text internally without depending on
an external parakeet/sherpa-onnx-asr service.

Model selection via environment variables:
  VOICEBM_STT_MODEL    - Model name (default: cohere-transcribe)
  VOICEBM_STT_LANGUAGE - Language (default: en)
  VOICEBM_STT_THREADS  - CPU threads (default: 4)
"""

import logging
import numpy as np
import sys
from typing import Optional

# Import from centralized registry to avoid duplication
from voicebm_stt_model_registry import (
    get_model_info,
    create_recognizer,
    download_model,
)

_LOGGER = logging.getLogger(__name__)

# Long-audio handling: single-pass decoding degrades / hits sherpa limits for
# multi-minute clips. Audio longer than MAX_SEGMENT_SECS is decoded in
# overlapping chunks and the results joined.
MAX_SEGMENT_SECS = 20.0
SEGMENT_OVERLAP_SECS = 0.75

try:
    import sherpa_onnx
except ImportError:
    sherpa_onnx = None


class VoiceBMSTTEngine:
    """Embedded STT engine using sherpa-onnx OfflineRecognizer."""

    def __init__(
        self,
        model_name: str = "cohere-transcribe",
        model_dir: str = "/data/stt-models",
        language: str = "en",
        num_threads: int = 4,
    ):
        """Initialize STT engine with a sherpa-onnx model."""
        if sherpa_onnx is None:
            raise RuntimeError("sherpa-onnx not installed")

        self.model_name = model_name
        self.model_dir = model_dir
        self.language = language
        self.num_threads = num_threads

        self._recognizer = create_recognizer(
            model_name=model_name,
            model_base_dir=model_dir,
            language=language,
            num_threads=num_threads,
        )
        _LOGGER.info(
            f"VoiceBM STT Engine initialized: {model_name}, language={language}"
        )

    def recognize(
        self, audio_data: bytes, sample_rate: int = 16000
    ) -> str:
        """Recognize speech from audio bytes.

        Args:
            audio_data: Raw PCM audio data (int16)
            sample_rate: Sample rate in Hz (default: 16000)

        Returns:
            Transcribed text
        """
        try:
            # Convert bytes to numpy array
            audio_np = np.frombuffer(audio_data, dtype=np.int16).astype(
                np.float32
            ) / 32768.0

            duration_secs = len(audio_np) / sample_rate
            if duration_secs <= MAX_SEGMENT_SECS:
                return self._decode(audio_np, sample_rate)

            # Long audio: decode in overlapping chunks so very long clips
            # transcribe reliably (single-pass decode degrades on long input).
            _LOGGER.info(
                "Long audio: %.1fs > %.1fs — decoding in chunks",
                duration_secs, MAX_SEGMENT_SECS,
            )
            chunk_samples = int(MAX_SEGMENT_SECS * sample_rate)
            overlap_samples = int(SEGMENT_OVERLAP_SECS * sample_rate)
            step = chunk_samples - overlap_samples
            texts = []
            for start in range(0, len(audio_np), step):
                seg = audio_np[start:start + chunk_samples]
                text = self._decode(seg, sample_rate)
                if text:
                    texts.append(text)
            return " ".join(texts).strip()
        except Exception as e:
            _LOGGER.error(f"STT recognition error: {e}", exc_info=True)
            return ""

    def _decode(self, audio_np: np.ndarray, sample_rate: int) -> str:
        """Decode a single audio segment with the offline recognizer."""
        stream = self._recognizer.create_stream()
        stream.accept_waveform(sample_rate, audio_np)
        self._recognizer.decode_stream(stream)

        text = stream.result.text.strip()
        _LOGGER.debug(f"STT recognized: {text!r}")
        return text


# Global instance (initialized in voicebm_wyoming_proxy.py)
_STT_ENGINE: Optional[VoiceBMSTTEngine] = None


def get_stt_engine() -> Optional[VoiceBMSTTEngine]:
    """Get or create the global STT engine."""
    global _STT_ENGINE
    return _STT_ENGINE


def init_stt_engine(
    model_name: str = "cohere-transcribe",
    model_dir: str = "/data/stt-models",
    language: str = "en",
    num_threads: int = 4,
) -> VoiceBMSTTEngine:
    """Initialize the global STT engine."""
    global _STT_ENGINE
    _STT_ENGINE = VoiceBMSTTEngine(
        model_name=model_name,
        model_dir=model_dir,
        language=language,
        num_threads=num_threads,
    )
    return _STT_ENGINE


def download_stt_model(model_name: str, base_dir: str) -> None:
    """Download and extract STT model if not already present.

    Args:
        model_name: Model name from MODELS registry
        base_dir: Base directory to download models into
    
    Delegates to centralized registry function to avoid duplication.
    """
    download_model(model_name, base_dir)
