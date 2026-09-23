#!/usr/bin/env python3
import os
import logging
import tempfile
import wave
import subprocess
import asyncio

from flask import Flask, request, jsonify
from flask_cors import CORS
from wyoming.client import AsyncClient
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.asr import Transcribe, Transcript

logging.basicConfig(level=logging.INFO)
_LOGGER = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

WYOMING_HOST = '127.0.0.1'
WYOMING_PORT = int(os.environ.get('VOICEBM_WYOMING_PORT', 10301))
API_PORT = int(os.environ.get('VOICEBM_API_PORT', 10302))
# Max seconds to wait for the transcript after sending audio. Long recordings
# take a while on CPU STT; the request fails cleanly with a timeout error
# instead of hanging forever.
API_TIMEOUT = int(os.environ.get('VOICEBM_API_TIMEOUT', '600'))


async def transcribe_audio(audio_data: bytes, sample_rate: int = 16000) -> str:
    async with AsyncClient.from_uri(f"tcp://{WYOMING_HOST}:{WYOMING_PORT}") as client:
        await client.write_event(Transcribe().event())
        await client.write_event(AudioStart(rate=sample_rate, width=2, channels=1).event())

        chunk_size = 8192
        for i in range(0, len(audio_data), chunk_size):
            await client.write_event(
                AudioChunk(rate=sample_rate, width=2, channels=1, audio=audio_data[i:i+chunk_size]).event()
            )

        await client.write_event(AudioStop().event())

        async def _read_transcript():
            while True:
                event = await client.read_event()
                if event is None:
                    break
                if Transcript.is_type(event.type):
                    return Transcript.from_event(event).text
            return ""

        try:
            return await asyncio.wait_for(_read_transcript(), timeout=API_TIMEOUT)
        except asyncio.TimeoutError:
            raise TimeoutError(
                f"Timed out after {API_TIMEOUT}s waiting for voicebm transcript "
                f"(audio too long or STT too slow)"
            )


def convert_to_pcm16(audio_bytes: bytes, filename: str = None) -> tuple[bytes, int]:
    suffix = '.tmp'
    if filename:
        ext = os.path.splitext(filename)[1].lower()
        if ext in ['.mp3', '.wav', '.ogg', '.flac', '.m4a', '.webm', '.opus', '.mp4', '.mpeg', '.mpga']:
            suffix = ext

    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as input_file:
        input_file.write(audio_bytes)
        input_path = input_file.name

    output_path = input_path + '_converted.wav'
    try:
        result = subprocess.run([
            'ffmpeg', '-y',
            '-i', input_path,
            '-ar', '16000',
            '-ac', '1',
            '-f', 'wav',
            '-acodec', 'pcm_s16le',
            output_path
        ], capture_output=True, text=True, timeout=30)

        if result.returncode != 0:
            raise Exception(f"ffmpeg conversion failed: {result.stderr}")

        with wave.open(output_path, 'rb') as wav_file:
            pcm_data = wav_file.readframes(wav_file.getnframes())
            sample_rate = wav_file.getframerate()

        return pcm_data, sample_rate
    finally:
        for p in [input_path, output_path]:
            if os.path.exists(p):
                os.unlink(p)


@app.route('/v1/audio/transcriptions', methods=['POST'])
def create_transcription():
    try:
        if 'file' not in request.files:
            return jsonify({"error": {"message": "No audio file provided", "type": "invalid_request_error"}}), 400

        audio_file = request.files['file']
        model = request.form.get('model', 'whisper-1')
        language = request.form.get('language', 'en')
        response_format = request.form.get('response_format', 'json')

        audio_bytes = audio_file.read()
        pcm_data, sample_rate = convert_to_pcm16(audio_bytes, audio_file.filename)

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            text = loop.run_until_complete(transcribe_audio(pcm_data, sample_rate))
        finally:
            loop.close()

        if response_format == 'text':
            return text, 200, {'Content-Type': 'text/plain'}
        elif response_format == 'srt':
            return f"1\n00:00:00,000 --> 00:00:10,000\n{text}\n", 200, {'Content-Type': 'text/plain'}
        elif response_format == 'vtt':
            return f"WEBVTT\n\n00:00:00.000 --> 00:00:10.000\n{text}\n", 200, {'Content-Type': 'text/plain'}
        elif response_format == 'verbose_json':
            return jsonify({
                "task": "transcribe", "language": language, "duration": 0.0,
                "text": text,
                "segments": [{"id": 0, "seek": 0, "start": 0.0, "end": 10.0, "text": text, "tokens": [], "temperature": 0.0, "avg_logprob": 0.0, "compression_ratio": 1.0, "no_speech_prob": 0.0}]
            })
        else:
            return jsonify({"text": text})

    except Exception as e:
        _LOGGER.exception("Error in transcription")
        return jsonify({"error": {"message": str(e), "type": "server_error"}}), 500


@app.route('/v1/models', methods=['GET'])
@app.route('/v1/audio/models', methods=['GET'])
def list_models():
    return jsonify({
        "object": "list",
        "data": [
            {"id": "whisper-1", "object": "model", "created": 1738022400, "owned_by": "voicebm"},
        ]
    })


@app.route('/health', methods=['GET'])
def health():
    try:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        async def check():
            try:
                async with AsyncClient.from_uri(f"tcp://{WYOMING_HOST}:{WYOMING_PORT}"):
                    return True
            except Exception:
                return False

        connected = loop.run_until_complete(check())
        loop.close()
        return jsonify({"status": "healthy" if connected else "degraded", "wyoming_connected": connected})
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 500


@app.route('/', methods=['GET'])
@app.route('/v1', methods=['GET'])
def index():
    return jsonify({
        "name": "VoiceBM OpenAI API",
        "version": "1.0.0",
        "type": "speech-to-text",
        "endpoints": {
            "transcriptions": "/v1/audio/transcriptions",
            "models": "/v1/models",
            "health": "/health"
        }
    })


if __name__ == '__main__':
    _LOGGER.info(f"Starting VoiceBM OpenAI-compatible STT API on port {API_PORT}")
    app.run(host='0.0.0.0', port=API_PORT, threaded=True)
