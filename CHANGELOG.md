# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-06-24

First public release — a working prototype: the core, the socket API, and the native UI are operational
and proven.

### Engine & audio
- Multitrack mixing: clips (position/trim/fade, linear·exp·S curves), gain/pan/mute/solo, submix buses,
  pre/post aux sends, insert chains per track and per bus.
- Effects: 4-band EQ, reverb, delay, distortion, plus a generic `au` insert exposing all 23 Apple effect
  Audio Units with self-described parameters.
- Automation baked at render (volume, clip gain, insert params); pan driven by the mixer node with a
  single law across static/automated and offline/live.
- Measurement: integrated LUFS, **BS.1770-compliant true-peak (4× polyphase oversampling)**, LRA,
  FFT spectrum, silence detection.
- Live preview via a persistent `AVAudioEngine` with ~30 Hz opt-in telemetry (playhead, per-track/bus VU,
  live FFT, measured gain reduction, live loudness).
- Export to WAV / native AAC, with effect tails rendered to silence (no longer clipped at 50 ms).
- `normalize` now guards true-peak (default −1 dBTP ceiling) so it can't introduce clipping.

### Protocol & server
- Newline-delimited JSON over a Unix socket; stable IDs; attributed deltas broadcast to all clients;
  self-describing `help`/`describe` with a recipe/example cookbook.
- Robustness: no command can crash the daemon (errors are returned, not fatal); bounded line buffer;
  socket is never stolen from a live instance + `chmod 0600`; clean SIGINT/SIGTERM shutdown.
- Multi-client concurrency: per-client send queue so a slow client can't freeze everyone's mutations;
  write-all (no truncated frames); backlog cap.
- Telemetry/automation reads use an immutable lane snapshot; all graph mutations serialized on one queue
  (no data races between the apply path and telemetry).

### UI
- GarageBand-style layout: timeline (clips, waveforms, fades, automation lanes) + console (node EQ with
  live spectrum, tangible knobs, GR/VU meters, loudness radar), A/B, native menu bar, attributed activity feed.

### Project
- Asserted test suite (`./test.sh`) and macOS CI; MIT license; zero external dependencies (swiftc only).

[0.1.0]: https://github.com/gwenn-ha-dev/Nuedeface/releases/tag/v0.1.0
