# Sakura ✿ Chat

A tiny roleplaying web app: talk to Sakura — a pink-haired, green-eyed anime woman —
by voice or text. Sakura is an adult anime character who answers in real time with her own voice (Gemini Live API),
and her sprite lip-syncs to the audio.

## Run

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
echo 'GEMINI_API_KEY=your-key' > .env   # if not already present
.venv/bin/python server.py
```

Open http://127.0.0.1:8787, click once to enable audio, then type — or hit the
mic button and just talk. You can interrupt her mid-sentence by speaking.

## How it works

- **`server.py`** — aiohttp server that serves the static app and relays a
  WebSocket between the browser and `gemini-3.1-flash-live-preview`
  (voice: Leda). Binary frames are raw PCM audio (16 kHz up, 24 kHz down);
  JSON frames carry transcripts / turn events.
- **`static/app.js`** — mic capture via an inline AudioWorklet, gapless
  scheduled playback via Web Audio, and lip sync: an AnalyserNode measures the
  RMS loudness of whatever is currently playing and picks one of three mouth
  sprites (closed / half / open) every 40 ms.
- **`assets/`** — character sprites generated with GPT Image 2: one base image,
  then image-to-image edits that change _only_ the mouth (and one outfit swap),
  backgrounds removed so she composites over any scene. Two painted backgrounds
  plus a CSS-gradient one.

## Personality

Sakura’s character is the `PERSONA` string in `server.py` (around lines 34–38).
It is passed to Gemini Live as `system_instruction` in `CONFIG`.

Edit that string to change tone, length, quirks, or backstory — then restart
the server. There is no separate prompt file or UI for this.

## Memory

Sakura keeps a lightweight persistent memory per anonymous visitor (`memory.py`,
SQLite via stdlib `sqlite3`, stored in `sakura.db` next to `server.py` —
override with `SAKURA_DB_PATH`).

**How it works**

- Each browser gets a random anonymous ID in a long-lived `sakura_uid` cookie
  (no accounts). A missing or mangled cookie just gets a fresh ID.
- When a WebSocket session starts, the user's compact memory document is loaded
  **once**, formatted into a bounded plain-text block (≤ ~1k tokens), and
  appended to `PERSONA` as part of the Gemini Live `system_instruction`.
  Memory is never queried again during the conversation, so the real-time
  voice path is untouched.
- Completed text transcript turns (user + Sakura, no audio, no streaming
  fragments) are saved per session with start/end timestamps.
- After a session disconnects — and additionally every
  `SAKURA_UPDATE_TURN_THRESHOLD` (default 12) completed turns — a background
  task sends the old memory plus only the *unprocessed* turns to a fast Gemini
  text model (`SAKURA_MEMORY_MODEL`, default `gemini-2.5-flash`) which returns
  a complete replacement memory document. A per-user lock plus a `processed`
  marker on each turn guarantee every turn is folded in at most once, even on
  duplicate disconnects. If extraction fails, the old memory is kept unchanged.

**What is retained**: facts you explicitly stated, durable preferences,
recurring projects/topics, open threads, plus a short relationship summary —
all size-capped (`SAKURA_MAX_FACTS` 15, `SAKURA_MAX_PREFERENCES` 10,
`SAKURA_MAX_PROJECTS` 8, `SAKURA_MAX_SUMMARY_CHARS` 600). Not retained:
inferences/guesses, Sakura's own claims, small talk, duplicates.

**Inspect / edit / clear**: click the 🧠 button in the app (or
`GET /memory`, `PUT /memory`, `POST /memory/clear`) — always scoped to your
own cookie. Changes apply from the next session.

**Privacy**: memories and recent text transcripts are stored as plain text in
a local SQLite file on the server — not encrypted, not synced anywhere. No
audio, cookies, or API keys are stored in memory documents.

**Limitations**: identity is per-browser (clear cookies → Sakura forgets you);
extraction quality depends on the text model; memory written by a session that
ends while the server is shutting down may be lost; the on-screen chat log is
still display-only.

Tests: `.venv/bin/python -m unittest test_memory -v` (extraction is mocked; no
API access needed).

## Voice model

- **Model:** `models/gemini-3.1-flash-live-preview` (`MODEL` in `server.py`)
- **Voice:** Gemini prebuilt voice `Leda` (`speech_config` → `voice_name`)
- **Audio:** browser mic up at 16 kHz PCM; Sakura’s voice down at 24 kHz PCM

Change the voice by editing `voice_name` in `CONFIG` (other Gemini Live
prebuilt voices), then restart the server.

## Visual characteristics

Sakura is a pink-haired, green-eyed anime girl rendered as layered PNG sprites
with transparent backgrounds so she composites over any scene.

| Aspect       | Details                                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------------------------ |
| Look         | Long light-pink hair, bright green eyes (described in `PERSONA`; drawn in sprites)                                       |
| Mouth states | `closed` / `half` / `open` — lip-synced from playback RMS every ~40 ms                                                   |
| Outfits      | Seifuku (`uniform_*.png`), Sundress (`casual_*.png`), Swimsuit (`swim_*.png`), Gym (`gym_*.png`) under `assets/sprites/` |
| Backgrounds  | Bedroom, Sakura park, Beach, Mt Fuji, Onsen (`assets/bg/`), plus a CSS “Dream” gradient                                  |

Sprites were generated with GPT Image 2 (base image, then image-to-image mouth
and outfit edits). Switch looks with the top-right chips, or add your own by
dropping a PNG into `assets/` and one line into `SPRITES` or `BACKGROUNDS` in
`static/app.js`.
