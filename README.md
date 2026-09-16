# Nuedeface

[![CI](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml/badge.svg)](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-macOS%2026%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

*🇬🇧 English · 🇫🇷 [Français](./README.fr.md)*

**Simple mixing, done well — native macOS, GarageBand-inspired, *headless*, driven over a Unix socket.** One surface, three clients: **you** (the native UI), an **AI** — any of them, not just Claude — and a **script**, all speaking the same JSON protocol.

## Features

- Every effect and process is **Apple native** (AVAudioEngine + Audio Units), pushed hard — no home-made DSP.
- An AI can **mix for you while you keep control**: you watch each gesture land live and can take over at any moment.
- Timeline with waveforms and automation, console with a readable node-EQ and live meters.
- Every gesture is a JSON verb you could have typed yourself.
- No dependencies — `swiftc` alone, Apple frameworks only.

## Install

```sh
git clone https://github.com/gwenn-ha-dev/Nuedeface.git
cd Nuedeface
make build
```

## How it works

Nuendo → « nu en dos » → **« nue de face »**. Where the old DAWs turn their back on you — everything buried in menus — Nuedeface shows it all, face on, readable. The name is the thesis.

*Status: working prototype.* Core, API and UI are operational and proven (measured validation benches plus socket scenes on real files).

## Build

| Command | What it does |
|---|---|
| `make build` | Release build, warnings are errors |
| `make test` | Run the test suite |
| `make run` | Launch the app |
| `make icon` | Regenerate `Resources/AppIcon.icns` |
| `make package` | Produce a distributable bundle in `build/` |
| `make lint` | Check compliance with the project charter |
| `make help` | List every target |

## Dependencies

None — Apple frameworks only.

## License

MIT © 2026 gwenn-ha-dev — see [LICENSE](./LICENSE).
