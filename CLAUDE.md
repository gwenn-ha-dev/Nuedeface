# Nuedeface — agent context

## What this is

**Simple mixing, done well — native macOS, GarageBand-inspired, *headless*, driven over a Unix socket.** One surface, three clients: **you** (the native UI), an **AI** — any of them, not just Claude — and a **script**, all speaking the same JSON protocol.

Platform: macOS 26+. Build system: swiftc, no package manager. Bundle ID `dev.gwennha.Nuedeface`.

## Build and test

```sh
make build   # release, warnings are errors
make test
make lint    # charter compliance — run before declaring anything done
```

Never invoke `swift build`, `xcodebuild` or a build script directly; go through
the `Makefile`. It is the same interface in every project here.

## Invariants — do not break these

- **No hard-coded user-visible strings.** Everything goes through
  `Resources/Localizable.xcstrings`, present in both `en` and `fr`. Adding a
  string means adding both translations in the same change.
- **No build artefacts committed.** No `.app`, no `build/`, no `.build/`.
- **Dependencies: none.** Adding one requires documenting it in the README's
  *Dependencies* section.
- **`README.md` and `README.fr.md` stay in sync.** Editing one means editing the other.
- **The icon is generated**, never hand-placed: `outils/icone.swift` is the
  source, `make icon` rebuilds `Resources/AppIcon.icns`.
- Code, comments and commit messages are in **English**.

## Layout

```
.github/
.gitignore
AppIcon.icns
CHANGELOG.md
CODE_OF_CONDUCT.md
CONTRIBUTING.md
LICENSE
Makefile
Nuedeface.app/
README.fr.md
README.md
Resources/
assets/
clients/
docs/
nuedeface
outils/
proofs/
src/
Tests/
tools/
```

## The charter

The full norm this project follows lives at `../../Charte/CHARTE.md`.
