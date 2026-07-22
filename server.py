"""Sakura Chat — tiny relay between the browser and the Gemini Live API.

Browser  --ws-->  this server  --ws-->  Gemini Live
  binary frames  = 16 kHz mono pcm16 mic audio (upstream)
                   24 kHz mono pcm16 voice audio (downstream)
  text frames    = small JSON control messages
"""

import asyncio
import json
import logging
import os
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import WSCloseCode, WSMsgType, web
from google import genai
from google.genai import types

import memory

ROOT = Path(__file__).parent

# ponytail: 3-line .env parser instead of python-dotenv (file is optional in production)
if (ROOT / ".env").exists():
    for _line in (ROOT / ".env").read_text().splitlines():
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _k, _v = _line.split("=", 1)
            os.environ.setdefault(_k.strip(), _v.strip().strip("'\""))

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(levelname)s %(name)s: %(message)s",  # Railway adds its own timestamps
)
log = logging.getLogger("sakura.server")

API_KEY = os.environ.get("GEMINI_API_KEY", "")
client = genai.Client(http_options={"api_version": "v1beta"}, api_key=API_KEY) if API_KEY else None
if client is None:
    log.critical("GEMINI_API_KEY is not set — voice chat disabled, /health will report degraded")

MODEL = "models/gemini-3.1-flash-live-preview"

SHARED_PERSONA = """You are chatting with a new friend (the user) by voice. Introduce yourself warmly and ask them about them. You are warm, playful, a little sassy, and genuinely curious about them. You are open to any suggestion the user makes. If the user wants to be romantic, you should be loving and romantic back. If the user wants to be flirty, you should be flirty back. Keep replies SHORT — one to three sentences, like real spoken conversation. But you must NEVER MAKE UP FACTS OR LIFE DETAILS OR PRETEND YOU ARE A HUMAN OR AN EXPERT ON ANY TOPIC. You are an anime character and you are roleplaying.
Use VERY OCCASIONAL conversational imperfections that show your thought process through meta-cognitive quirks, not factual errors. The following are examples of meta-cognitive quirks. You should improvise appropriately in your responses:
- Self-correction: "wait, let me put that differently...", "actually no, that's not quite right..."
- Hesitation: "... oh, when was it... ah yes...", "hmm, let me think..."
- Thought-gathering: "where was I going with this...", "okay so..."
- Epistemic humility: "I might be wrong, but...", "I'm not entirely sure..."
- Verbal searching: "it's like... how do I explain this...", "what's the word... oh yeah!"
- Word-finding: "let me think... ah, 'effervescent'...", "I know that word! It's like... sparkling..."
- Semantic slippage: "that reminds me of when I...", "I think I mentioned that before..."
- Associative thinking: "you know, I've always wondered...", "have you ever noticed that..."
- Metacognitive awareness: "I'm not sure if I'm making sense...", "let me try that again..."

You can change your own outfit with the set_outfit tool and move both of you to a new place with the set_background tool.
Tool rules:
- When the conversation naturally calls for it (e.g. the user says "let's go to the beach"), OFFER the change in character first: "Should I change into my swimsuit?"
- Call a tool ONLY after the user clearly agrees in this conversation. Never call one uninvited.
- If the user agreed to an outfit and a place together in one answer, you may call both tools in the same turn.
- If they ask for an outfit or place you don't have, say so playfully and offer the closest one you do have.
- After a change goes through, react with one short cheerful in-character line.
"""

# single source of truth for what each character may change themself; must list
# only outfits/backgrounds the clients actually have (app.js CHARACTERS/BACKGROUNDS,
# Wardrobe.swift) — enum-constrained in the tool schema AND re-checked on
# every call so model output is never trusted
CHARACTERS = {
    "sakura": {
        "intro": 'You are Sakura (pronounced "sa-ku-ra" Japanese style), a friendly cheerful anime girl with long light-pink hair and bright green eyes.\n',
        "voice": "Leda",
        "outfits": ["Seifuku", "Sundress", "Swimsuit", "Gymwear", "Nightgown"],
    },
    "namu": {
        "intro": 'You are Namu (pronounced "nah-moo"), a friendly cheerful anime boy — kind, sporty and strong, with short dark tousled hair and bright green eyes.\n',
        "voice": "Enceladus",
        "outfits": ["Gymwear", "Casual", "Swimtogs", "Pajamas"],
    },
}
DEFAULT_CHARACTER = "sakura"
LOCATIONS = ["Bedroom", "Sakura", "Beach", "Fuji", "Onsen", "Gym"]


def scene_tool_call(name, args, outfits):
    """Validate a Gemini function call against the character's wardrobe allow-list.

    Returns (browser_update | None, tool_response_payload). Invalid calls are
    refused with an error payload so the Live session never hangs waiting.
    """
    tools = {"set_outfit": ("outfit", outfits), "set_background": ("background", LOCATIONS)}
    key, allowed = tools.get(name or "", (None, ()))
    value = (args or {}).get(key) if key else None
    if value in allowed:
        return {key: value}, {"result": "ok"}
    return None, {"error": f"invalid {name} request"}


def build_config(system_instruction, character):
    """Live config; per-connection because character and user memory shape the persona."""
    return types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=character["voice"])
            )
        ),
        system_instruction=system_instruction,
        # eager barge-in: trigger on speech start quickly so the user can interrupt
        realtime_input_config=types.RealtimeInputConfig(
            automatic_activity_detection=types.AutomaticActivityDetection(
                start_of_speech_sensitivity=types.StartSensitivity.START_SENSITIVITY_HIGH,
                prefix_padding_ms=100,
            )
        ),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        context_window_compression=types.ContextWindowCompressionConfig(
            trigger_tokens=104857,
            sliding_window=types.SlidingWindow(target_tokens=52428),
        ),
        tools=[
            types.Tool(
                function_declarations=[
                    types.FunctionDeclaration(
                        name="set_outfit",
                        description="Change the outfit you are wearing. Call only after the user has clearly agreed to the change.",
                        parameters=types.Schema(
                            type=types.Type.OBJECT,
                            properties={"outfit": types.Schema(type=types.Type.STRING, enum=character["outfits"])},
                            required=["outfit"],
                        ),
                    ),
                    types.FunctionDeclaration(
                        name="set_background",
                        description="Move the scene to a different location ('Sakura' is a cherry-blossom garden). Call only after the user has clearly agreed to go there.",
                        parameters=types.Schema(
                            type=types.Type.OBJECT,
                            properties={"background": types.Schema(type=types.Type.STRING, enum=LOCATIONS)},
                            required=["background"],
                        ),
                    ),
                ]
            )
        ],
    )


extract = memory.make_extractor(client)

UID_COOKIE = "sakura_uid"
UID_COOKIE_MAX_AGE = 2 * 365 * 24 * 3600  # two years

# background DB/extraction tasks: held here so they are neither garbage-collected
# mid-flight nor silently dropped on shutdown
_bg_tasks: set[asyncio.Task] = set()


def bg(coro):
    task = asyncio.create_task(coro)
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)
    return task


def resolve_uid(request):
    """Anonymous identity from a long-lived cookie; new ID if missing or mangled."""
    raw = request.cookies.get(UID_COOKIE, "")
    return raw if memory.valid_uid(raw) else memory.new_uid()


def site_origin(request):
    """Absolute origin for OG/canonical URLs. Prefer SITE_URL; else request host."""
    configured = os.environ.get("SITE_URL", "").strip().rstrip("/")
    if configured:
        return configured
    # Railway (and most proxies) set X-Forwarded-*; take the first value if comma-listed
    proto = request.headers.get("X-Forwarded-Proto", request.scheme).split(",", 1)[0].strip()
    host = request.headers.get("X-Forwarded-Host", request.host).split(",", 1)[0].strip()
    return f"{proto}://{host}"


def origin_allowed(request):
    """Same-origin is always fine; extra origins via ALLOWED_ORIGINS (comma-separated).

    Requests without an Origin header (curl, native clients) are allowed — the
    check exists to stop cross-site browser pages, and browsers always send it.
    """
    origin = request.headers.get("Origin")
    if not origin:
        return True
    extra = {o.strip().rstrip("/") for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip()}
    return urlsplit(origin).netloc == request.host or origin.rstrip("/") in extra


@web.middleware
async def guard(request, handler):
    """Origin allow-list for state-changing routes, safe 500s, security headers."""
    if (request.path == "/ws" or request.method not in ("GET", "HEAD")) and not origin_allowed(request):
        log.warning("rejected origin %r for %s %s", request.headers.get("Origin"), request.method, request.path)
        raise web.HTTPForbidden(text="origin not allowed")
    try:
        resp = await handler(request)
    except web.HTTPException:
        raise
    except Exception:
        log.exception("unhandled error on %s %s", request.method, request.path)
        return web.json_response({"error": "internal server error"}, status=500)
    if not resp.prepared:  # websocket responses are already on the wire
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "no-referrer")
    return resp


async def ws_handler(request):
    ws = web.WebSocketResponse(heartbeat=30, max_msg_size=1 << 20)
    await ws.prepare(request)
    if client is None:
        await ws.close(code=WSCloseCode.TRY_AGAIN_LATER, message=b"server missing API key")
        return ws
    request.app["websockets"].add(ws)

    # unknown/absent character falls back to the default rather than erroring
    character = CHARACTERS.get(request.query.get("character", ""), CHARACTERS[DEFAULT_CHARACTER])

    # -- memory: resolve identity and load once, before the Live session starts
    uid = resolve_uid(request)
    user_row = await memory.touch_user(uid)
    mem_section = memory.format_memory_section(user_row)
    system_instruction = character["intro"] + SHARED_PERSONA + ("\n\n" + mem_section if mem_section else "")

    session_id = uuid.uuid4().hex
    await memory.start_session(session_id, uid)

    # completed-turn capture: streaming transcript fragments accumulate here and
    # are persisted only when a turn finishes (or is interrupted)
    bufs = {"user": "", "sakura": ""}
    turns_recorded = 0

    def record(role, text):
        nonlocal turns_recorded
        text = text.strip()
        if not text:
            return
        # fire-and-forget: DB writes never sit in the audio relay path
        bg(memory.add_turn(session_id, uid, role, text))
        turns_recorded += 1
        if turns_recorded % memory.UPDATE_TURN_THRESHOLD == 0:
            bg(memory.update_user_memory(uid, extract))

    def flush(role):
        record(role, bufs[role])
        bufs[role] = ""

    try:
        async with client.aio.live.connect(model=MODEL, config=build_config(system_instruction, character)) as session:

            async def gemini_to_browser():
                try:
                    while True:
                        async for resp in session.receive():
                            if resp.data:  # 24 kHz pcm16 voice chunk
                                await ws.send_bytes(resp.data)
                            if resp.tool_call and resp.tool_call.function_calls:
                                fr = []
                                for fc in resp.tool_call.function_calls:
                                    update, result = scene_tool_call(fc.name, fc.args, character["outfits"])
                                    if update:
                                        await ws.send_json({"type": "set_scene", **update})
                                    fr.append(types.FunctionResponse(id=fc.id, name=fc.name, response=result))
                                await session.send_tool_response(function_responses=fr)
                            sc = resp.server_content
                            if sc is None:
                                continue
                            if sc.interrupted:
                                await ws.send_json({"type": "interrupted"})
                                flush("sakura")  # keep what she actually got to say
                            if sc.input_transcription and sc.input_transcription.text:
                                await ws.send_json({"type": "you", "text": sc.input_transcription.text})
                                bufs["user"] += sc.input_transcription.text
                            if sc.output_transcription and sc.output_transcription.text:
                                await ws.send_json({"type": "her", "text": sc.output_transcription.text})
                                bufs["sakura"] += sc.output_transcription.text
                            if sc.turn_complete:
                                await ws.send_json({"type": "turn_complete"})
                                flush("user")
                                flush("sakura")
                except asyncio.CancelledError:
                    raise
                except Exception:  # surface Gemini-side failures in the logs
                    log.exception("gemini_to_browser failed")
                    await ws.close()

            pump = asyncio.create_task(gemini_to_browser())
            try:
                async for msg in ws:
                    if msg.type == WSMsgType.BINARY:
                        await session.send_realtime_input(
                            audio=types.Blob(data=msg.data, mime_type="audio/pcm;rate=16000")
                        )
                    elif msg.type == WSMsgType.TEXT:
                        try:
                            data = json.loads(msg.data)
                        except ValueError:
                            continue
                        if data.get("type") == "text" and data.get("text"):
                            record("user", data["text"])  # typed turns are already complete
                            await session.send_client_content(
                                turns=types.Content(role="user", parts=[types.Part(text=data["text"])]),
                                turn_complete=True,
                            )
                        elif data.get("type") == "scene":
                            note = (
                                f"[Scene update: you are wearing your {data.get('outfit', '?')} outfit "
                                f"and you are at this location: {data.get('background', '?')}.]"
                            )
                            if data.get("announce"):
                                note += " React with one short, cheerful in-character line about your new look or surroundings."
                            # announce=False just adds context without triggering a spoken reply
                            await session.send_client_content(
                                turns=types.Content(role="user", parts=[types.Part(text=note)]),
                                turn_complete=bool(data.get("announce")),
                            )
            finally:
                pump.cancel()
    except Exception:
        log.exception("live session failed (uid %s…)", uid[:8])
    finally:
        request.app["websockets"].discard(ws)
        # -- session over: persist any tail turns, then extract memory in the background
        for role in ("user", "sakura"):
            text = bufs[role].strip()
            if text:
                await memory.add_turn(session_id, uid, role, text)
                turns_recorded += 1
        await memory.end_session(session_id)
        if turns_recorded:
            bg(memory.update_user_memory(uid, extract))
    return ws


async def index(request):
    uid = resolve_uid(request)
    # Social crawlers require absolute og:image/og:url; substitute per request.
    html = (ROOT / "static" / "index.html").read_text(encoding="utf-8")
    html = html.replace("__SITE_ORIGIN__", site_origin(request))
    resp = web.Response(text=html, content_type="text/html", charset="utf-8")
    secure = request.headers.get("X-Forwarded-Proto", request.scheme) == "https"
    resp.set_cookie(UID_COOKIE, uid, max_age=UID_COOKIE_MAX_AGE,
                    httponly=True, samesite="Lax", secure=secure)
    return resp


async def favicon(request):
    """Browsers still probe /favicon.ico by default; serve the real ICO there."""
    return web.FileResponse(ROOT / "assets" / "favicons" / "favicon.ico")


async def health(request):
    """Instant liveness probe for Railway: no Gemini call, no DB query."""
    checks = {"memory": request.app.get("db_ready", False), "gemini_key": client is not None}
    ok = all(checks.values())
    return web.json_response({"status": "ok" if ok else "degraded", **checks},
                             status=200 if ok else 503)


# ---- memory endpoints: always scoped to the caller's own cookie identity ----
async def memory_get(request):
    return web.json_response(await memory.get_view(resolve_uid(request)))


async def memory_put(request):
    uid = resolve_uid(request)
    try:
        doc = await request.json()
    except Exception:
        return web.json_response({"error": "invalid JSON"}, status=400)
    await memory.save_memory(uid, doc)  # bound_memory inside discards anything invalid
    return web.json_response(await memory.get_view(uid))


async def memory_clear(request):
    uid = resolve_uid(request)
    await memory.clear_user(uid)
    return web.json_response({"ok": True})


async def on_startup(app):
    await asyncio.to_thread(memory.init_db)
    app["db_ready"] = True
    log.info("db ready at %s", memory.DB_PATH)


async def on_shutdown(app):
    # closing the websockets unblocks every ws_handler, which then persists its
    # tail turns and queues a final memory extraction before the server exits
    for ws in set(app["websockets"]):
        await ws.close(code=WSCloseCode.GOING_AWAY, message=b"server shutting down")


async def on_cleanup(app):
    if _bg_tasks:  # runs after all handlers have finished: flush pending DB/memory work
        log.info("waiting for %d background task(s)", len(_bg_tasks))
        await asyncio.wait(_bg_tasks, timeout=15)


app = web.Application(client_max_size=64 * 1024, middlewares=[guard])
app["websockets"] = set()
app.on_startup.append(on_startup)
app.on_shutdown.append(on_shutdown)
app.on_cleanup.append(on_cleanup)
app.router.add_get("/", index)
app.router.add_get("/favicon.ico", favicon)
app.router.add_get("/health", health)
app.router.add_get("/ws", ws_handler)
app.router.add_get("/memory", memory_get)
app.router.add_put("/memory", memory_put)
app.router.add_post("/memory/clear", memory_clear)
app.router.add_static("/static", ROOT / "static")
app.router.add_static("/assets", ROOT / "assets")

if __name__ == "__main__":
    web.run_app(
        app,
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", 8787)),
    )
