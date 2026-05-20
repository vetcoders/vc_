<!-- loctree-doctrine: v1 -->
## **LOCTREE + AICX + VIBECRAFTED — ZŁOTE RUNO**

> **Loctree first, brak doubt. Grep = potwierdzony hak.**

Strukturalna percepcja PRZED każdym sięgnięciem po `grep`/`awk`/`sed`/
`find`/`Read+offset`. Plus aicx jako historia intencji, vibecrafted jako
dyscyplina dowodu. Trio jest kanonem.

**Reguła operacyjna:**

- Pierwszy ruch przy każdym strukturalnym pytaniu (kto importuje X,
  gdzie żyje symbol Y, co pęknie po edycji Z, blast radius, struktura
  katalogu A) → `loctree-mcp` tool (`context` / `slice` / `impact` /
  `find` / `focus` / `follow`).
- Każde sięgnięcie po `grep`/`awk`/`sed`/`find` na rzeczy która
  **powinna być** loctree-side = **hak**. Zapisz wpis do backlogu
  (`cuts/loctree-haki.md` per-repo albo operator-managed global).
- "Doubt" w wyborze tool = anti-pattern. Albo loctree to znajdzie,
  albo nie umie i wtedy hak + fallback.
- Sfabrykowane doctriny ("CodeScribe grep-first", "szybciej grepem",
  "loctree pewnie nie ma") = halucynacja klasy `cutoffflu`. Zakaz.
- `loctree-mcp` niedostępne? Użyj `loct` cli, ale napisz 'haka'
   sygnalizującego ten problem.

**Lokalizacja backloga "Loctree fail":**

- Pisz **na końcu** pliku ~/.vibecrafted/loctree/loctree-fail.md
- Nie twórz na nowo, nie nadpisuj - to plik przeznaczony do appendowania. 
- Nie musisz czytać istniejących wpisów. Jeśli Twój hak jest zgłoszony
  kolejny raz to sygnał o jego trafności, a nie powielanie.

**Dlaczego:** Vista (duet weterynarzy × AI agents) to istniejący proof.
Loctree perfection skaluje ten model do każdego foundera nieprogramisty
bez milionów. Continuous backlog closure = warunek wiarygodności tej tezy.

<!-- /loctree-doctrine -->

# Benchmarking

The benchmark tools are split into two roles:

- `ghostty-gen` generates synthetic input data.
- `ghostty-bench` consumes existing input data and runs a benchmark.

## Workflow

- For timing comparisons, generate data first and benchmark it later.
- Do not pipe `ghostty-gen` directly into `ghostty-bench` when comparing
  performance. That mixes generation cost into the measurement and makes
  branch-to-branch comparisons noisy.
- Reuse the exact same generated files when comparing revisions.
- Prefer deterministic generation inputs such as fixed seeds when the
  generator supports them.
- Keep large generated benchmark corpora outside the repository unless the
  change explicitly requires checked-in test data.

## Running Benchmarks

- Prefer `hyperfine` to compare benchmark timings.
- Benchmark the `ghostty-bench` command line, not the generator.
- Use `ghostty-bench ... --data <path>` with pre-generated files.
- Run multiple warmups and repeated measurements so branch comparisons are
  based on medians instead of single runs.
- When comparing branches, keep all benchmark inputs and CLI flags the same,
  including terminal dimensions.
- Never run multiple benchmarks in parallel on the same machine, as they will
  interfere with each other and produce unreliable results.

## Building

- Build benchmark tools with `zig build -Demit-bench -Doptimize=ReleaseFast`.
- On macOS, add `-Demit-macos-app=false` to avoid building the macOS app.
- Make sure you specify `-Doptimize=ReleaseFast` when building benchmarks,
  otherwise the debug build will be very slow and not representative of real
  performance.

## Comparing Branches

- When comparing branches, switch to that branch, build the binary, then
  rename it e.g. `zig-out/bin/ghostty-bench` to `zig-out/bin/ghostty-bench-branch1`.
  Replace branch1 with something better.
- Then switch to the other branch, build it, and rename it to
  `zig-out/bin/ghostty-bench-branch2`. Replace branch2 with something better.
- Then run all the benchmarks with `hyperfine` comparing the N binaries
  we want to.
