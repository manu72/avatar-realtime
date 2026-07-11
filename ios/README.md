# Sakura for iOS

A fully self-contained native port of the voice-chat web app — pick **Sakura**
(the default) or **Namu** on the start screen, then chat by voice. It talks
**directly to the Gemini Live API** — the Python server (`server.py`) is not
used, not required, and not touched. This is an MVP for local testing on a
small number of physical iPhones, not an App Store build.

## Requirements

- Xcode 16 or newer (built and tested with Xcode 26.4)
- iOS 17.0+ iPhone
- A free Apple Developer account signed into Xcode (for device signing)
- A Gemini API key from https://aistudio.google.com/apikey

## Architecture

```
ios/Sakura/
├── App/         SakuraApp (entry, lifecycle), SessionViewModel (orchestrator)
├── Views/       ContentView (stage, chips, transcript, input), MemoryView
├── Models/      Persona + config constants, TurnBuffer (transcript consolidation)
├── Gemini/      GeminiLiveClient (WebSocket), GeminiMessages (Codable protocol)
├── Audio/       AudioSystem — one AVAudioEngine for mic, playback and lip-sync level
├── Avatar/      Wardrobe (outfits/backgrounds), AvatarView (3-frame mouth)
├── Memory/      MemoryModels, MemoryStore (atomic JSON), MemoryExtractor (Gemini text call)
└── Resources/   Sprites + backgrounds copied from ../assets (web assets untouched)
```

The web app's `server.py` + `app.js` are the behavioural reference: same
model (`gemini-3.1-flash-live-preview`), same characters and voices (Sakura:
Leda, Namu: Puck), same persona text, same VAD/barge-in tuning, same memory
document shape and extraction prompt.

## How Gemini Live is connected

`GeminiLiveClient` opens a WebSocket with `URLSessionWebSocketTask` to:

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<API_KEY>
```

The first message is a `setup` payload (model, AUDIO response modality, the
character's voice, system instruction with the memory block appended, high-sensitivity
VAD with 100 ms prefix padding, input/output transcription, context-window
compression). After `setupComplete`, mic audio streams up as `realtimeInput`
chunks and typed messages go as `clientContent` turns. Server frames carry
voice audio (`inlineData`), transcriptions, `interrupted` and `turnComplete`.

## Audio formats

- **Upstream:** 16 kHz mono 16-bit PCM, little-endian, base64 in JSON,
  shipped in ~32 ms chunks (mic is captured at hardware rate and resampled
  with `AVAudioConverter`).
- **Downstream:** 24 kHz mono 16-bit PCM, scheduled gaplessly onto an
  `AVAudioPlayerNode`.
- The audio session uses `.playAndRecord` + `.voiceChat`, and echo
  cancellation is enabled explicitly with
  `inputNode.setVoiceProcessingEnabled(true)` — Apple's VoIP voice-processing
  unit subtracts the engine's own playback from the mic capture so Sakura's
  voice doesn't feed back and get transcribed as the user speaking.
- **Barge-in:** two layers, like the web app — Gemini's `interrupted` signal
  clears the queue, and a local RMS gate (~100 ms of sustained voice while
  she is speaking) mutes playback instantly without waiting for the
  round-trip.
- **Lip sync:** a tap on the output mixer measures RMS; <0.015 closed,
  <0.055 half, else open (with a random flutter), frames held ≥70 ms.

## API key configuration — and its risk

1. `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig`
2. Put your real key in `GEMINI_API_KEY` (and optionally your
   `DEVELOPMENT_TEAM` ID).
3. Build. The key flows xcconfig → Info.plist → `AppConfig.geminiAPIKey`.

`Secrets.xcconfig` is gitignored. **The key is embedded in the built app's
Info.plist and is trivially recoverable by anyone with the binary.** That is
an accepted trade-off for installing on your own controlled test devices
only. Do not distribute builds, do not TestFlight this, and treat the key as
compromised if a device is lost. A production app would need a token-vending
backend instead.

## Running on a physical iPhone

1. `open ios/Sakura.xcodeproj`
2. Xcode ▸ Settings ▸ Accounts: sign in, then select your team under
   *Sakura target ▸ Signing & Capabilities* (or set `DEVELOPMENT_TEAM` in
   `Secrets.xcconfig`). If the bundle ID collides, change
   `PRODUCT_BUNDLE_IDENTIFIER`.
3. Create `Config/Secrets.xcconfig` as above with your Gemini key.
4. Plug in the iPhone, select it as the run destination, press Run.
5. First install: on the phone, Settings ▸ General ▸ VPN & Device
   Management ▸ trust your developer certificate.
6. Launch and pick a character on the start screen (tapping elsewhere starts
   Sakura, the default) — the microphone permission prompt
   appears immediately (audio can't start without it: the engine is
   deliberately not initialised until permission resolves). Grant it, then
   tap the mic button and talk.
7. Test interruption: talk over her mid-reply — playback should cut within
   ~100 ms and she should yield.
8. Test memory: mention your name, chat a few turns, kill the app, reopen —
   the 🧠 sheet should show her notes and she should not re-introduce herself.

## Memory behaviour

- One atomic JSON file: `Application Support/Sakura/memory.json`
  (document + counters + not-yet-extracted transcript turns; bounded to
  15 facts / 10 preferences / 8 projects / 600-char summary / 160 turns).
- Loaded **once** at session start, formatted into a plain-text block, and
  appended to the persona before connecting — no per-response retrieval.
- Completed turns are buffered; every 12 recorded turns (and at session end /
  backgrounding) a background `gemini-2.5-flash` JSON request folds them into
  the document. Extraction failure leaves the previous memory untouched.
- **To inspect/edit/clear:** tap the 🧠 button. "Forget all" wipes the file.

## Tests

```
xcodebuild test -project ios/Sakura.xcodeproj -scheme Sakura \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

28 tests cover memory encoding/bounding/persistence/atomic-replace/clear,
failed-extraction rollback, transcript turn consolidation, and Gemini message
parsing/encoding. No test touches the network or needs an API key.

## Current limitations

- Backgrounding ends the live session (audio + socket torn down safely;
  memory extraction still runs). Foregrounding reconnects; re-tap the mic.
- The Gemini Live session is subject to server-side time limits; the app
  auto-reconnects after 1.5 s, starting a fresh session with updated memory.
- Local barge-in uses a fixed RMS threshold (0.04); noisy rooms may need it
  raised in `AudioSystem.accumulate`.
- Portrait-only, light mode, iPhone-only. No CallKit, no background audio.

## Troubleshooting

- **"Gemini API key missing" alert** — `Config/Secrets.xcconfig` absent or
  still holding the placeholder; create it and rebuild (a rebuild is required
  after changing xcconfig values).
- **Connects then immediately drops** — key invalid or Live API quota
  exhausted; check the key in AI Studio.
- **She can't hear you** — mic permission denied; Settings ▸ Sakura ▸
  Microphone.
- **"Audio couldn't start" / console shows `561015905` ('!pla')** — the
  engine tried to initialise a `.playAndRecord` route it can't open. The app
  starts audio only after permission is granted and rebuilds the graph on
  route changes; if it still fails, disconnect Bluetooth audio, quit other
  audio apps, and tap again. Audio lifecycle logs are under subsystem
  `com.throwingeights.sakura`, category `audio`, in Console.app.
- **Echo / self-interruption (Sakura "hears herself")** — check Console for
  `voice processing (AEC) enabled`; if it shows
  `voice processing enable failed`, the current route refused the
  voice-processing unit — disconnect Bluetooth audio and relaunch.
- **No audio out on device but transcript works** — check the silent/ring
  switch; the session uses `.defaultToSpeaker`.
