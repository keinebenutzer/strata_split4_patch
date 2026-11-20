# strata_split4_patch — die All-Cards-Split-Engine für 2–4 Karten, ohne Architektur-Hardcoding

**Bedienung: [LESEN.md](LESEN.md)** (check / einspielen / zurücknehmen / Ablauf vor dem Update). Details hier unten.

Der Patch macht aus Stratas Split-Engine eine, die **jede Schicht auf allen Karten** laufen lässt
(2–4 Karten), ohne den Build an eine einzige GPU-Architektur zu binden — plus die Skripte, die sie
auf einem Rechner zum Laufen bringen, den niemand im Voraus kennt.

**Basis:** `12d491da4` = Tag **v0.2.17** (Engine **0.1.63**). Ältere Schnitte bleiben als Tags
erhalten: `archive/split4-on-58ee32277` (v0.2.16 / Engine 0.1.62), `archive/split4-on-c77572806`
(v0.2.15), `archive/split4-on-7726f80c` (0.1.59.1). Wer auf einem älteren Stand bleibt, holt sich
den passenden Schnitt über den Tag.

## Worum es geht

Der Split war nie auf eine Architektur hartcodiert — er war nur **nicht freigeschaltet** und an
einer Stelle **an eine Zahl gebunden, die niemand aufgeschrieben hatte**. Beides ist jetzt anders:

| | vorher | jetzt |
|---|---|---|
| Build-Architektur | `STRATA_SPLIT_ARCH`, Default 86, nirgends erklärt | dieselbe Variable, aber die Karte wird gefragt (`install.sh`) und die Zahl kommt aus einer Tabelle |
| Was eine Karte kann | verteilt als `#if FNX_ARCH >= 80` über die Kernel | **`engine/src/split/src/arch_caps.hpp`**: Shared Memory je Karte, dp4a, die beiden f16-mma-Familien, int8-Attention |
| Prompt-Kernel-Layout | 32 Spalten (CUDA) / 16 Spalten (HIP) — nach Backend entschieden | nach der **Shared-Memory-Grenze der Karte** entschieden; ein `static_assert` meldet eine unpassende Karte zur Build-Zeit statt nach drei Minuten Modell-Load |
| Kernel-Beweis auf einer fremden Karte | nur für AMD (Selftest war in CMake an HIP gebunden) | **auch für NVIDIA**: `strata-split-selftest` wird für CUDA gebaut, und die Engine läuft ihn vor dem Modell-Load auf jeder Architektur, die Strata nicht gefahren ist |
| Kartenanzahl 4 auf sm_86 | in der Regel-Tabelle nicht gelistet (auto sagte nein) | gelistet: gefahren und gemessen (4× A4000, 106–125 tok/s je nach Kontext) |
| Eine unbekannte Architektur | „only been run on sm_86/sm_120 cards" und Schluss | die Regel sagt in Worten, was die Karte hat: `arch_note` — „sm_75: 64 KiB shared memory a block, prompt kernel drops to 16 columns, 32 need 73 KiB, self-test proves the kernels first" |

## Die eine echte Architektur-Grenze (das war die Überraschung)

`k_gdn_ch_rec` (der Prompt-Pfad des rekurrenten Teils) braucht **72,6 KiB dynamisches Shared Memory**
pro Block. Die published Limits: 7.5 Turing **64 KiB**, 7.0 Volta 96 KiB, 8.6/8.9/12.x 99 KiB,
8.0 163 KiB, 9.0/10.x 227 KiB.

→ **vier Turing-Karten (2080, 3090, T4) können den 32-Spalten-Layout nicht starten.** Der Baum hatte
die Lösung schon, aber nur für AMD: 16 Spalten sind 56,6 KiB, bit-identische Ergebnisse. Diese Wahl
hängt jetzt an der Grenze der Karte, nicht am Backend. Fluchtweg ohne alles:
`FNX_PF_GDN_CHUNK=0` (Reihe-für-Reihe-Kernel, 0 dynamisches Shared Memory).

Decode-Kernel sind unkritisch (18,0 KiB). `sm_98` gibt es nicht; reale Stufen sind 75, 80/86/87, 89,
90, 100/103/107/110, 120.

## Die Dateien

| Datei | was sie tut |
|---|---|
| `split4/strata_split4_all.patch` | der eine Großpatch (Basis `12d491da4`, 1157 Zeilen, 19 Dateien, +660/−48) |
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

# 3) Vor jedem Update: zuruecknehmen, danach wieder apply
bash install.sh --baum /pfad/zum/strata --zurueck
bash install.sh --baum /pfad/zum/strata
```

Der Build braucht CUDA: `-DSTRATA_ENABLE_CUDA=ON -DSTRATA_BUILD_SPLIT=ON -DSTRATA_SPLIT_CARDS="4" -DCMAKE_CUDA_ARCHITECTURES=<cc>`.
(`STRATA_BUILD_SPLIT` allein reicht nicht — ohne `STRATA_ENABLE_CUDA` sagt CMake „needs a Linux CUDA or HIP build, skipped“.)

## Was der Sprung auf 0.2.17 (Engine 0.1.63) geändert hat

* **Der Patch wuchs von 17 auf 19 Dateien — die Maschinen-Tempo-Einstellungen sind jetzt Teil des
  Patches.** Upstream plant Draft-Ketten und Batch-Abläufe mit Kostenzahlen einer einzigen
  Referenzkarte. Eine Maschine, deren Runden anders kosten, plante dann über ihren eigenen
  Break-even hinaus und verlor Tempo. Der Patch macht diese Zahlen konfigurierbar:
  * `session.cpp`: Draft-Kettenkosten über `FNX_DRAFT_ROUND_MS`, `FNX_DRAFT_ROW_MS`, `FNX_DRAFT_CALL_MS`
  * `batch.cpp`: Batchplan-Kosten über `FNX_BATCH_ROUND_MS`, `FNX_BATCH_ROW_LO`, `FNX_BATCH_ROW_HI`,
    `FNX_BATCH_CALL_MS`, `FNX_BATCH_CHAIN_MS`, `FNX_BATCH_GROUP_MS`, `FNX_BATCH_KNEE`
  * `sfnx.cpp`: `FNX_BATCH_DEPTH_STATS=1` druckt die tatsächlich gemessene Akzeptanz je
    Draft-Position — so findet man die passenden Zahlen für die eigene Maschine, ohne zu raten.
  Ohne diese Umgebungsvariablen gilt unverändert Upstreams Standardverhalten.
* **Upstream hat die Tensorumwandlung des Split-Lesers überarbeitet** (parallele Umwandlung der
  dichten Tensor beim Laden). Der Patch folgt dort upstreams Version; die eigene
  IQ2-Punktkern-Nachrüstung (siehe 0.2.15-Abschnitt) bleibt davon unberührt bestehen.

## Was der Sprung auf 0.2.16 (Engine 0.1.62) geändert hat

* **Der Baum ist umgezogen** (Layout-Move `4058aa782`): `engine/` für den Engine-Quell
  (`engine/src/split/...`), `terminal/` für `setup.py`, `strata_cli`, `strata_control` und die Tests.
  Gebaut wird `cmake -S engine`. `install.sh` und `check_split4.py` erkennen beide Layouts.
* **`src/split/tools/qdot_test.cu` gibt es nicht mehr:** Upstream entfernte mit „own-stack step 10"
  (`3e26b4e15`) die vendored `ggml-cuda` und mit ihr den Bitgleichheits-Test für die IQ2-Dots.
  Die `vec_dot_iq2_xs_q8_1` / `vec_dot_iq2_xxs_q8_1` in `qdot.cuh` sind weiter drin, aber ihr
  Oracle ist weg — `split_qdot_golden` (der gebliebene Digest-Test) kennt nur bis IQ2_S.
  **Offene Lücke:** ein IQ2-Zweig für `qdot_golden` ist noch zu schreiben.
* **Nachzug beim Bau:** der ergänzte CUDA-Zweig `strata-split-selftest` braucht Stratas eigene
  Quant-Includes (`${_sp_quant}`) statt der entfernten ggml-cuda-Pfade.
* Die Kartenanzahl ist eine CMake-Regel: `STRATA_SPLIT_CARDS` akzeptiert nur 2, 3 oder 4 —
  `install.sh` sagt das jetzt, bevor CMake abbricht.

## Was der Sprung auf 0.2.15 (Engine 0.1.60) geändert hat — und die IQ2-Falle

* **Upstream hat die eigenen Punktkerne des Split-Engine-Decode ersetzt:** `src/split/src/qdot.cuh`
  (Commit `58414f3ec`). Der Typ-Enum heißt jetzt `GgmlType` mit `T_*`, und es gab keine
  `vec_dot_iq2_xs_q8_1` / `vec_dot_iq2_xxs_q8_1` mehr.
* **Deshalb war IQ2_XS/IQ2_XXS aus dem Patch gefallen — und das war ein Irrtum.** Ein Modell kann
  nach IQ3_XXS heißen und trotzdem gemischte geroutete Experten führen (gemessen: 20× IQ2_XS und
  18× IQ2_XXS im Produktivpack). Der erste Start ohne die Dots kippte mit
  `blk.0.ffn_gate_exps.weight is ggml type 17`. **Nachzug (delta4):** `qdot.cuh` führt
  `vec_dot_iq2_xs_q8_1` und `vec_dot_iq2_xxs_q8_1` als Upstream-Text aus `vecdotq.cuh`
  (nur `ggml_cuda_dp4a` → `qd_dp4a`), Dispatch in `kernels.cu`, Annahme zurück in `model.cpp`.
  Bit-Identität gegen `vecdotq.cuh` im `qdot_test` (13 Formate). CUDA only; ein HIP-Bau weist die
  Typen per `static_assert` ab. Prompt-Pfad weiter über `FNX_PF_MOE_Q8=1` (keine IQ2-Prompt-Kacheln).
* Upstream hat inzwischen selbst `T_IQ2_XXS`/`T_IQ2_XS` im Enum — das ist im Schnitt respektiert,
  nicht ersetzt.

## Was bewiesen ist und was nicht

* **bewiesen (20.11.2026, Schnitt auf `12d491da4` = v0.2.17 / Engine 0.1.63):** Zyklus auf frischer
  Worktree — `check` konfliktfrei (19 Dateien), `apply`, gelegter Baum **null Zeilen** vom
  Patch-Schnitt entfernt, `revert` sauber (0 Dateien). Auf einem Produktivrechner mit **4× RTX A4000
  sm_86** gebaut und gefahren: `strata-split-4` mit 262144 Kontext, 110–125 tok/s im Dauerbetrieb.
* **bewiesen (19.11.2026, Schnitt auf `58ee32277` = v0.2.16 / Engine 0.1.62, 1× A4000 sm_86,
  CUDA 12.8):** Zyklus konfliktfrei (17 Dateien), Bau `-S engine -DSTRATA_ENABLE_CUDA=ON
  -DSTRATA_BUILD_SPLIT=ON -DSTRATA_BUILD_TESTS=ON -DSTRATA_SPLIT_CARDS="2"
  -DCMAKE_CUDA_ARCHITECTURES=86`: `strata-split-2` (77 MB) und `strata-split-selftest` fehlerfrei.
  **CUDA-Selbsttest auf der Karte grün:** `self-test PASSED in 226 ms: card 0: wmma, expert tile,
  dense product, dp4a, recurrent step against a scalar reference`. CPU-Unit-Tests und
  73 Split-Python-Tests grün.
* **bewiesen (Gegenbau für eine andere Architektur):** `strata-split-4` und `strata-split-selftest`
  bauen für **sm_75** (Turing, 64 KiB) konfliktfrei durch. Wird das 32-Spalten-Layout erzwungen,
  **scheitert der Build am Compile-Zeitpunkt** mit `static assertion failed with "k_gdn_ch_rec asks
  a card for more shared memory than a block can opt into"` — auf sm_86 ist derselbe Build grün.
* **nicht gefahren:** vier Turing-Karten (sm_75) — der Patch macht den Build möglich und meldet die
  Grenze, aber ein echter Lauf auf vier 3090 steht aus. Ebenso sm_89, sm_90, sm_120 mit vier Karten.
* Die Engine sagt bei einer Architektur, die Strata nicht gefahren ist, jetzt **in Worten**, was sie
  kann und dass sie experimentell ist (`arch_note`), und prüft die Kernel, bevor das Modell geladen
  wird. `FNX_SELFTEST=1` erzwingt den Test auch auf einer bekannten Karte, `FNX_SELFTEST=0`
  überspringt ihn.

## Patch-Pflege

Bei jedem Upstream-Sprung wird der Patch gegen den neuen Tag neu geschnitten und der Zyklus
(check → apply → Vergleich → revert) auf einer frischen Worktree wiederholt, bevor er ausgeliefert
wird. Der jeweils abgelöste Schnitt bleibt als `archive/`-Tag erhalten.
