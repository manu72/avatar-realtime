/* Sakura Chat — frontend: mic capture, audio playback, lip sync, UI. */

const $ = (s) => document.querySelector(s);

/* ---------- assets ---------- */
const SPRITES = {
  "Seifuku 🎀":  { closed: "/assets/sprites/uniform_closed.png", half: "/assets/sprites/uniform_half.png", open: "/assets/sprites/uniform_open.png" },
  "Sundress 🌿": { closed: "/assets/sprites/casual_closed.png",  half: "/assets/sprites/casual_half.png",  open: "/assets/sprites/casual_open.png" },
};
const BACKGROUNDS = {
  "Bedroom 🛏":  "url(/assets/bg/bedroom.png)",
  "Sakura 🌸":  "url(/assets/bg/sakura.png)",
  "Dream ☁️":   "linear-gradient(160deg,#ffd9e8 0%,#e8d9ff 50%,#d0f4e0 100%)",
};

const mouthImgs = { closed: $("#m-closed"), half: $("#m-half"), open: $("#m-open") };

function setOutfit(name) {
  for (const [state, img] of Object.entries(mouthImgs)) img.src = SPRITES[name][state];
  markOn("#outfit-picker", name);
}
function setBackground(name) {
  $("#stage").style.backgroundImage = BACKGROUNDS[name];
  markOn("#bg-picker", name);
}
function markOn(pickerSel, name) {
  for (const b of document.querySelectorAll(pickerSel + " button"))
    b.classList.toggle("on", b.textContent === name);
}
function buildPicker(sel, names, onPick) {
  const el = $(sel);
  for (const name of names) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = name;
    b.onclick = () => onPick(name);
    el.appendChild(b);
  }
}
buildPicker("#bg-picker", Object.keys(BACKGROUNDS), setBackground);
buildPicker("#outfit-picker", Object.keys(SPRITES), setOutfit);

// preload every sprite so mouth swaps never flicker
for (const outfit of Object.values(SPRITES))
  for (const url of Object.values(outfit)) { const i = new Image(); i.src = url; }

setOutfit(Object.keys(SPRITES)[0]);
setBackground(Object.keys(BACKGROUNDS)[0]);
mouthImgs.closed.classList.add("on");

function setMouth(state) {
  for (const [k, img] of Object.entries(mouthImgs)) img.classList.toggle("on", k === state);
}

/* ---------- status ---------- */
const statusEl = $("#status");
function setStatus(text, cls) { statusEl.textContent = text; statusEl.className = cls || ""; }

/* ---------- websocket ---------- */
let ws;
function connect() {
  ws = new WebSocket(`ws://${location.host}/ws`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => setStatus("ready — talk to me!", "ok");
  ws.onclose = () => { setStatus("reconnecting…"); setTimeout(connect, 1500); };
  ws.onmessage = (e) => {
    if (e.data instanceof ArrayBuffer) return playChunk(e.data);
    const m = JSON.parse(e.data);
    if (m.type === "interrupted") stopPlayback();
    else if (m.type === "turn_complete") { bubbles.you = bubbles.her = null; }
    else if (m.type === "you" || m.type === "her") appendTranscript(m.type, m.text);
  };
}

/* ---------- chat log ---------- */
const log = $("#log");
const bubbles = { you: null, her: null };
function appendTranscript(role, text) {
  if (!bubbles[role]) {
    bubbles[role] = document.createElement("div");
    bubbles[role].className = "bub " + role;
    log.appendChild(bubbles[role]);
    while (log.children.length > 40) log.firstChild.remove();
  }
  bubbles[role].append(text);
  log.scrollTop = log.scrollHeight;
}

/* ---------- voice playback (24 kHz pcm16) ---------- */
let playCtx, analyser, nextT = 0;
const active = new Set();

function ensurePlayCtx() {
  if (playCtx) return;
  playCtx = new AudioContext({ sampleRate: 24000 });
  analyser = playCtx.createAnalyser();
  analyser.fftSize = 1024;
  analyser.connect(playCtx.destination);
}

function playChunk(arrayBuffer) {
  ensurePlayCtx();
  const i16 = new Int16Array(arrayBuffer);
  const buf = playCtx.createBuffer(1, i16.length, 24000);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < i16.length; i++) ch[i] = i16[i] / 32768;
  const src = playCtx.createBufferSource();
  src.buffer = buf;
  src.connect(analyser);
  const t = Math.max(playCtx.currentTime + 0.06, nextT);
  src.start(t);
  nextT = t + buf.duration;
  active.add(src);
  src.onended = () => active.delete(src);
}

function stopPlayback() {
  for (const s of active) { try { s.stop(); } catch {} }
  active.clear();
  nextT = 0;
}

/* ---------- lip sync: amplitude of playing voice -> mouth frame ---------- */
const td = new Uint8Array(1024);
let mouth = "closed", lastSwap = 0;
function lipLoop() {
  const ts = performance.now();
  let rms = 0;
  if (analyser && active.size) {
    analyser.getByteTimeDomainData(td);
    let sum = 0;
    for (let i = 0; i < td.length; i++) { const v = (td[i] - 128) / 128; sum += v * v; }
    rms = Math.sqrt(sum / td.length);
  }
  const talking = rms > 0.015;
  document.body.classList.toggle("speaking", talking);
  if (talking) setStatus("Sakura is speaking ♪", "talk");
  else if (statusEl.classList.contains("talk")) setStatus("ready — talk to me!", "ok");

  if (ts - lastSwap < 70) return; // hold each frame ≥70ms so it reads as speech
  let next;
  if (rms < 0.015) next = "closed";
  else if (rms < 0.055) next = "half";
  else next = (mouth === "open" && Math.random() < 0.35) ? "half" : "open"; // flutter on loud vowels
  if (next !== mouth) { setMouth(next); mouth = next; lastSwap = ts; }
}
// ponytail: setInterval over rAF — keeps animating when the tab is occluded/throttled
setInterval(lipLoop, 40);

/* ---------- mic capture (16 kHz pcm16 via AudioWorklet) ---------- */
const WORKLET = `
class Pcm16 extends AudioWorkletProcessor {
  constructor() { super(); this.chunks = []; this.len = 0; }
  process(inputs) {
    const ch = inputs[0][0];
    if (ch) {
      this.chunks.push(new Float32Array(ch));
      this.len += ch.length;
      if (this.len >= 512) { // ~32ms at 16kHz per message
        const out = new Int16Array(this.len);
        let i = 0;
        for (const c of this.chunks)
          for (const s of c) out[i++] = Math.max(-1, Math.min(1, s)) * 32767;
        this.port.postMessage(out.buffer, [out.buffer]);
        this.chunks = []; this.len = 0;
      }
    }
    return true;
  }
}
registerProcessor("pcm16", Pcm16);`;

let micCtx, micStream;
const micBtn = $("#mic");

async function startMic() {
  micStream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 },
  });
  micCtx = new AudioContext({ sampleRate: 16000 });
  const url = URL.createObjectURL(new Blob([WORKLET], { type: "application/javascript" }));
  await micCtx.audioWorklet.addModule(url);
  const node = new AudioWorkletNode(micCtx, "pcm16");
  node.port.onmessage = (e) => { if (ws && ws.readyState === 1) ws.send(e.data); };
  micCtx.createMediaStreamSource(micStream).connect(node);
  micBtn.classList.add("live");
  setStatus("listening…", "ok");
}

function stopMic() {
  micStream?.getTracks().forEach((t) => t.stop());
  micCtx?.close();
  micCtx = micStream = null;
  micBtn.classList.remove("live");
  setStatus("ready — talk to me!", "ok");
}

micBtn.onclick = () => (micCtx ? stopMic() : startMic().catch((e) => setStatus("mic blocked: " + e.message)));

/* ---------- text input ---------- */
$("#bar").onsubmit = (e) => {
  e.preventDefault();
  const input = $("#msg");
  const text = input.value.trim();
  if (!text || !ws || ws.readyState !== 1) return;
  ws.send(JSON.stringify({ type: "text", text }));
  appendTranscript("you", text);
  bubbles.you = null;
  input.value = "";
};

/* ---------- petals ---------- */
for (let i = 0; i < 10; i++) {
  const p = document.createElement("span");
  p.className = "petal";
  p.textContent = Math.random() < 0.5 ? "🌸" : "✿";
  p.style.left = Math.random() * 100 + "vw";
  p.style.fontSize = 12 + Math.random() * 16 + "px";
  p.style.animationDuration = 9 + Math.random() * 14 + "s";
  p.style.animationDelay = -Math.random() * 20 + "s";
  document.body.appendChild(p);
}

/* ---------- boot: browsers require a gesture before audio ---------- */
$("#boot").onclick = () => {
  $("#boot").remove();
  ensurePlayCtx();
  playCtx.resume();
  connect();
};
