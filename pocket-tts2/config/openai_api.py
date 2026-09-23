#!/usr/bin/env python3
import os
import io
import logging
import tempfile
import subprocess
import asyncio
import wave

from flask import Flask, request, jsonify, Response
from flask_cors import CORS
from wyoming.client import AsyncClient
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.tts import Synthesize, SynthesizeVoice

logging.basicConfig(level=logging.INFO)
_LOGGER = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

WYOMING_HOST = '127.0.0.1'
WYOMING_PORT = int(os.environ.get('POCKET_TTS_WYOMING_PORT', 10215))
API_PORT = int(os.environ.get('POCKET_TTS_API_PORT', 10216))


async def synthesize_text(text: str, voice: str) -> bytes:
    async with AsyncClient.from_uri(f"tcp://{WYOMING_HOST}:{WYOMING_PORT}") as client:
        synth = Synthesize(text=text)
        if voice:
            synth.voice = SynthesizeVoice(name=voice)
        await client.write_event(synth.event())

        pcm_data = bytearray()
        while True:
            event = await client.read_event()
            if event is None:
                break
            if AudioChunk.is_type(event.type):
                chunk = AudioChunk.from_event(event)
                pcm_data.extend(chunk.audio)
            elif AudioStop.is_type(event.type):
                break

        return bytes(pcm_data)


def convert_audio(pcm_data: bytes, sample_rate: int, fmt: str, speed: float) -> tuple[bytes, str]:
    content_types = {
        'mp3': 'audio/mpeg',
        'opus': 'audio/opus',
        'aac': 'audio/aac',
        'flac': 'audio/flac',
        'wav': 'audio/wav',
        'pcm': 'audio/L16;rate=24000;channels=1',
    }

    if fmt == 'pcm':
        return pcm_data, content_types['pcm']

    if fmt == 'wav' and speed == 1.0:
        buf = io.BytesIO()
        with wave.open(buf, 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sample_rate)
            w.writeframes(pcm_data)
        return buf.getvalue(), content_types['wav']

    with tempfile.NamedTemporaryFile(suffix='.raw', delete=False) as raw:
        raw.write(pcm_data)
        raw_path = raw.name

    output_path = raw_path + '.' + fmt
    try:
        cmd = [
            'ffmpeg', '-y',
            '-f', 's16le',
            '-ar', str(sample_rate),
            '-ac', '1',
            '-i', raw_path,
        ]
        if speed != 1.0:
            cmd.extend(['-filter:a', f'atempo={speed}'])
        if fmt == 'mp3':
            cmd.extend(['-codec:a', 'libmp3lame', '-q:a', '2'])
        elif fmt == 'opus':
            cmd.extend(['-codec:a', 'libopus'])
        elif fmt == 'aac':
            cmd.extend(['-codec:a', 'aac'])
        elif fmt == 'flac':
            cmd.extend(['-codec:a', 'flac'])
        else:
            cmd.extend(['-codec:a', 'libmp3lame', '-q:a', '2'])
            fmt = 'mp3'

        cmd.append(output_path)

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            raise Exception(f"ffmpeg failed: {result.stderr}")

        with open(output_path, 'rb') as f:
            audio = f.read()

        return audio, content_types.get(fmt, 'application/octet-stream')
    finally:
        if os.path.exists(raw_path):
            os.unlink(raw_path)
        if os.path.exists(output_path):
            os.unlink(output_path)


@app.route('/v1/audio/speech', methods=['POST'])
def create_speech():
    try:
        data = request.get_json(silent=True)
        if not data:
            data = request.form.to_dict()

        input_text = data.get('input', '')
        if not input_text:
            return jsonify({"error": {"message": "No input text provided", "type": "invalid_request_error"}}), 400

        voice = data.get('voice', 'alba')
        response_format = data.get('response_format', 'mp3')
        speed = float(data.get('speed', 1.0))

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            pcm_data = loop.run_until_complete(synthesize_text(input_text, voice))
        finally:
            loop.close()

        audio_bytes, content_type = convert_audio(pcm_data, 24000, response_format, speed)
        return Response(audio_bytes, mimetype=content_type)

    except Exception as e:
        _LOGGER.exception("Error in TTS")
        return jsonify({"error": {"message": str(e), "type": "server_error"}}), 500


@app.route('/v1/models', methods=['GET'])
def list_models():
    return jsonify({
        "object": "list",
        "data": [
            {"id": "pocket-tts", "object": "model", "created": 1738022400, "owned_by": "kyutai"},
            {"id": "tts-1", "object": "model", "created": 1738022400, "owned_by": "openai"},
            {"id": "tts-1-hd", "object": "model", "created": 1738022400, "owned_by": "openai"},
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
        "name": "PocketTTS OpenAI API",
        "version": "1.0.0",
        "type": "text-to-speech",
        "endpoints": {
            "speech": "/v1/audio/speech",
            "models": "/v1/models",
            "health": "/health"
        },
        "voices": ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"],
    })


if __name__ == '__main__':
    _LOGGER.info(f"Starting PocketTTS OpenAI-compatible TTS API on port {API_PORT}")
    app.run(host='0.0.0.0', port=API_PORT, threaded=True)
