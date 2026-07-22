# Sakura ✿ Chat

A tiny roleplaying web app: talk to an anime companion by voice or text. Pick a
character on the splash screen — **Sakura** (pink-haired, green-eyed anime woman,
the default) or **Namu** (dark-haired, green-eyed muscular anime man). Both are
adult anime characters who answer in real time with their own voice (Gemini Live
API), and their sprites lip-sync to the audio.

Two independent implementations live in this repository:

- **Web app** (this directory) — Python `server.py` relay + browser client,
  run as documented below.
- **Native iOS app** (`ios/`) — self-contained Swift/SwiftUI port that talks
  directly to Gemini Live; it does not use `server.py` at all. Setup and docs:
  [`ios/README.md`](ios/README.md).

Neither depends on the other at runtime; each is runnable on its own.

## Run locally

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
echo 'GEMINI_API_KEY=your-key' > .env   # if not already present
.venv/bin/python server.py
```

Open http://127.0.0.1:8787, pick a character (clicking anywhere else starts
Sakura, the default), then type — or hit the mic button and just talk. You can
interrupt mid-sentence by speaking.

## Deploy to Railway

The repo deploys straight from GitHub: [`railway.json`](railway.json) carries the
start command, health check (`/health`) and restart policy; `.python-version`
pins Python 3.12; dependencies come from `requirements.txt`. Set
`GEMINI_API_KEY`, attach a volume at `/data` and set `SAKURA_DATA_DIR=/data`
so the SQLite memory survives redeploys. Full walkthrough (account setup →
troubleshooting): [`RAILWAY_DEPLOYMENT.md`](RAILWAY_DEPLOYMENT.md).

In production the same single aiohttp process does everything: serves the
static app and sprites, relays the browser WebSocket to Gemini Live, and runs
background memory extraction. WebSocket origins are checked (same-origin plus
`ALLOWED_ORIGINS`), errors return generic 500s, and SIGTERM triggers a graceful
shutdown that closes WebSockets and flushes pending memory writes. SQLite is
single-writer — run **one replica**.

### Environment variables

| Variable                | Default                      | Purpose                                                                    |
| ----------------------- | ---------------------------- | -------------------------------------------------------------------------- |
| `GEMINI_API_KEY`        | — (required)                 | Gemini API key for Live voice + memory extraction                          |
| `PORT`                  | `8787`                       | Listen port (Railway sets this automatically)                              |
| `HOST`                  | `0.0.0.0`                    | Bind address                                                               |
| `LOG_LEVEL`             | `INFO`                       | Python logging level                                                       |
| `ALLOWED_ORIGINS`       | unset                        | Extra allowed browser origins, comma-separated; same-origin always allowed |
| `SITE_URL`              | request host                 | Canonical public origin for OG/Twitter/canonical URLs (e.g. `https://sakura.example.com`) |
| `SAKURA_DATA_DIR`       | repo dir                     | Directory for `sakura.db` (created automatically; use `/data` on Railway)  |
| `SAKURA_DB_PATH`        | `$SAKURA_DATA_DIR/sakura.db` | Exact DB file path override                                                |
| `SAKURA_MEMORY_MODEL`   | `gemini-2.5-flash`           | Text model used for memory extraction                                      |
| `SAKURA_MAX_FACTS` etc. | see `memory.py`              | Memory size caps and update threshold                                      |

## How it works

- **`server.py`** — aiohttp server that serves the static app and relays a
  WebSocket between the browser and `gemini-3.1-flash-live-preview`. The
  `?character=` query param on `/ws` selects the persona, prebuilt voice
  (Sakura: Leda, Namu: Enceladus) and outfit allow-list from the `CHARACTERS` dict.
  Binary frames are raw PCM audio (16 kHz up, 24 kHz down); JSON frames carry
  transcripts / turn events. The characters can also change their own outfit
  and the background via Gemini function calling (`set_outfit` /
  `set_background`), validated server-side against the same allow-lists.
- **`static/app.js`** — mic capture via an inline AudioWorklet, gapless
  scheduled playback via Web Audio, and lip sync: an AnalyserNode measures the
  RMS loudness of whatever is currently playing and picks one of three mouth
  sprites (closed / half / open) every 40 ms.
- **`assets/`** — character sprites generated with GPT Image 2: one base image
  per character, then image-to-image edits that change _only_ the mouth (and
  outfit swaps), backgrounds removed so they composite over any scene. Six
  painted backgrounds, shared by both characters.

## Project structure

```
server.py              aiohttp server: static files, /ws relay, /health, /memory API
memory.py              SQLite persistence + Gemini text extraction (stdlib sqlite3)
test_memory.py         unit tests for memory.py (extraction mocked, no API needed)
test_tools.py          unit tests for the scene-tool allow-list validation
requirements.txt       google-genai + aiohttp (the only dependencies)
railway.json           Railway deploy config (start command, health check)
.python-version        Python 3.12 (used by Railway's builder)
static/
  index.html           single page: layout, styling, character-select splash
  app.js               characters, mic worklet, playback, lip sync, pickers, memory panel
assets/
  sprites/*.webp       mouth frames per outfit (closed/half/open); namu_* = Namu's
  bg/*.webp            painted background scenes
  sakura-og.webp       primary Open Graph / Twitter share image (1200×800)
  favicons/            browser + PWA icons + site.webmanifest
ios/                   independent native SwiftUI app (own README, own tests);
                       talks directly to Gemini Live, never uses server.py
RAILWAY_DEPLOYMENT.md  step-by-step Railway guide
sakura.db              created at runtime (gitignored), location configurable
```

## Personality

Each character's persona is a short `intro` string in the `CHARACTERS` dict in
`server.py`, concatenated with the shared `SHARED_PERSONA` rules (tone, quirks,
tool etiquette). Each WebSocket connection passes the result to Gemini Live as
`system_instruction` (built per connection, with the caller's memory notes
appended when they exist).

Edit those strings to change tone, length, quirks, or backstory — then restart
the server. There is no separate prompt file or UI for this.

## Memory

Sakura keeps a lightweight persistent memory per anonymous visitor (`memory.py`,
SQLite via stdlib `sqlite3`, stored in `sakura.db` next to `server.py` by
default — point it elsewhere with `SAKURA_DATA_DIR` or `SAKURA_DB_PATH`).

**How it works**

- Each browser gets a random anonymous ID in a long-lived `sakura_uid` cookie
  (no accounts). A missing or mangled cookie just gets a fresh ID.
- When a WebSocket session starts, the user's compact memory document is loaded
  **once**, formatted into a bounded plain-text block (≤ ~1k tokens), and
  appended to the persona as part of the Gemini Live `system_instruction`.
  Memory is never queried again during the conversation, so the real-time
  voice path is untouched.
- Completed text transcript turns (user + character, no audio, no streaming
  fragments) are saved per session with start/end timestamps.
- After a session disconnects — and additionally every
  `SAKURA_UPDATE_TURN_THRESHOLD` (default 12) completed turns — a background
  task sends the old memory plus only the _unprocessed_ turns to a fast Gemini
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

**Limitations**: identity is per-browser (clear cookies → they forget you);
memory is shared across characters (Namu knows what you told Sakura);
extraction quality depends on the text model; graceful shutdown flushes pending
memory writes (a hard kill can still lose the last extraction); the on-screen
chat log is still display-only.

Tests: `.venv/bin/python -m unittest test_memory -v` (extraction is mocked; no
API access needed).

## Voice model

- **Model:** `models/gemini-3.1-flash-live-preview` (`MODEL` in `server.py`)
- **Voices:** Gemini prebuilt voices — Sakura: `Leda`, Namu: `Enceladus`
- **Audio:** browser mic up at 16 kHz PCM; character voice down at 24 kHz PCM

Change a voice by editing that character's `voice` in the `CHARACTERS` dict in
`server.py` (other Gemini Live prebuilt voices), then restart the server.

## Visual characteristics

Both characters are rendered as layered WEBP sprites with transparent
backgrounds so they composite over any scene. Mouth states `closed` / `half` /
`open` are lip-synced from playback RMS every ~40 ms.

| Aspect  | Sakura                                                                                                                               | Namu                                                                                                  |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Look    | Long light-pink hair, bright green eyes                                                                                              | Short dark tousled hair, bright green eyes, muscular                                                  |
| Outfits | Gymwear (`gym_*`), Sundress (`casual_*`), Swimsuit (`swim2_*`), Seifuku (`uniform_*`), Nightgown (`night_*`) under `assets/sprites/` | Gymwear (`namu_gym_*`), Casual (`namu_casual_*`), Swimtogs (`namu_swim_*`), Pajamas (`namu_pajama_*`) |

Backgrounds are shared: Mt Fuji, Sakura park, Beach, Onsen, Gym, Bedroom
(`assets/bg/`); a CSS “Dream” gradient exists but is commented out in `app.js`.

Sprites were generated with GPT Image 2 (base image per character, then
image-to-image mouth and outfit edits; Namu's base was derived from Sakura's to
keep the art style identical). Switch looks with the top-right chips, or add
your own by dropping a WEBP into `assets/` and one line into `CHARACTERS` or
`BACKGROUNDS` in `static/app.js`.
