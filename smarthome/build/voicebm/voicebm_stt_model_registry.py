#!/usr/bin/env python3
"""
Model registry for sherpa-onnx ASR service.
Maps model names to download URLs, directory names, and recognizer configurations.
All models use OfflineRecognizer (batch inference) — appropriate for Wyoming's complete-utterance protocol.
"""
import os
import sys
import logging
import tarfile
import urllib.request

import sherpa_onnx

_LOGGER = logging.getLogger(__name__)

MODELS = {
    "cohere-transcribe": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01.tar.bz2",
        "dir": "sherpa-onnx-cohere-transcribe-14-lang-int8-2026-04-01",
        "type": "cohere_transcribe",
        "encoder": "encoder.int8.onnx",
        "decoder": "decoder.int8.onnx",
        "tokens": "tokens.txt",
    },
    "nemo-parakeet-ctc-0.6b": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-2025-01-29.tar.bz2",
        "dir": "sherpa-onnx-nemo-parakeet-tdt-ctc-110m-en-2025-01-29",
        "type": "nemo_ctc",
        "model": "model.int8.onnx",
        "tokens": "tokens.txt",
    },
    "whisper-small": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-small.tar.bz2",
        "dir": "sherpa-onnx-whisper-small",
        "type": "whisper",
        "encoder": "small-encoder.int8.onnx",
        "decoder": "small-decoder.int8.onnx",
        "tokens": "small-tokens.txt",
    },
    "sensevoice-small": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2",
        "dir": "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
        "type": "sense_voice",
        "model": "model.int8.onnx",
        "tokens": "tokens.txt",
    },
    "parakeet-tdt-0.6b-v2": {
        "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
        "dir": "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
        "type": "transducer",
        "encoder": "encoder.int8.onnx",
        "decoder": "decoder.int8.onnx",
        "joiner": "joiner.int8.onnx",
        "tokens": "tokens.txt",
    },
}


def get_model_info(name: str) -> dict:
    """Returns model info dict or raises ValueError."""
    if name not in MODELS:
        raise ValueError(f"Unknown model '{name}'. Available: {list(MODELS.keys())}")
    return MODELS[name]


def get_download_url(model_name: str) -> str:
    return get_model_info(model_name)["url"]


def get_model_dir(model_name: str, base_dir: str) -> str:
    info = get_model_info(model_name)
    return os.path.join(base_dir, info["dir"])


def create_recognizer(
    model_name: str,
    model_base_dir: str,
    num_threads: int = 4,
    language: str = "en",
) -> sherpa_onnx.OfflineRecognizer:
    """Creates and returns a configured OfflineRecognizer for the given model."""
    info = get_model_info(model_name)
    model_dir = os.path.join(model_base_dir, info["dir"])

    if not os.path.isdir(model_dir):
        raise FileNotFoundError(
            f"Model directory not found: {model_dir}. Run with --download first."
        )

    model_type = info["type"]
    _LOGGER.info(f"Creating OfflineRecognizer: model={model_name}, language={language}, threads={num_threads}")

    if model_type == "cohere_transcribe":
        return sherpa_onnx.OfflineRecognizer.from_cohere_transcribe(
            encoder=os.path.join(model_dir, info["encoder"]),
            decoder=os.path.join(model_dir, info["decoder"]),
            tokens=os.path.join(model_dir, info["tokens"]),
            language=language,
            num_threads=num_threads,
        )

    elif model_type == "whisper":
        return sherpa_onnx.OfflineRecognizer.from_whisper(
            encoder=os.path.join(model_dir, info["encoder"]),
            decoder=os.path.join(model_dir, info["decoder"]),
            tokens=os.path.join(model_dir, info["tokens"]),
            language=language,
            task="transcribe",
            num_threads=num_threads,
        )

    elif model_type == "nemo_ctc":
        return sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
            model=os.path.join(model_dir, info["model"]),
            tokens=os.path.join(model_dir, info["tokens"]),
            num_threads=num_threads,
        )

    elif model_type == "sense_voice":
        return sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=os.path.join(model_dir, info["model"]),
            tokens=os.path.join(model_dir, info["tokens"]),
            language=language,
            use_itn=True,
            num_threads=num_threads,
        )

    elif model_type == "transducer":
        return sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(model_dir, info["encoder"]),
            decoder=os.path.join(model_dir, info["decoder"]),
            joiner=os.path.join(model_dir, info["joiner"]),
            tokens=os.path.join(model_dir, info["tokens"]),
            num_threads=num_threads,
            model_type="parakeet",
            decoding_method="greedy_search",
        )

    else:
        raise ValueError(f"Unsupported model type: {model_type}")


def download_model(model_name: str, base_dir: str) -> None:
    """Download and extract the model tarball if not already present."""
    info = get_model_info(model_name)
    model_dir = os.path.join(base_dir, info["dir"])

    if os.path.isdir(model_dir):
        print(f"Model already present: {model_dir}", flush=True)
        return

    url = info["url"]
    tarball_name = url.split("/")[-1]
    tarball_path = os.path.join(base_dir, tarball_name)

    print(f"Downloading {model_name} from {url} ...", flush=True)

    def _progress(block_count, block_size, total_size):
        downloaded = block_count * block_size
        if total_size > 0:
            pct = min(100, downloaded * 100 // total_size)
            print(f"\r  {pct}% ({downloaded // 1024 // 1024} MB / {total_size // 1024 // 1024} MB)", end="", flush=True)

    urllib.request.urlretrieve(url, tarball_path, reporthook=_progress)
    print()  # newline after progress

    print(f"Extracting {tarball_name} ...", flush=True)
    with tarfile.open(tarball_path, "r:bz2") as tar:
        tar.extractall(path=base_dir)

    os.remove(tarball_path)
    print(f"Model ready: {model_dir}", flush=True)


if __name__ == "__main__":
    import argparse

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    parser = argparse.ArgumentParser(description="sherpa-onnx model registry helper")
    parser.add_argument("--download", action="store_true", help="Download the model")
    parser.add_argument("--model", required=True, help="Model name")
    parser.add_argument("--dir", default="/data", help="Base directory for models")
    args = parser.parse_args()

    if args.download:
        download_model(args.model, args.dir)
    else:
        info = get_model_info(args.model)
        print(f"Model: {args.model}")
        print(f"  URL : {info['url']}")
        print(f"  Dir : {os.path.join(args.dir, info['dir'])}")
