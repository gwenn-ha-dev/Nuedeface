# Contributing to Nuedeface

Thanks for your interest! Nuedeface is a deliberately small, dependency-free macOS project. A few notes
to keep it that way.

## Ground rules

- **No external dependencies.** `swiftc` only — no SwiftPM, no CocoaPods, no Homebrew packages. If a
  feature seems to need a dependency, it almost certainly belongs out of scope.
- **100% local.** One process, one Unix socket, several clients. Nothing networked or remote.
- **DSP is Apple-native** (AVAudioEngine + Audio Units). We don't hand-roll DSP.

## Build & test

```sh
./build.sh     # produces ./nuedeface and Nuedeface.app
./test.sh      # asserted DSP/model tests — must stay green
```

Both run in CI (macOS) on every push and PR. A PR is expected to keep `./test.sh` passing.

## Making a change

1. Branch from `main`.
2. Keep the diff focused; match the surrounding style (the codebase favors dense, well-commented Swift —
   read a neighboring file before writing).
3. If you touch DSP or the document model, **add or extend an assertion in `tests/main.swift`**. The
   `proofs/` benches are also a good place to de-risk a tricky behavior in isolation.
4. Run `./build.sh && ./test.sh` locally.
5. Open a PR describing *what* and *why*.

## Reporting bugs / ideas

Open an issue with: macOS version, steps to reproduce, and — for audio bugs — the exact socket commands
or a minimal `project.save` JSON if you can.

## Scope

In scope: mixing, native effects, measurement, the socket protocol, the UI's clarity. Out of scope
(by design): recording, MIDI, third-party plugins, anything remote. Proposals that grow the dependency
footprint or the surface area will be weighed hard against the project's thesis.
