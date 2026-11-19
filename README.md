# strata_split4_patch — die All-Cards-Split-Engine für vier Karten, ohne Architektur-Hardcoding

**Bedienung: [LESEN.md](LESEN.md)** (check / einspielen / zurücknehmen / Ablauf vor `update.sh`). Details hier unten.

Der Patch, der aus Strata 0.1.62 die Split-Engine macht, die **jede Schicht auf allen Karten** laufen lässt
(2–4 Karten), plus die Skripte, die sie auf einem Rechner zum Laufen bringen, den niemand hier je gesehen hat.

**Basis:** `58ee32277` = Tag **v0.2.16** (Engine **0.1.62**). **Ast mit dem Patch:**
`agent/hermes-split4-arch-0162` in `pott/strata_lokal` (getragen von `agent/hermes-split4-arch-0161` per
`git rebase --onto 58ee32277 c77572806`; alte Schnitte: Tag `archive/split4-on-c77572806` für v0.2.15 und
`archive/split4-on-7726f80c` für 0.1.59.1).

## Worum es geht

Der Split war nie auf `sm_86` hartcodiert — er war nur **nicht freigeschaltet** und an einer Stelle **an eine
Zahl gebunden, die niemand aufgeschrieben hatte**. Beides ist jetzt anders:

| | vorher | jetzt |
|---|---|---|
| Build-Architektur | `STRATA_SPLIT_ARCH`, Default 86, nirgends erklärt | dieselbe Variable, aber die Karte wird gefragt (`install.sh`) und die Zahl kommt aus einer Tabelle |
| Was eine Karte kann | verteilt als `#if FNX_ARCH >= 80` über die Kernel | **`engine/src/split/src/arch_caps.hpp`**: Shared Memory je Karte, dp4a, die beiden f16-mma-Familien, int8-Attention |
| Prompt-Kernel-Layout | 32 Spalten (CUDA) / 16 Spalten (HIP) — nach Backend entschieden | nach der **Shared-Memory-Grenze der Karte** entschieden; ein `static_assert` meldet eine unpassende Karte zur Build-Zeit statt nach drei Minuten Modell-Load |
| Kernel-Beweis auf einer fremden Karte | nur für AMD (Selftest war in CMake an HIP gebunden) | **auch für NVIDIA**: `strata-split-selftest` wird für CUDA gebaut, und die Engine läuft ihn vor dem Modell-Load auf jeder Architektur, die Strata nicht gefahren ist |
| Kartenanzahl 4 auf sm_86 | in der Regel-Tabelle nicht gelistet (auto sagte nein) | gelistet: gefahren und gemessen am 11.11.2026 (4× A4000, 106–116 tok/s) |
| Eine unbekannte Architektur | „only been run on sm_86/sm_120 cards" und Schluss | die Regel sagt in Worten, was die Karte hat: `arch_note` — „sm_75: 64 KiB shared memory a block, prompt kernel drops to 16 columns, 32 need 73 KiB, self-test proves the kernels first" |

## Die eine echte Architektur-Grenze (das war die Überraschung)

`k_gdn_ch_rec` (der Prompt-Pfad des rekurrenten Teils) braucht **72,6 KiB dynamisches Shared Memory** pro Block.
Die published Limits: 7.5 Turing **64 KiB**, 7.0 Volta 96 KiB, 8.6/8.9/12.x 99 KiB, 8.0 163 KiB, 9.0/10.x 227 KiB.

→ **vier Turing-Karten (2080, 3090, T4) können den 32-Spalten-Layout nicht starten.** Der Baum hatte die Lösung
schon, aber nur für AMD: 16 Spalten sind 56,6 KiB, bit-identische Ergebnisse. Diese Wahl hängt jetzt an der
Grenze der Karte, nicht am Backend. Fluchtweg ohne alles: `FNX_PF_GDN_CHUNK=0` (Reihe-für-Reihe-Kernel, 0 dynamisches Shared Memory).

Decode-Kernel sind unkritisch (18,0 KiB). `sm_98` gibt es nicht; reale Stufen sind 75, 80/86/87, 89, 90, 100/103/107/110, 120.

## Die Dateien

| Datei | was sie tut |
|---|---|
| `split4/strata_split4_all.patch` | der eine Großpatch (Basis `58ee32277`, 1141 Zeilen, 17 Dateien, +686/−44; der gelegte Baum unterscheidet sich **null Zeilen** von der Ast-Spitze) |
| `split4/BASE.txt` | die Basis-Commit-Nummer, damit die Skripte sie nicht raten |
| `install.sh` | Karten fragen → prüfen → anwenden → bauen → beweisen. Optionen `--nur-pruefen`, `--ohne-bau`, `--zurueck`, `--selbsttest`, `--testbau`, `--arch`, `--karten` |
| `check_split4.py` | prüfen ohne zu ändern: Karten (nvidia-smi), Modell (GGUF), dieselbe Regel wie die Engine, plus der Bau-Befehl für diesen Rechner |
| `aufraeumen.sh` | melden, was der Patch tut; Zyklustest auf Wegwerf-Worktree (apply → revert → sauber); eigene Reste entfernen (`--loeschen`) |
| `apply_patch.sh` | das Schlichte: `check` / `apply` / `revert` |

## Benutzen

```bash
# 1) Was ist das hier für ein Rechner? (nichts wird geändert)
python3 check_split4.py --baum /pfad/zum/strata --modell /pfad/zum/modell.gguf

# 2) Installieren: prueft, wendet an, baut fuer die Architektur DER Karten, beweist die Kernel
bash install.sh --baum /pfad/zum/strata --selbsttest --testbau

# 3) Vor jedem update.sh: zuruecknehmen, danach wieder apply
bash install.sh --baum /pfad/zum/strata --zurueck
bash install.sh --baum /pfad/zum/strata
```

Der Build braucht CUDA: `-DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_SPLIT=ON -DSTRATA_SPLIT_CARDS="4" -DCMAKE_CUDA_ARCHITECTURES=<cc>`.
(`STRATA_BUILD_SPLIT` allein reicht nicht — ohne `STRATA_ENABLE_CUDA` sagt CMake „needs a Linux CUDA or HIP build, skipped“.)

## Was der Sprung auf 0.2.16 (Engine 0.1.62) geändert hat

* **Der Baum ist umgezogen** (Layout-Move `4058aa782`): `engine/` für den Engine-Quell
  (`engine/src/split/...`), `terminal/` für `setup.py`, `strata_cli`, `strata_control` und die Tests.
  Gebaut wird `cmake -S engine`. `install.sh` und `check_split4.py` erkennen beide Layouts.
* **`src/split/tools/qdot_test.cu` gibt es nicht mehr:** Upstream entfernte mit „own-stack step 10"
  (`3e26b4e15`) die vendored `ggml-cuda` und mit ihr unseren Bitgleichheits-Test für die IQ2-Dots.
  Unsere `vec_dot_iq2_xs_q8_1` / `vec_dot_iq2_xxs_q8_1` in `qdot.cuh` sind weiter drin, aber ihr
  Oracle ist weg — `split_qdot_golden` (der gebliebene Digest-Test) kennt nur bis IQ2_S.
  **Offene Lücke:** ein IQ2-Zweig für `qdot_golden` ist noch zu schreiben.
* **Nachzug beim Bau:** der von uns ergänzte CUDA-Zweig `strata-split-selftest` brauchte Stratas
  eigene Quant-Includes (`${_sp_quant}`) statt der entfernten ggml-cuda-Pfade — sonst
  `strata/quant/strata-quant-common.h: No such file or directory`.
* **Eine Konfliktstelle:** Upstream fügte `pf_pick_test` in die CPU-Testliste ein, unsere
  `arch_caps_test` steht jetzt daneben.
* Die Kartenanzahl ist eine CMake-Regel: `STRATA_SPLIT_CARDS` akzeptiert nur 2, 3 oder 4 —
  `install.sh` sagt das jetzt, bevor CMake abbricht.

## Was der Sprung auf 0.2.15 (Engine 0.1.60) geändert hat

* **Upstream hat die eigenen Punktkerne des Split-Engine-Decode ersetzt:** `src/split/src/qdot.cuh`
  (Commit `58414f3ec`, „split: own decode dots, no ggml-cuda header in the engine“). Der Typ-Enum heißt jetzt
  `GgmlType` mit `T_*`, und es gibt **keine** `vec_dot_iq2_xs_q8_1` / `vec_dot_iq2_xxs_q8_1`.
* **Deshalb war IQ2_XS/IQ2_XXS aus dem Patch gefallen — und das war ein Irrtum (17.11.2026).** Der Glaube
  „das Pack auf 2gb ist IQ3_XXS, also betrifft es uns nicht“ stimmte nicht: das Pack heißt so, aber seine
  gerouteten Experten sind gemischt und führen 20× IQ2_XS und 18× IQ2_XXS. Der erste Produktivstart des
  neuen Schnitts auf 2gb kippte genau dort (`blk.0.ffn_gate_exps.weight is ggml type 17`), serve fiel auf
  den Layer-Split zurück. **Nachzug (delta4, Commit `597807380`):** `qdot.cuh` führt `vec_dot_iq2_xs_q8_1`
  und `vec_dot_iq2_xxs_q8_1` als Upstream-Text aus `vecdotq.cuh` (nur `ggml_cuda_dp4a` → `qd_dp4a`),
  Dispatch in `kernels.cu` (vdot_of/vdr_of, alle drei MoE-Schalter), Annahme zurück in `model.cpp`.
  Bit-Identität gegen `vecdotq.cuh` im `qdot_test` (13 Formate). CUDA only; ein HIP-Bau weist die Typen
  per `static_assert` ab. Prompt-Pfad weiter über `FNX_PF_MOE_Q8=1` (keine IQ2-Prompt-Kacheln).
* Der Rest des Patches ist unverändert durchgekommen (EC_POOLS 4→8, CardW 1024, `FNX_EXPERT_RAM_GIB`,
  Q2_0-Shared-Expert-Schutz, Fehlerbericht aller Karten, IQ3_S-Umwandlung, arch_caps-Tabelle, `arch_note`,
  delta3). Upstream hat inzwischen selbst `T_IQ2_XXS`/`T_IQ2_XS` im Enum und einen `memlock_test` —
  beides ist im neuen Schnitt respektiert, nicht ersetzt.

## Was bewiesen ist und was nicht

* **bewiesen (19.11.2026, Schnitt auf `58ee32277` = v0.2.16 / Engine 0.1.62, Sandbox 1× A4000 sm_86,
  CUDA 12.8):** Zyklus auf frischer Worktree — `check` konfliktfrei (17 Dateien), `apply`, gelegter Baum
  **null Zeilen** von der Ast-Spitze `agent/hermes-split4-arch-0162` entfernt, `revert` sauber (0 Dateien).
  Bau `-S engine -DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_SPLIT=ON -DSTRATA_BUILD_TESTS=ON
  -DSTRATA_SPLIT_CARDS="2" -DCMAKE_CUDA_ARCHITECTURES=86`: `strata-split-2` (77 MB) und
  `strata-split-selftest` (27 MB) fehlerfrei, Ninja-Exit 0. **Der CUDA-Selbsttest laeuft auf der Karte
  gruen:** `device 0: NVIDIA RTX A4000 (sm_86), 48 SMs, 15.6 GiB, 99 KiB shared memory a block` /
  `self-test PASSED in 226 ms: card 0: wmma, expert tile, dense product, dp4a, recurrent step against a
  scalar reference`. CPU-Unit-Tests: `arch_caps` ("13 published capabilities, 32-Spalten 74372 Bytes,
  16-Spalten 57988"), `card_check` ok, `selftest_policy` ok. Split-Python-Tests von `terminal/` aus
  (`PYTHONPATH=. python3 -m unittest tests.split.…`): **73 gruene**, einschliesslich
  `test_arch_caps_parity` und der vier Faelle des env-Schreibtests (delta3).
* **bewiesen (16.11.2026, neuer Schnitt auf `c77572806`, Sandbox 1× A4000 sm_86, CUDA 12.8):** Zyklus auf
  frischer Worktree — `git apply --check` konfliktfrei (15 Dateien), `apply`, gelegter Baum **identisch** zur
  Ast-Spitze `agent/hermes-split4-arch-0161`, `revert` sauber. Bau `-DSTRATA_ENABLE_CUDA=ON
  -DSTRATA_BUILD_SPLIT=ON -DSTRATA_BUILD_TESTS=ON -DCMAKE_CUDA_ARCHITECTURES=86`: **Exit 0**,
  `strata-split-2` (75 MB) und alle Split-Tests entstehen. **13 Split-Einheitstests grün, 0 Fehler:**
  `arch_caps` (13 published capabilities), `batch_plan` (10000 Fälle, 0 Fehler), `card_check`,
  `expert_residency` (PASS), `pf_ring_plan`, `peer_policy`, `rccl_policy`, `selftest_policy`, `memlock`,
  `gdn_tc` (0 Fehler), `moe_tile`, `part_price`, `lend_complement` (PASS=***
* **bewiesen (12.11.2026, Sandbox, 1× A4000 sm_86):** Patch konfliktfrei auf frischer Worktree `7726f80c`
  (15 Dateien; `apply` → `revert` → Baum wieder sauber, und der gelegte Baum unterscheidet sich null Zeilen
  von der Ast-Spitze). `strata-split-4` für sm_86 baut (74 MB).
  `strata-split-selftest` wird für CUDA gebaut und **läuft auf der Karte grün**:
  `device 0: NVIDIA RTX A4000 (sm_86), 48 SMs, 15.6 GiB, 99 KiB shared memory a block` /
  `self-test PASSED in 252 ms: card 0: wmma, expert tile, dense product, dp4a, recurrent step against a scalar reference`.
  CPU-Unit-Tests grün (`split_arch_caps_test`: „13 published capabilities, 32-Spalten-Layout 74372 Bytes, 16-Spalten 57988").
  `tests/split/test_arch_caps_parity.py` hält die Shared-Memory-Zahlen der Kartenregel an die der C++-Tabelle —
  über den Compiler, nicht über eingelesenen Text: „arch_caps-Parität: alle 15 Stufen gleich (32 Spalten ab 70, darunter 16)".
  Die vorhandenen Split-Tests bleiben grün: `split_card_check_test`, `split_selftest_policy_test` (C++),
  `test_split_engine.py` (57 Fälle der Kartenregel), `test_split_hcsplit.py` (9), `test_split_gen_keys.py` (5)
  — die Python-Tests von der Baumwurzel aus mit `PYTHONPATH=.`. `convert_check.py` und `tile_check.py` sind
  manuelle Prüfläufe, die einen Modellpfad wollen, und wurden nicht gelaufen.
* **bewiesen (12.11.2026, Gegenbau für eine andere Architektur):** `strata-split-4` und `strata-split-selftest`
  bauen für **sm_75** (Turing, 64 KiB) konfliktfrei durch (73 MB / 27 MB, 0 Fehler). Der Gegenversuch zeigt, warum:
  wird das 32-Spalten-Layout erzwungen, **scheitert der Build am Compile-Zeitpunkt** mit
  `static assertion failed with "k_gdn_ch_rec asks a card for more shared memory than a block can opt into (src/arch_caps.hpp)"`
  — auf sm_86 ist derselbe Build grün. Die Karte selbst läuft in dieser Sandbox nicht (nur eine sm_86 ist da),
  ein 4×-Turing-Rechner ist damit **gebaut, aber nicht gefahren**.
* **produktiv gefahren (11.11.2026, 2gb):** 4× RTX A4000 sm_86, 106–116 tok/s.
* **nicht gefahren:** vier Turing-Karten (sm_75) — der Patch macht den Build möglich und meldet die Grenze,
  aber ein echter Lauf auf vier 3090 steht aus. Ebenso sm_89, sm_90, sm_120 mit vier Karten.
* Die Engine sagt bei einer Architektur, die Strata nicht gefahren ist, jetzt **in Worten**, was sie kann und
  dass sie experimentell ist (`arch_note`), und prüft die Kernel, bevor das Modell geladen wird.
  `FNX_SELFTEST=1` erzwingt den Test auch auf einer bekannten Karte, `FNX_SELFTEST=0` überspringt ihn.

## Wo der Ast liegt

`pott/strata_lokal`, Branch `agent/hermes-split4-arch-0161` (getragener Altast: `agent/hermes-split4-arch`).
Mergen auf `main` bleibt wie üblich dem Benutzer oder
Hermes nach Prüfung überlassen.
