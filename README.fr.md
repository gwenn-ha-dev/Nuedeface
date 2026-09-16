# Nuedeface

[![CI](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml/badge.svg)](https://github.com/gwenn-ha-dev/Nuedeface/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Platform](https://img.shields.io/badge/Platform-macOS%2026%2B-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)

*🇬🇧 [English](./README.md) · 🇫🇷 Français*

**Du mix simple, mais de qualité — macOS natif, inspiré de GarageBand, *headless*, piloté par un socket Unix.** Une seule surface, trois clients : **toi** (l'UI native), une **IA** — *n'importe laquelle*, pas seulement Claude — et un **script**, tous parlent le même protocole JSON.

## Fonctionnalités

- Chaque effet et traitement est **Apple natif** (AVAudioEngine + Audio Units), exploité au max — pas de DSP maison.
- L'IA peut **mixer à ta place pendant que tu gardes le contrôle** : tu vois chaque geste se poser en direct et tu peux reprendre la main à tout moment.
- Timeline avec waveforms et automation, console avec node-EQ lisible et mètres live.
- Chaque geste est un verbe JSON que tu pourrais taper toi-même.
- Aucune dépendance — `swiftc` seul, frameworks Apple uniquement.

## Installation

```sh
git clone https://github.com/gwenn-ha-dev/Nuedeface.git
cd Nuedeface
make build
```

## Comment ça marche

Nuendo → « nu en dos » → **« nue de face »**. Là où les vieux DAW te tournent le dos (usine à gaz, tout planqué dans des menus), Nuedeface montre tout, de face, lisible. Le nom est la thèse.

*État : prototype fonctionnel.* Cœur, API et UI opérationnels et prouvés (bancs de validation mesurés + scènes socket sur de vrais fichiers).

## Construction

| Commande | Ce qu'elle fait |
|---|---|
| `make build` | Compilation release, tout avertissement est une erreur |
| `make test` | Lance la suite de tests |
| `make run` | Lance l'app |
| `make icon` | Régénère `Resources/AppIcon.icns` |
| `make package` | Produit un bundle distribuable dans `build/` |
| `make lint` | Vérifie la conformité à la charte |
| `make help` | Liste toutes les cibles |

## Dépendances

Aucune — frameworks Apple uniquement.

## Licence

MIT © 2026 gwenn-ha-dev — voir [LICENSE](./LICENSE).
