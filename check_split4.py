#!/usr/bin/env python3
"""check_split4.py -- Pruefen, ob der All-Cards-Split auf DIESEM Rechner laeuft, ohne etwas zu aendern.

Maschinenneutral: die Karten werden gefragt (nvidia-smi), das Modell wird gelesen (GGUF), die Regel ist
dieselbe wie die der Engine selbst (strata_control/split_engine.py). Keine Karte und kein Modell ist hier
eingetragen -- ein Rechner mit vier Turing-Karten bekommt eine andere Antwort als einer mit vier Ampere.

    ./check_split4.py --modell /pfad/zum/modell.gguf
    ./check_split4.py --modell ... --context 131072 --selftest build-86/src/split/strata-split-selftest
    ./check_split4.py --baum /pfad/zum/strata            # nur Karten, RAM und Bau-Befehl

Die Architektur-Zahlen (Shared Memory je Karte, Tensor-Core-Pfade) wohnen in src/split/src/arch_caps.hpp und
werden nicht dupliziert: wer sie sehen will, laesst --selftest laufen, das gibt die Zahl der Karte aus und
vergleicht sie mit der Tabelle.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent


def find_tree(arg: str | None) -> pathlib.Path | None:
    """Der Strata-Arbeitsbaum: Argument, $STRATA_DIR, oder der Baum, in dem dieses Skript liegt."""
    cands = []
    if arg:
        cands.append(pathlib.Path(arg))
    if os.environ.get("STRATA_DIR"):
        cands.append(pathlib.Path(os.environ["STRATA_DIR"]))
    cands.append(HERE)
    for c in cands:
        if (c / "src" / "split" / "CMakeLists.txt").is_file():
            return c
    return None


def nvidia_cards() -> list[dict]:
    """Karten direkt von nvidia-smi: Index, Name, MiB, Compute Capability, freie MiB."""
    tool = shutil.which("nvidia-smi")
    if not tool:
        return []
    q = "index,name,memory.total,compute_cap,memory.free"
    try:
        out = subprocess.run([tool, f"--query-gpu={q}", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception as e:                                    # Karte nicht ansprechbar, Treiber ohne Query
        print(f"nvidia-smi lief nicht durch: {e}")
        return []
    cards = []
    for line in out.strip().splitlines():
        p = [x.strip() for x in line.split(",")]
        if len(p) < 5:
            continue
        try:
            major, minor = p[3].split(".")
            cards.append(dict(index=int(p[0]), name=p[1], vram_mib=int(p[2]), cc=int(major) * 10 + int(minor), free_mib=int(p[4])))
        except ValueError:
            continue
    return cards


def main() -> int:
    ap = argparse.ArgumentParser(description="Prueft Karten, Modell und Regel fuer den All-Cards-Split.")
    ap.add_argument("--baum", help="Strata-Arbeitsbaum (Default: $STRATA_DIR oder dieser Ordner)")
    ap.add_argument("--modell", help="GGUF-Datei (erste Shard), deren Experten gezaehlt werden")
    ap.add_argument("--context", type=int, default=131072, help="Kontext, fuer den geprueft wird (Default 131072)")
    ap.add_argument("--allow-untested", action="store_true", help="auch eine Architektur durchrechnen, die Strata nicht gefahren ist")
    ap.add_argument("--selftest", help="gebautes strata-split-selftest: fragt die Karte nach ihrer eigenen Shared-Memory-Zahl")
    ap.add_argument("--als-ob", metavar="CC", help="die Compute Capability aller Karten annehmen (Name und Groesse bleiben die echten) -- die Frage vor dem Kauf")
    args = ap.parse_args()

    tree = find_tree(args.baum)
    if tree is None:
        print("Kein Strata-Baum gefunden (--baum angeben). Ohne ihn gibt es keine Regel, nur die Kartenliste.")

    cards = nvidia_cards()
    if not cards:
        print("Keine NVIDIA-Karte erreichbar (nvidia-smi ohne Antwort).")
        return 2
    print(f"Karten ({len(cards)}):")
    for c in cards:
        print(f"  {c['index']}: {c['name']:28s} {c['vram_mib']:7d} MiB, sm_{c['cc']}, frei {c['free_mib']} MiB")
    same = len({c["name"] for c in cards}) == 1 and len({c["cc"] for c in cards}) == 1
    spread = max(c["vram_mib"] for c in cards) - min(c["vram_mib"] for c in cards)
    print(f"  alle gleich: {'ja' if same and spread <= 512 else 'nein'}"
          f"{'' if same else '  (Namen/Compute Capability unterscheiden sich)'}"
          f"{'' if spread <= 512 else f'  (Spanne {spread} MiB -- eine Karte hat weniger, meist ECC)'}")

    if args.als_ob:
        cc = int(args.als_ob)
        for c in cards:
            c["cc"] = cc
        print(f"  angenommen: sm_{cc} auf {len(cards)} Karten (Name und Groesse bleiben die echten)")

    if args.selftest:
        exe = pathlib.Path(args.selftest)
        if not exe.is_file():
            print(f"  selftest nicht gefunden: {exe}")
        else:
            print("\nKarte befragen (strata-split-selftest, ohne Modell):")
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300)
            for line in (r.stdout + r.stderr).strip().splitlines():
                print("  " + line)
            print(f"  exit {r.returncode}: {'Kernel-Test bestanden' if r.returncode == 0 else 'Kernel-Test fehlgeschlagen'}")

    if tree is None:
        return 0
    sys.path.insert(0, str(tree))
    try:
        import strata_control.split_engine as SE
    except ImportError as e:
        print(f"Regel der Engine nicht erreichbar: {e}")
        return 2

    arch = f"sm_{cards[0]['cc']}"
    tested = SE.TESTED.get("nvidia", {})
    counts = tested.get(arch, ())
    print(f"\nRegel der Engine ({tree}):")
    print(f"  Architektur {arch}: von Strata gefahren" if counts else f"  Architektur {arch}: von Strata noch nicht gefahren")
    if not counts and hasattr(SE, "arch_note"):
        print("  " + SE.arch_note(arch))
    if counts:
        print(f"  gelistete Karten-Anzahlen: {counts}"
              f"{'' if len(cards) in counts else f'  -- {len(cards)} Karten sind NICHT gelistet (allow_untested laesst es trotzdem zu)'}")
    print(f"  Kartenmaximum der Engine: {SE.MAX_CARDS} (das C++-Geometrie-Max ist NCARD_MAX=8)")

    if args.modell:
        model = SE.scan_model(args.modell)
        ram_total, ram_avail = SE.ram_gib()
        se_cards = [SE.Card(index=c["index"], name=c["name"], vram_mib=c["vram_mib"], cc=c["cc"], vendor="nvidia", arch="", free_mib=c["free_mib"])
                    for c in cards]
        d = SE.decide(enabled=True, system="linux", cards=se_cards, ram_total_gib=ram_total, ram_available_gib=ram_avail,
                      model=model, context=args.context, allow_untested=args.allow_untested)
        print(f"\nModell {pathlib.Path(args.modell).name}: Experten {sorted(model.routed_types)}, "
              f"{model.routed_bytes / 1024**3:.2f} GiB Experten, Einbettungen {model.embd_type}")
        print(f"RAM: {ram_total:.1f} GiB gesamt, {ram_avail:.1f} GiB verfuegbar")
        print(f"\nEntscheidung: {'Split' if d.use_split else 'kein Split (normaler Layer-Split)'}")
        print(f"  braucht {d.need_vram_gib:.2f} GiB je Karte, {d.need_ram_gib:.1f} GiB RAM")
        for r in d.reasons:
            print(f"  dagegen: {r}")
        for u in getattr(d, "untested", []):
            print(f"  ungetestet, aber erlaubt: {u}")

    n = len(cards)
    if n < 2 or n > SE.MAX_CARDS:
        print(f"\n{len(cards)} Karten: der Split baut 2 bis {SE.MAX_CARDS} (strata-split-2/3/4) -- dafuer ist dieser Rechner nicht gebaut.")
        return 0
    print(f"\nBefehl fuer diesen Rechner (Architektur {arch[3:]}, {n} Karten):")
    print(f"  cmake -B build-split4 -DCMAKE_BUILD_TYPE=Release \\")
    print(f"        -DCMAKE_CUDA_COMPILER=$(command -v nvcc) -DCMAKE_CUDA_ARCHITECTURES={arch[3:]} \\")
    print(f"        -DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_SPLIT=ON -DSTRATA_SPLIT_CARDS=\"{n}\" -DSTRATA_BUILD_TESTS=ON")
    print(f"  cmake --build build-split4 --target strata-split-{n} strata-split-selftest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
