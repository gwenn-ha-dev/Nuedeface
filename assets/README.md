# assets/

Les fichiers audio ne sont **pas** versionnés (voir `.gitignore` : `*.m4a`, `*.wav`, …) —
poids du repo + droits sur le contenu.

La démo `clients/demo_podcast.py` attend deux fichiers (libres de droits), par défaut :

- `assets/voice.wav` — une voix (le sujet du podcast)
- `assets/ambience.mp3` — une ambiance (lit de fond)

```sh
cp /chemin/vers/ta-voix.wav      assets/voice.wav
cp /chemin/vers/ton-ambiance.mp3 assets/ambience.mp3
```

Tu peux aussi passer les chemins en arguments :

```sh
python3 clients/demo_podcast.py /abs/voix.wav /abs/ambiance.mp3
```
