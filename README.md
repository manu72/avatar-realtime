# Sakura ✿ Chat

A tiny roleplaying web app: talk to Sakura — a pink-haired, green-eyed anime girl —
by voice or text. She answers in real time with her own voice (Gemini Live API),
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
  then image-to-image edits that change *only* the mouth (and one outfit swap),
  backgrounds removed so she composites over any scene. Two painted backgrounds
  plus a CSS-gradient one.

## Switching looks

Top-right chips: backgrounds (Bedroom / Sakura park / Dream gradient) and
outfits (Seifuku / Sundress). Add your own by dropping a PNG into `assets/`
and adding one line to `SPRITES` or `BACKGROUNDS` in `static/app.js`.
