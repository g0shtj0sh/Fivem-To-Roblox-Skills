# Ajustement du contre-braquage GTA (2026-11-16). Usage : MODE=out KCUT=0 python3 countersteer_fit.py [traces...]
# MODE=cg|rear|out|outdz ; sortie : écart RMS de l angle de roue avant (moyenne des deux) par trace.
import json, math, glob, sys
import numpy as np
D = "/home/app-user/work/Fivem-To-Roblox-Skills/calibration/m422/fivem/"
L = math.radians(35); CAP = L*0.875; FLOOR = L*0.1889
FADE, POW = 15.0, 2.72
import os
V0, K, MIN = 1.8, float(os.environ.get("KCUT", "0.18")), 0.30
B = 1.40
import os
MODE = os.environ.get("MODE", "cg")  # rear axle to COM (m), approx half of 2.811
DZ = 0.25
def axis(c):
    m = max(0, (abs(c)-DZ)/(1-DZ)); return math.copysign(min(m,1), c) if c else 0
def lock(v, vrear, cut=True):
    base = max(L/(1+(abs(v)/FADE)**POW), FLOOR)
    c = min(max(1-K*max(0,abs(vrear)-V0), MIN), 1) if cut else 1
    return min(max(base*c, 0), CAP)
files = sys.argv[1:] or ["hbcorner_40_1","hbcorner_70_1","corner40_1","corner80_1","stepsteer_1","slalom_1"]
rows = []
for f in files:
    d = json.load(open(D+f+".json")); c = d["meta"]["columns"]; I = {k:i for i,k in enumerate(c)}
    S = d["samples"]; t0 = S[0][I["t"]]
    lastStr, lastChange, steerOn = 0, -1e9, None
    for r in S:
        g = lambda n: r[I[n]]
        t = (g("t")-t0)/1000
        if abs(g("str")-lastStr) > 0.02: lastChange = t
        lastStr = g("str")
        if steerOn is None and abs(g("str")) > 0.3: steerOn = t
        if f.startswith("corner80") and steerOn is not None and t - steerOn > 1.28: continue
        v = g("vFwd") if "vFwd" in I else g("speed")
        if abs(v) < 3 or abs(g("str")) < 0.3 or t - lastChange < 0.35: continue
        if g("wheelsOnGround") < 4: continue
        w = (g("w0str")+g("w1str"))/2
        vr = g("vLat") + B*g("wz")
        beta = math.atan2(vr, abs(v)) if MODE == "rear" else math.atan2(g("vLat"), abs(v))
        if MODE == "out" and beta * g("wz") <= 0: beta = 0.0
        if MODE == "outdz":
            beta = math.atan2(g("vLat"), abs(v))
            beta = math.copysign(max(abs(beta) - math.radians(float(os.environ.get("DZB", "1"))), 0), beta) if beta * g("wz") > 0 else 0.0
        dem = axis(g("str"))
        rows.append((f, t, w, -dem*lock(v, vr), -dem*lock(v, vr, False), beta, (r[I["hbOn"]] if "hbOn" in I else 0), v))
A = np.array([r[2:] for r in rows], float)
w, pc, pn, beta, hb, v = A.T
names = [r[0] for r in rows]
def report(lbl, pred):
    res = w - pred
    print(f"{lbl:28s} rms {math.degrees(np.sqrt(np.mean(res**2))):5.2f}°", end="  ")
    for f in files:
        m = np.array([n==f for n in names])
        if m.any(): print(f"{f.split('_')[0][:8]}{f[-4:]} {math.degrees(np.sqrt(np.mean(res[m]**2))):4.1f}", end=" ")
    print()
report("cut only (current)", pc)
for base, lbl in ((pc,"cut"),(pn,"nocut")):
    k = np.sum((w-base)*beta)/np.sum(beta*beta)
    report(f"{lbl} + k·beta k={k:+.2f}", base + k*beta)
    for kk in (-0.5,-0.7,-0.9,-1.0):
        report(f"{lbl} + {kk}·beta", base + kk*beta)
