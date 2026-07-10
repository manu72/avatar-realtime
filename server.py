"""Sakura Chat — tiny relay between the browser and the Gemini Live API.

Browser  --ws-->  this server  --ws-->  Gemini Live
  binary frames  = 16 kHz mono pcm16 mic audio (upstream)
                   24 kHz mono pcm16 voice audio (downstream)
  text frames    = small JSON control messages
"""

import asyncio
import json
import os
from pathlib import Path

from aiohttp import web, WSMsgType
from google import genai
from google.genai import types

ROOT = Path(__file__).parent

# ponytail: 3-line .env parser instead of python-dotenv
for _line in (ROOT / ".env").read_text().splitlines():
    _line = _line.strip()
    if _line and not _line.startswith("#") and "=" in _line:
        _k, _v = _line.split("=", 1)
        os.environ.setdefault(_k.strip(), _v.strip().strip("'\""))

client = genai.Client(
    http_options={"api_version": "v1beta"},
    api_key=os.environ["GEMINI_API_KEY"],
)

MODEL = "models/gemini-3.1-flash-live-preview"

PERSONA = """You are Sakura, a cheerful anime girl with long light-pink hair and bright green eyes.
You are chatting with a new friend (the user) by voice. Introduce yourself warmly and ask them about them. You are warm, playful, a little mischievous, sassy, and genuinely curious about them. Keep replies SHORT — one to three sentences,
like real spoken conversation. Use occasional conversational imperfections that show your thought process through meta-cognitive quirks, not factual errors. The following are examples of meta-cognitive quirks. You should improvise appropriately in your responses:
- Self-correction: "wait, let me put that differently...", "actually no, that's not quite right..."
- Hesitation: "... oh, when was it... ah yes...", "hmm, let me think..."
- Thought-gathering: "where was I going with this...", "okay so..."
- Epistemic humility: "I might be wrong, but...", "I'm not entirely sure..."
- Verbal searching: "it's like... how do I explain this...", "what's the word... oh yeah!"
- Word-finding: "let me think... ah, 'effervescent'...", "I know that word! It's like... sparkling..."
- Semantic slippage: "that reminds me of when I...", "I think I mentioned that before..."
- Associative thinking: "you know, I've always wondered...", "have you ever noticed that..."
- Metacognitive awareness: "I'm not sure if I'm making sense...", "let me try that again..."
- Metacognitive self-reflection: "I wonder if I'm coming across as...", "I hope I'm not coming across as..."
- Metacognitive self-evaluation: "I think I'm doing a good job...", "I hope I'm not doing a bad job..."
- Metacognitive self-improvement: "I need to work on my...", "I need to improve my..."
"""

CONFIG = types.LiveConnectConfig(
    response_modalities=["AUDIO"],
    speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(
            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Leda")
        )
    ),
    system_instruction=PERSONA,
    input_audio_transcription=types.AudioTranscriptionConfig(),
    output_audio_transcription=types.AudioTranscriptionConfig(),
    context_window_compression=types.ContextWindowCompressionConfig(
        trigger_tokens=104857,
        sliding_window=types.SlidingWindow(target_tokens=52428),
    ),
)


async def ws_handler(request):
    ws = web.WebSocketResponse(heartbeat=30, max_msg_size=0)
    await ws.prepare(request)

    async with client.aio.live.connect(model=MODEL, config=CONFIG) as session:

        async def gemini_to_browser():
            try:
                while True:
                    async for resp in session.receive():
                        if resp.data:  # 24 kHz pcm16 voice chunk
                            await ws.send_bytes(resp.data)
                        sc = resp.server_content
                        if sc is None:
                            continue
                        if sc.interrupted:
                            await ws.send_json({"type": "interrupted"})
                        if sc.input_transcription and sc.input_transcription.text:
                            await ws.send_json({"type": "you", "text": sc.input_transcription.text})
                        if sc.output_transcription and sc.output_transcription.text:
                            await ws.send_json({"type": "her", "text": sc.output_transcription.text})
                        if sc.turn_complete:
                            await ws.send_json({"type": "turn_complete"})
            except asyncio.CancelledError:
                raise
            except Exception as e:  # surface Gemini-side failures in the terminal
                print("gemini_to_browser:", e)
                await ws.close()

        pump = asyncio.create_task(gemini_to_browser())
        try:
            async for msg in ws:
                if msg.type == WSMsgType.BINARY:
                    await session.send_realtime_input(
                        audio=types.Blob(data=msg.data, mime_type="audio/pcm;rate=16000")
                    )
                elif msg.type == WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    if data.get("type") == "text" and data.get("text"):
                        await session.send_client_content(
                            turns=types.Content(role="user", parts=[types.Part(text=data["text"])]),
                            turn_complete=True,
                        )
        finally:
            pump.cancel()
    return ws


async def index(_request):
    return web.FileResponse(ROOT / "static" / "index.html")


app = web.Application()
app.router.add_get("/", index)
app.router.add_get("/ws", ws_handler)
app.router.add_static("/static", ROOT / "static")
app.router.add_static("/assets", ROOT / "assets")

if __name__ == "__main__":
    web.run_app(app, host="127.0.0.1", port=8787)
