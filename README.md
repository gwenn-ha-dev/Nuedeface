# Nuedeface

[![CI](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml/badge.svg)](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5%2B%20·%20swiftc%20·%20zero%20dependencies-orange?logo=swift)

*🇬🇧 English · 🇫🇷 [Français](./README.fr.md)*

<p align="center"><img src="docs/img/hero.png" width="900" alt="Nuedeface — timeline with waveforms and automation, console with a legible node-EQ and live meters"></p>

> A pun in French: *Nuendo* → *nu en dos* ("bare-backed") → ***nue de face*** ("bare, face-on").
> Where the old DAWs turn their back on you (gas-factory UIs, everything buried in menus), Nuedeface
> shows everything, face-on, legible. The name **is** the thesis.

**Simple mixing, held to a quality bar — native macOS, GarageBand-inspired, *headless*, driven by a Unix
socket.** One surface, three clients: **you** (the native UI), **an AI** — *any* AI, not just Claude — and a
**script**, all speaking the same JSON protocol. Every effect and processor is **native Apple** (AVAudioEngine
+ Audio Units), pushed as far as it goes — no hand-rolled DSP. The AI can **mix for you while you keep
control**: you watch each move land live and can take the wheel at any moment.

<p align="center"><img src="docs/img/demo.gif" width="900" alt="An AI builds a podcast mix live over the socket — track trim, in/out fades, band-by-band EQ, hand-set compression, ducking, then the master chain — while you watch"></p>

<p align="center"><sub><b>An AI mixes a podcast, live, over the socket</b> — track trim · in/out fades · band-by-band EQ · hand-set compression · ducking · master chain (EQ · comp · limiter · −16 LUFS). Every move is a JSON verb you could type yourself.</sub></p>

> *Status: working prototype.* Core + API + UI operational and proven (measured validation benches +
> socket scenes on real files).

---

## Why

For simple mixing, GarageBand's engine does the job but its presentation is illegible (incomprehensible
EQ, effects hidden away). Audacity doesn't have the Mac look. **So this isn't a DSP project — it's a
project about clarity (UI) + an API.** And because everything goes through a self-describing API, **any AI
can prepare — or fully mix — a project for you**, live, while you keep control.

**Made for real jobs:** prepping a project before you take over, mixing a podcast, cleaning up and leveling
a voice recording — simple work, done well.

---

## Getting started

```sh
./build.sh                         # swiftc, zero dependencies (no SwiftPM, no install)
./test.sh                          # DSP/model test suite (offline, deterministic)

open ./Nuedeface.app               # the native UI (spawns an embedded server on /tmp/nuedeface.sock)
python3 clients/demo_podcast.py    # a script (≈ an AI) builds a podcast mix in THE SAME app, live

# … or the server alone, headless:
./nuedeface --headless /tmp/nuedeface.sock &
python3 clients/demo_podcast.py
```

> The demo imports a voice + an ambience track (defaults: `assets/voice.wav`, `assets/ambience.mp3`). None
> is shipped in the repo (size + rights): drop your own into `assets/` or pass paths as arguments — see
> [`assets/README.md`](./assets/README.md).

The **UI is just another socket client**: faders, meters, waveforms and **attributed deltas** update
live, whether the action came from your mouse or from an AI. An **activity feed** (status bar) shows
*who did what* — you literally watch the AI work.

> **First launch (downloaded build):** macOS Gatekeeper quarantines apps downloaded from the web. If you
> grabbed a pre-built `.app`, run `xattr -dr com.apple.quarantine Nuedeface.app` once (or right-click →
> Open). Building locally with `./build.sh` is **not** affected.

---

## Driving it (human, script or AI — same surface)

A machine-first protocol, **newline-delimited JSON**. The tree is addressed by **stable IDs**; time is in
**seconds** at the edge (samples internally). On connect, the server sends a `hello` pointing at discovery.

**Discoverable without docs** (the test: plug any AI in cold and say "mix this voice"):
- **`help`** / **`describe`** → the whole command set: verbs, **signatures** (args/returns), params with
  **unit + min/max/default**, the catalog of 23 Apple AUs, and a **cookbook** (`recipes` + annotated `examples`).
- **`getState`** → the full project snapshot.
- **two ears** to *perceive* the audio and close the mutate→measure→correct loop:
  `analyze` (LUFS/peak/clip), `loudness` (R128: momentary/short-term/true-peak/LRA), `spectrum` (timbre),
  `meters` (per track), `detectSilence` (where the gaps are).

```json
{"cmd":"import","path":"/abs/voice.m4a"}                 → {"ok":true,"assetId":"a1"}
{"cmd":"clip.add","trackId":"t1","asset":"a1","start":0} → {"ok":true,"newId":"c1"}
{"cmd":"set","path":"track/t1/controls/gain","value":0.44}
{"cmd":"clip.setFade","clipId":"c1","fadeIn":0.5,"fadeOut":1.5}
{"cmd":"normalize","target":-16}                          → targets -16 LUFS (true-peak guarded)
{"cmd":"analyze"}                                         → {"lufs":-16.0,"peakDBFS":-7.2,"clipping":false}
{"cmd":"export","path":"/abs/out.m4a","format":"m4a"}
```

Every mutation broadcasts an **attributed delta** (`{"event":"delta","rev":..,"who":"client#2",..}`) to all
clients → a synchronized replica. **Failures are explicit** (`{"ok":false,"error":"…"}`) so the AI can
recover on its own.

### The verbs (overview)

| Category | Verbs |
|---|---|
| **Discovery** | `help`/`describe`, `getState` |
| **Audio in/out** | `import`, `export` (wav / native AAC m4a) |
| **Measurement** | `analyze`, `loudness`, `meters`, `spectrum`, `detectSilence` |
| **Structure** | `track.*`, `bus.*` (submix, cycle-safe routing), `send.*` (pre/post aux taps), `clip.*` (add/move/trim/setFade/split/duplicate/crossfade), `insert.*` (eq·reverb·delay·distortion + **`au`** = any Apple AU) |
| **Settings** | `set` (gain/pan/mute/solo, insert params), `automation.*` (vol/pan/clip-gain/params) |
| **High-level gestures** | `normalize`, `match` (loudness\|tone), `duck` (bed under voice), `fx.apply` (recipes) |
| **Transport** (ephemeral) | `transport.play/stop/seek`, `subscribe` (opt-in telemetry) |
| **Project / takes** | `project.save/load`, `undo`/`redo`, `ab.capture/recall/list` (A/B compare) |

---

## What the engine does

- **Multitrack mixing**: clips positioned/trimmed/faded (linear/exp/S curve), gain/pan/mute/solo, submix
  buses + aux sends, an insert chain per track and per bus.
- **Effects**: 4-band EQ, reverb, delay, distortion — **plus the generic `au` insert** opening all
  **23 Apple effect Audio Units** (compressor, limiter, multiband…), self-described params, zero code per effect.
- **Automation** baked at render (volume, clip gain, insert params) + pan driven by the mixer node (one law
  everywhere) — audible offline AND live.
- **Analysis**: LUFS / **BS.1770-compliant true-peak (4× polyphase oversampling)** / LRA (R128), FFT
  spectrum, silence detection — the AI *hears* what it's doing.
- **Live preview**: a persistent `AVAudioEngine` plays the mix; playhead, per-track/bus VU, **live FFT**,
  **measured gain reduction** and loudness are streamed as telemetry (~30 Hz, opt-in).
- **Export** WAV / native AAC (effect tails are rendered to silence). No recording, no MIDI, no third-party
  plugins (deliberately out of scope).

## The UI

GarageBand layout (timeline on top, console below, both collapsible). **Timeline** = real clips, waveforms,
fades, automation lanes, playhead. **Console** = the selected channel as a **horizontal rack** (draggable
node EQ with the **live spectrum behind the curve**, tangible knobs, GR meters) + a **mix/master** section
(mini-faders, stereo VU, loudness radar). Uniform gestures (right-click / long-press = Rename · Delete · …),
native macOS menu bar, A/B, mindful save (project name + "modified" state).

---

## Repo map

| | |
|---|---|
| `src/` | core: `Document` (model + log + undo) · `Engine` (offline render + LUFS + analysis) · `LiveEngine` (preview + telemetry) · `Spectrum` · `AudioUnits` · `Recipes` · `Server` (socket) |
| `src/ui/` | SwiftUI UI: `SocketClient` (replica) · `Console` · `Timeline` · `Widgets` · `Theme` · `ContentView` · `AppHost` |
| `clients/` | `demo_podcast.py` — a podcast mix (voice + ambience) built entirely by hand over the socket; the script behind the demo GIF |
| `tests/` | asserted test suite (true-peak, LUFS, fades, automation, silence), run by `./test.sh` |
| `proofs/` | standalone Swift validation benches that de-risked the hard parts (hot-swap, LUFS, fades, reconcile, AU, limiter, bus, sends, spectrum…) |
| `tools/` | dev utilities: `list_audio_units.swift` (enumerate Apple AUs), `master.swift` (mastering bench) |
| `build.sh` · `test.sh` | swiftc build → `./nuedeface` + `Nuedeface.app` · test suite |

---

## Constraints

- **No external dependencies**: `swiftc` only, no SwiftPM, no install.
- **100% local**: one process, one Unix socket, several clients (the mpv/mpd/redis pattern). Never remote.

---

## Contributing & license

See [CONTRIBUTING.md](./CONTRIBUTING.md) and the [Code of Conduct](./CODE_OF_CONDUCT.md).
Licensed under the [MIT License](./LICENSE) © 2026 gwenn-ha-dev.
