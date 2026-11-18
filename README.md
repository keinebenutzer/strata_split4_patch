# strata_split4_patch — die All-Cards-Split-Engine für vier Karten, ohne Architektur-Hardcoding

**Bedienung: [LESEN.md](LESEN.md)** (check / einspielen / zurücknehmen / Ablauf vor `update.sh`). Details hier unten.

Der Patch, der aus Strata 0.1.60/0.1.61 die Split-Engine macht, die **jede Schicht auf allen Karten** laufen lässt
(2–4 Karten), plus die Skripte, die sie auf einem Rechner zum Laufen bringen, den niemand hier je gesehen hat.

**Basis:** `c77572806` = Tag **v0.2.15** (Control 0.1.61, Engine-Paket 0.1.60). **Ast mit dem Patch:**
`agent/hermes-split4-arch-0161` in `pott/strata_lokal` (getragen von `agent/hermes-split4-arch` per
`git rebase --onto c77572806 7726f80c`, darunter der delta3-Nachzug; alter Schnitt: Tag
`archive/split4-on-7726f80c`).

## Worum es geht

Der Split war nie auf `sm_86` hartcodiert — er war nur **nicht freigeschaltet** und an einer Stelle **an eine
Zahl gebunden, die niemand aufgeschrieben hatte**. Beides ist jetzt anders:

| | vorher | jetzt |
|---|---|---|
| Build-Architektur | `STRATA_SPLIT_ARCH`, Default 86, nirgends erklärt | dieselbe Variable, aber die Karte wird gefragt (`install.sh`) und die Zahl kommt aus einer Tabelle |
| Was eine Karte kann | verteilt als `#if FNX_ARCH >= 80` über die Kernel | **`src/split/src/arch_caps.hpp`**: Shared Memory je Karte, dp4a, die beiden f16-mma-Familien, int8-Attention |
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
| `split4/strata_split4_all.patch` | der eine Großpatch (Basis `c77572806`, 991 Zeilen, 15 Dateien; der gelegte Baum unterscheidet sich **null Zeilen** von der Ast-Spitze) |
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

