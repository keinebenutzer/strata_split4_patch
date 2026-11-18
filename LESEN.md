# LESEN.md — Bedienung

Am einfachsten: **in den Ziel-Ordner wechseln** und das Script mit relativem Pfad
aufrufen. Das Zielverzeichnis ist dann der aktuelle Ordner — ein zweites Wort braucht es nicht:

```bash
cd ~/Machen/Strata
bash ../strata_split4_patch/apply_patch.sh check    # 1) testen
bash ../strata_split4_patch/apply_patch.sh apply    # 2) einspielen
bash ../strata_split4_patch/apply_patch.sh revert   # 3) zurücknehmen
```

Syntax immer: **zuerst der Modus** (check|apply|revert), **dann optional das Zielverzeichnis**.
Kein `-C` wie bei git. Von jedem beliebigen Ordner aus geht auch:

```bash
bash /pfad/zu/strata_split4_patch/apply_patch.sh check ~/Strata
```

## 1. Testen

`konfliktfrei auf diesem Stand.` → einspielen. Fehler mit Konfliktzeilen → der Baum steht nicht
auf der Patch-Basis (steht im README) oder ein anderer Patch liegt uncommittet darauf. Dann:
`git stash` → `./update.sh` → erneut testen. **Nie `git stash pop` nach dem update.**

## 2. Einspielen

`angewandt (nicht committet).` — danach bauen (der Befehl steht im README und wird von
`check_split4.py` für den jeweiligen Rechner ausgedruckt).

## 3. Zurücknehmen

`zurueckgenommen.` — Baum wieder im reinen Upstream-Stand.

## 4. Der Ablauf vor `update.sh` (Regelfall)

```bash
cd ~/Strata
bash ../strata_split4_patch/apply_patch.sh revert    # 1) Patch runter
./update.sh                                          # 2) Upstream ziehen
bash ../strata_split4_patch/apply_patch.sh apply     # 3) Patch wieder rauf
```

## Bequemer: ein Durchgang für alles

```bash
python3 ../strata_split4_patch/check_split4.py --baum ~/Strata --modell ~/Modelle/modell.gguf
python3 ../strata_split4_patch/check_split4.py --baum ~/Strata --als-ob 75     # was wäre ein Rechner mit Turing-Karten?
bash      ../strata_split4_patch/install.sh    --baum ~/Strata --selbsttest
bash      ../strata_split4_patch/aufraeumen.sh --baum ~/Strata --zyklus
```

`install.sh` fragt die Karten ab, baut für deren Architektur und beweist die Kernel.
`--nur-pruefen` ändert nichts, `--zurueck` nimmt den Patch ab, `--ohne-bau` baut nicht.
