"""Pack de sons moteur maison : choix de la catégorie et mixage moteur + échappement."""
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r import sound_pack  # noqa: E402
from f2r.audio import write_wav  # noqa: E402
from f2r.util import Report  # noqa: E402


def _make_pack(root: Path) -> Path:
    t = np.arange(48000) / 24000
    for cat, n in (("super", 2), ("sport", 1), ("berline", 1), ("monster", 1)):
        for i in range(1, n + 1):
            d = root / "sounds" / cat / f"brolver_{cat}_{i:02d}"
            for part in ("moteur", "echappement"):
                for state, secs in (("acceleration", 1.0), ("deceleration", 1.5), ("ralenti", 0.3)):
                    write_wav(d / f"{d.name}_{part}_{state}.wav",
                              np.sin(2 * np.pi * 100 * t[: int(24000 * secs)]) * 0.5, 24000)
    write_wav(root / "sounds" / "klaxon" / "brolver_klaxon_01.wav", np.sin(t * 2000) * 0.5, 24000)
    return root


def test_sound_pack():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        rep = Report()
        root = sound_pack.open_pack(_make_pack(tmp / "pack"), tmp / "cache", rep)
        assert root is not None and root.name == "sounds"
        assert sound_pack.choose(root, "VC_SUPER", "adder").parent.name == "super"
        assert sound_pack.choose(root, "VC_SUPER", "adder") == sound_pack.choose(root, "VC_SUPER", "adder")
        assert sound_pack.choose(root, "VC_OFF_ROAD", "monster3").parent.name == "monster"
        assert sound_pack.choose(root, "VC_BOAT", "x").parent.name == "berline"
        assert sound_pack.choose(root, "VC_SPORT", "x", "brolver_super_02").name == "brolver_super_02"
        assert sound_pack.choose(root, "VC_SPORT", "x", "inconnu") is None
        wavs = sound_pack.prepare(sound_pack.choose(root, "VC_SPORT", "x"), root, tmp / "w", "x", rep)
        assert set(wavs) == {f"{l}_{k}" for l in ("engine", "exhaust") for k in ("accel", "decel", "idle")} | {"horn"}
        assert "_echappement_deceleration" in wavs["exhaust_decel"].name


if __name__ == "__main__":
    test_sound_pack()
    print("ok")
