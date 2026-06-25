#!/usr/bin/env python3
# Nuedeface — démo PODCAST « à la main, sous tes yeux » : voix + ambiance mixées en direct par le socket.
#
# AUCUNE recette : chaque geste est posé un par un. Deux cadences :
#   • COMPACT (défaut) → ~10 s, taillé pour un GIF : micro-gestes fondus en jalons, on finit sur la boucle.
#   • FULL  (NUEDE_COMPACT=0) → version détaillée, pédagogique, idéale pour une vidéo/MP4 longue.
#
#   1) open ./Nuedeface.app                       # l'UI (lance le serveur sur /tmp/nuedeface.sock)
#   2) python3 clients/demo_podcast.py            # ← lance ça, et filme la fenêtre
#      NUEDE_COMPACT=0 python3 clients/demo_podcast.py   # version longue détaillée
#
# Args optionnels : [voix] [ambiance] [socket].  Rythme fin : NUEDE_BEAT (s/jalon).

import socket, json, os, sys, time

ASSETS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "assets"))
VOICE = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ASSETS, "voice.wav")
AMB   = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(ASSETS, "ambience.mp3")
SOCK  = sys.argv[3] if len(sys.argv) > 3 else "/tmp/nuedeface.sock"

COMPACT = os.environ.get("NUEDE_COMPACT", "1") not in ("0", "no", "false", "")
MBEAT   = float(os.environ.get("NUEDE_BEAT", "0.55" if COMPACT else "0.75"))
LOOP    = 4.0 if COMPACT else 8.0           # durée de la boucle de lecture filmée

for label, p in (("voix", VOICE), ("ambiance", AMB)):
    if not os.path.exists(p):
        sys.exit(f"{label} introuvable : {p}\n"
                 f"  → passe un chemin en argument, ou dépose ton fichier dans assets/ (voir assets/README.md)")

# connexion avec retry (le socket embarqué de l'app met ~1 s à apparaître)
s = None
for _ in range(80):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(SOCK); break
    except OSError:
        time.sleep(0.1)
if s is None:
    raise SystemExit(f"socket introuvable ({SOCK}) — l'app Nuedeface est-elle lancée ?")
f = s.makefile("rwb", buffering=0); _id = 0

def call(cmd, **kw):
    """Envoie un verbe, ignore les deltas diffusés, renvoie la réponse appariée. Signale les échecs."""
    global _id; _id += 1; mine = _id
    f.write((json.dumps({"id": mine, "cmd": cmd, **kw}) + "\n").encode())
    while True:
        m = json.loads(f.readline())
        if m.get("event") == "delta":
            continue
        if m.get("id") == mine:
            if m.get("ok") is False:
                print(f"     ⚠ {cmd}: {m.get('error')}")
            return m

def beat(msg, pause=None):
    """Jalon : pause toujours (rythme le film)."""
    print(f"  ▸ {msg}")
    time.sleep(MBEAT if pause is None else pause)

def micro(msg):
    """Micro-étape : détaillée (et temporisée) en FULL, fondue dans le jalon en COMPACT."""
    print(f"     · {msg}")
    if not COMPACT:
        time.sleep(MBEAT)

# --- résolution des params d'une AU générique (lus dans getState : schéma auto-décrit par instance) ---
def insert_schema(kind, owner_id, insert_id):
    st = call("getState")["state"]
    owner = next((t for t in st["tracks"] if t["id"] == owner_id), None) if kind == "track" else st["buses"].get(owner_id)
    return (owner or {}).get("fx", {}).get(insert_id, {}).get("schema", [])

def pid(schema, *cands):
    """id réel d'un param d'AU. Certaines AU (AUDynamicsProcessor) ont un `id` NUMÉRIQUE et le libellé dans
    `name` → on essaie id (exact, puis sous-chaîne) PUIS name (sous-chaîne), dans l'ordre des candidats."""
    for c in cands:
        for p in schema:
            if p["id"].lower() == c.lower():
                return p["id"]
    for c in cands:
        for p in schema:
            if c.lower() in p["id"].lower():
                return p["id"]
    for c in cands:
        for p in schema:
            if c.lower() in p["name"].lower():
                return p["id"]
    return None

def setp(base, schema, real_id, value, label):
    """set d'un param d'AU, borné au [min,max] du schéma. base = 'track/t1/fx/iX' ou 'bus/master/fx/iX'."""
    if not real_id:
        print(f"     ⚠ param introuvable ({label})"); return
    spec = next((p for p in schema if p["id"] == real_id), None)
    if spec:
        value = max(spec["min"], min(spec["max"], value))
    call("set", path=f"{base}/params/{real_id}", value=value)

print(f"\n=== Nuedeface — mix PODCAST À LA MAIN  ({'COMPACT ~10 s' if COMPACT else 'FULL'}) ===\n")
call("subscribe")
v   = call("import", path=VOICE)["assetId"]
amb = call("import", path=AMB)["assetId"]
beat("import : voix + ambiance", 0.4)

# 1) pistes
call("track.rename", trackId="t1", name="Voix")
t2 = call("track.add", name="Ambiance")["newId"]
beat("deux pistes : Voix + Ambiance")

# 2) clips + trim de la piste trop longue
ambClip = call("clip.add", trackId=t2, asset=amb, start=0, offset=8, duration=12)["newId"]
micro("ambiance posée… 12 s, ça déborde")
call("clip.trim", clipId=ambClip, duration=10)
beat("trim → l'ambiance fait pile 10 s")
voix = call("clip.add", trackId="t1", asset=v, start=1.0, offset=0, duration=7.84)["newId"]
micro("voix posée à 1,0 s")
call("clip.trim", clipId=voix, duration=6.8)
beat("voix calée sur le lit, queue resserrée")

# 3) fondus d'entrée / sortie (la classe)
call("clip.setFade", clipId=voix, fadeIn=0.5, shape="scurve")
micro("fade-in voix (galbe S)")
call("clip.setFade", clipId=voix, fadeOut=1.0, shape="exp")
micro("fade-out voix (galbe expo)")
call("clip.setFade", clipId=ambClip, fadeIn=1.2, shape="scurve")
micro("intro ambiance en douceur")
call("clip.setFade", clipId=ambClip, fadeOut=1.8, shape="exp")
beat("fondus d'entrée / sortie sur les deux pistes")

# 4) EQ voix — 4 bandes (la courbe se dessine)
eq = call("insert.add", trackId="t1", type="eq")["newId"]
for k, val in (("b0_freq", 90), ("b0_gain", -6), ("b1_freq", 300), ("b1_gain", -3),
               ("b2_freq", 4000), ("b2_gain", 4), ("b3_freq", 7500), ("b3_gain", -4)):
    call("set", path=f"track/t1/fx/{eq}/params/{k}", value=val)
    if k.endswith("gain"):
        micro({"b0_gain": "graves coupés (~90 Hz)", "b1_gain": "creux à 300 Hz (boue)",
               "b2_gain": "présence à 4 kHz", "b3_gain": "dé-ess à 7,5 kHz"}[k])
beat("EQ voix : graves coupés · présence · sifflantes domptées")

# 5) compresseur voix — réglé à la main (la GR bouge)
comp = call("insert.add", trackId="t1", type="au", subType="dcmp")["newId"]
sch = insert_schema("track", "t1", comp); base = f"track/t1/fx/{comp}"
setp(base, sch, pid(sch, "Compression Threshold", "threshold"), -22, "threshold"); micro("seuil −22 dB")
setp(base, sch, pid(sch, "Headroom", "headroom"), 5, "headroom"); micro("genou souple")
setp(base, sch, pid(sch, "Attack Time", "attack"), 0.004, "attack")
setp(base, sch, pid(sch, "Release Time", "release"), 0.18, "release"); micro("attaque rapide / release moyen")
setp(base, sch, pid(sch, "Master Gain", "overallGain", "gain"), 5, "makeup")
beat("compresseur de voix réglé à la main (+5 dB makeup)")

# 6) ambiance sous la voix
aeq = call("insert.add", trackId=t2, type="eq")["newId"]
call("set", path=f"track/{t2}/fx/{aeq}/params/b3_freq", value=5000)
call("set", path=f"track/{t2}/fx/{aeq}/params/b3_gain", value=-9)
call("set", path=f"track/{t2}/controls/gain", value=0.4)
micro("ambiance roulée dans les aigus + baissée")
call("duck", source="t1", target=t2, threshold=-30, depth=-12)
beat("ducking : l'ambiance plonge sous la voix")

# 7) chaîne master — pièce par pièce
meq = call("insert.add", busId="master", type="eq")["newId"]
for k, val in (("b0_freq", 40), ("b0_gain", -3), ("b2_freq", 3000), ("b2_gain", 1.5)):
    call("set", path=f"bus/master/fx/{meq}/params/{k}", value=val)
micro("EQ master")
mcomp = call("insert.add", busId="master", type="au", subType="dcmp")["newId"]
msch = insert_schema("bus", "master", mcomp); mbase = f"bus/master/fx/{mcomp}"
setp(mbase, msch, pid(msch, "Compression Threshold", "threshold"), -16, "threshold")
setp(mbase, msch, pid(msch, "Master Gain", "overallGain", "gain"), 2, "makeup")
micro("compresseur de bus")
call("insert.add", busId="master", type="au", subType="lmtr")
micro("limiteur de sécurité")
call("normalize", target=-16)
beat("master : EQ · comp · limiteur · normalize −16 LUFS")

if not COMPACT:
    L = call("loudness")
    print(f"     integrated {L['integrated']:.1f} LUFS · short-term {L['shortTerm']:.1f} · "
          f"true-peak {L['truePeak']:.1f} dBTP · LRA {L['lra']:.1f}")

print("\n▶ LECTURE en boucle 0→10 s — playhead, VU, spectre sous l'EQ, GR du comp\n")
call("transport.play", **{"from": 0, "to": 10, "loop": True})
time.sleep(LOOP)   # la boucle filmée (l'app continue à jouer après la sortie du script)
print("== mix podcast monté à la main, 100 % piloté par le socket — l'app reste ouverte ==\n")
