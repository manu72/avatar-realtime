/* Sakura Chat — frontend: mic capture, audio playback, lip sync, UI. */

const $ = (s) => document.querySelector(s);

/* ---------- assets ---------- */
const SPRITES = {
  "Gymwear 🏃‍♀️": {
    closed: "/assets/sprites/gym_closed.webp",
    half: "/assets/sprites/gym_half.webp",
    open: "/assets/sprites/gym_open.webp",
  },
  "Sundress 🌿": {
    closed: "/assets/sprites/casual_closed.webp",
    half: "/assets/sprites/casual_half.webp",
    open: "/assets/sprites/casual_open.webp",
  },
  "Swimsuit 🩱": {
    closed: "/assets/sprites/swim2_closed.webp",
    half: "/assets/sprites/swim2_half.webp",
    open: "/assets/sprites/swim2_half.webp",
  },
  "Seifuku 🎀": {
    closed: "/assets/sprites/uniform_closed.webp",
    half: "/assets/sprites/uniform_half.webp",
    open: "/assets/sprites/uniform_open.webp",
  },
  "Nightgown 🌙": {
    closed: "/assets/sprites/night_closed.webp",
    half: "/assets/sprites/night_half.webp",
    open: "/assets/sprites/night_open.webp",
  },
};
const BACKGROUNDS = {
  "Fuji 🗻": "url(/assets/bg/fuji.webp)",
  "Sakura 🌸": "url(/assets/bg/sakura.webp)",
  "Beach 🏖": "url(/assets/bg/beach.webp)",
  "Onsen ♨️": "url(/assets/bg/onsen.webp)",
  "Gym 🏋️": "url(/assets/bg/gym.webp)",
  "Bedroom 🛏": "url(/assets/bg/bedroom.webp)",
  // "Dream ☁️": "linear-gradient(160deg,#ffd9e8 0%,#e8d9ff 50%,#d0f4e0 100%)",
};

const mouthImgs = { closed: $("#m-closed"), half: $("#m-half"), open: $("#m-open") };

/* tell Sakura what she's wearing and where she is */
let ws; // declared here: sendScene runs during initial setOutfit, before the websocket section
let currentOutfit, currentBg, sceneTimer;
const cleanLabel = (s) => s.replace(/[^\p{L}\p{N} ]/gu, "").trim(); // drop chip emoji
function sendScene(announce = true) {
  if (!ws || ws.readyState !== 1) return;
  clearTimeout(sceneTimer); // debounce rapid chip-clicking into one update
  sceneTimer = setTimeout(
    () =>
      ws.send(
        JSON.stringify({
          type: "scene",
          outfit: cleanLabel(currentOutfit),
          background: cleanLabel(currentBg),
          announce,
        }),
      ),
    announce ? 600 : 0,
  );
}

function setOutfit(name) {
  for (const [state, img] of Object.entries(mouthImgs)) img.src = SPRITES[name][state];
  markOn("#outfit-picker", name);
  currentOutfit = name;
  sendScene();
}
function setBackground(name) {
  $("#stage").style.backgroundImage = BACKGROUNDS[name];
  markOn("#bg-picker", name);
  currentBg = name;
  sendScene();
}
function markOn(pickerSel, name) {
  for (const b of document.querySelectorAll(pickerSel + " button")) b.classList.toggle("on", b.textContent === name);
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
  for (const url of Object.values(outfit)) {
    const i = new Image();
    i.src = url;
  }

setOutfit(Object.keys(SPRITES)[0]);
setBackground(Object.keys(BACKGROUNDS)[0]);
mouthImgs.closed.classList.add("on");

function setMouth(state) {
  for (const [k, img] of Object.entries(mouthImgs)) img.classList.toggle("on", k === state);
}

/* ---------- status ---------- */
const statusEl = $("#status");
function setStatus(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || "";
}

/* ---------- websocket ---------- */
function connect() {
  ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => {
    setStatus("ready — talk to me!", "ok");
    sendScene(false);
  };
  ws.onclose = () => {
    setStatus("reconnecting…");
    setTimeout(connect, 1500);
  };
  ws.onmessage = (e) => {
    if (e.data instanceof ArrayBuffer) return playChunk(e.data);
    const m = JSON.parse(e.data);
    if (m.type === "interrupted") {
      stopPlayback();
      bubbles.her = null;
    } // close cut-off bubble
    else if (m.type === "turn_complete") {
      bubbles.you = bubbles.her = null;
    } else if (m.type === "you" || m.type === "her") appendTranscript(m.type, m.text);
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
let playCtx,
  analyser,
  nextT = 0;
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
  for (const s of active) {
    try {
      s.stop();
    } catch {}
  }
  active.clear();
  nextT = 0;
}

/* ---------- lip sync: amplitude of playing voice -> mouth frame ---------- */
const td = new Uint8Array(1024);
let mouth = "closed",
  lastSwap = 0;
function lipLoop() {
  const ts = performance.now();
  let rms = 0;
  if (analyser && active.size) {
    analyser.getByteTimeDomainData(td);
    let sum = 0;
    for (let i = 0; i < td.length; i++) {
      const v = (td[i] - 128) / 128;
      sum += v * v;
    }
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
  else next = mouth === "open" && Math.random() < 0.35 ? "half" : "open"; // flutter on loud vowels
  if (next !== mouth) {
    setMouth(next);
    mouth = next;
    lastSwap = ts;
  }
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
  // local barge-in: cut her playback the instant sustained voice hits the mic,
  // instead of waiting ~500ms for Gemini's interrupted signal to round-trip
  let voiceRun = 0;
  node.port.onmessage = (e) => {
    if (ws && ws.readyState === 1) ws.send(e.data);
    if (!active.size) {
      voiceRun = 0;
      return;
    } // only gate while she is speaking
    const i16 = new Int16Array(e.data);
    let sum = 0;
    for (let i = 0; i < i16.length; i++) {
      const v = i16[i] / 32768;
      sum += v * v;
    }
    // ponytail: fixed RMS threshold; adaptive ambient-noise floor if it misfires
    voiceRun = Math.sqrt(sum / i16.length) > 0.04 ? voiceRun + 1 : 0;
    if (voiceRun >= 3) {
      stopPlayback();
      voiceRun = 0;
    } // ~100ms of sustained voice
  };
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
// explicit Enter-to-send: implicit form submission is unreliable in embedded browsers
$("#msg").addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    $("#bar").requestSubmit();
  }
});

$("#bar").onsubmit = (e) => {
  e.preventDefault();
  const input = $("#msg");
  const text = input.value.trim();
  if (!text || !ws || ws.readyState !== 1) return;
  stopPlayback(); // sending a message interrupts her mid-sentence, like real conversation
  ws.send(JSON.stringify({ type: "text", text }));
  appendTranscript("you", text);
  bubbles.you = null;
  input.value = "";
};

/* ---------- memory panel ---------- */
const memModal = $("#mem-modal");
memModal.hidden = true;

function renderMemory(view) {
  const m = view.memory,
    p = m.profile;
  const row = (label, val) =>
    val && val.length
      ? `<dt>${label}</dt><dd>${Array.isArray(val) ? val.map((v) => "• " + v).join("<br>") : val}</dd>`
      : "";
  $("#mem-view").innerHTML =
    `<dl>` +
    `<dt>Chats so far</dt><dd>${view.interaction_count}${view.first_seen_at ? " (first met " + view.first_seen_at.slice(0, 10) + ")" : ""}</dd>` +
    row("Your name", p.preferred_name) +
    row("Facts", p.facts) +
    row("Preferences", p.preferences) +
    row("Projects & topics", p.projects) +
    row("Relationship notes", m.relationship_summary) +
    `</dl>` +
    (!p.preferred_name && !p.facts.length && !p.preferences.length && !p.projects.length && !m.relationship_summary
      ? "<p>Nothing yet — Sakura writes her notes shortly after each chat ends.</p>"
      : "");
  $("#mem-json").value = JSON.stringify(m, null, 2);
}

// XMLHttpRequest instead of fetch: some browser extensions monkey-patch
// window.fetch and can leave its promise pending forever; XHR is rarely touched
function api(method, url, body) {
  return new Promise((resolve, reject) => {
    const x = new XMLHttpRequest();
    x.open(method, url);
    x.timeout = 5000;
    x.onload = () => (x.status < 300 ? resolve(JSON.parse(x.responseText)) : reject(new Error("HTTP " + x.status)));
    x.onerror = () => reject(new Error("network error"));
    x.ontimeout = () => reject(new Error("timed out"));
    x.send(body);
  });
}

async function memoryAction(fn) {
  try {
    renderMemory(await fn());
  } catch (e) {
    // e.g. the server is still running pre-memory code
    $("#mem-view").textContent = "Couldn't load memory (" + e.message + "). Restart server.py and reload the page.";
  }
}

$("#mem-btn").onclick = () => {
  memModal.hidden = false;
  memoryAction(() => api("GET", "/memory"));
};
$("#mem-close").onclick = () => {
  memModal.hidden = true;
};
memModal.onclick = (e) => {
  if (e.target === memModal) memModal.hidden = true;
}; // click outside card closes
$("#mem-clear").onclick = () => {
  if (!confirm("Sakura will forget everything about you. Sure?")) return;
  memoryAction(async () => {
    await api("POST", "/memory/clear");
    return api("GET", "/memory");
  });
};
$("#mem-save").onclick = () => {
  let doc;
  try {
    doc = JSON.parse($("#mem-json").value);
  } catch {
    return alert("That's not valid JSON.");
  }
  memoryAction(() => api("PUT", "/memory", JSON.stringify(doc)));
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
/* called by the overlay's inline onclick in index.html */
window.bootApp = () => {
  ensurePlayCtx();
  playCtx.resume();
  connect();
};
