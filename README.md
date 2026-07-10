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

Conversation memory is **not stored** in this app. Turns live only inside the
active Gemini Live session for as long as the browser WebSocket stays open.

- Refresh, close the tab, or restart the server → new session → blank slate.
- The on-screen chat log in `static/app.js` is display-only (capped at ~40
  bubbles); it is not fed back as history.
- Long sessions use Gemini’s `context_window_compression` (sliding window in
  `CONFIG`) to trim context on the API side — still not local persistence.

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
