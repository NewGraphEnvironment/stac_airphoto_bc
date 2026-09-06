# stac_airphoto_bc

STAC pipeline for BC historical air photos — fetch, georef, COG, S3, STAC catalog.

## Repository Context

**Repository:** NewGraphEnvironment/stac_airphoto_bc
**Primary Language:** R + Python (conda env `stac-airphoto-bc`)
**SRED:** NewGraphEnvironment/sred-2025-2026#22
**Live:** [images.a11s.one/collections/stac-airphoto-bc](https://images.a11s.one/collections/stac-airphoto-bc)
**Pages:** [newgraphenvironment.com/stac_airphoto_bc](https://www.newgraphenvironment.com/stac_airphoto_bc/)

## Current State

- 9,976 georeferenced thumbnail COGs, 1967–2019
- Two regions: Neexdzii Kwa watershed (9,741) and three small southeast BC AOIs (235)
- 30.3 GiB on S3 (`s3://stac-airphoto-bc`)
- Registered on pgstac via `images.a11s.one`
- GDAL metadata tags embedded in each COG (visible in QGIS)
- STAC item titles: `airp_id — roll_frame — date`

## Architecture

Built on [fly](https://github.com/NewGraphEnvironment/fly) (>= 0.5.0).

### fly package provides

- `fly::fly_fetch()` — downloads thumbnails/flight logs (parallel via `workers` param)
- `fly::fly_georef()` — warps images to estimated ground footprints as GeoTIFFs (BC Albers 3005), with `rotation` param for flight line bearing correction
- `fly::fly_footprint()` — estimates ground coverage rectangles from centroids + scale
- `fly::fly_select()` — greedy set-cover photo selection with `component_ensure` param
- `fly::fly_filter()` — spatial filtering by footprint or centroid

### Pipeline

| Step | Script | What |
|------|--------|------|
| Fetch | `01_fetch.R` | Query BC Data Catalogue centroids, select by footprint overlap, write the ledger, download thumbnails |
| Georef | `02_georef.R` | Warp thumbnails to ground footprints (BC Albers 3005) |
| COG | `03_cog.R` + `03_cog_tag.py` | Convert to COGs (DEFLATE), embed GDAL metadata tags via rasterio |
| STAC | `05_stac_register.py` | Generate items, **merge** into the published collection, validate |
| S3 | `04_s3_upload.R` | Back up `collection.json`, then `aws s3 sync` (never `--delete`) |

Registration runs **before** the sync, so a run uploads its own STAC output.

Run end-to-end: `bash scripts/run_pipeline.sh [aoi_id ...]`

### The AOI is a parameter

`scripts/aoi.R` is the registry — `neexdzii_kwa` (watershed), `se_a`, `se_b`,
`se_c` (bboxes). Every stage takes ids on the command line and does all
registered AOIs when given none; an unknown id aborts before any work.

Per-AOI: centroid cache, AOI polygon, selected set, ledger, logs, report.
Global and year-partitioned: `data/raw/`, `data/stac/`, and S3. Two overlapping
AOIs therefore share a frame rather than publishing it twice.

`data/select/<id>.csv` is a ledger with one row per candidate and exactly one
outcome, reconciled against the centroid cache. `data/reports/<id>.md` renders
from it.

Registration on geopro (separate step):
```bash
ssh root@<GEOPRO_IP> "bash /tmp/stac_register-pypgstac.sh stac-airphoto-bc https://stac-airphoto-bc.s3.us-west-2.amazonaws.com"
```

### Embedded COG metadata

Each COG carries GDAL tags (visible in QGIS Layer Properties → Information):
`AIRP_ID`, `PHOTO_DATE`, `SCALE`, `FILM_ROLL`, `FRAME_NUMBER`, `FOCAL_LENGTH`, `FLYING_HEIGHT`, `FILENAME`

Tags set via `03_cog_tag.py` (rasterio) because `terra::metags` can't persist custom tags.

### Source data

- BC Data Catalogue centroid layer: `airp_id`, `photo_date`, `scale`, `focal_length`, `flying_height`, `thumbnail_image_url`, etc.
- ~97% of photos have thumbnail URLs (openmaps.gov.bc.ca/thumbs/ JPGs, ~1250x1250)
- Grayscale (1 band) pre-1986, RGB+alpha (4 band) post-1986

### Directory conventions

Asset type (`thumbs`, `scans`) carried through every stage:

```
data/raw/thumbs/{year}/*.jpg              — downloaded thumbnails
data/raw/georef/thumbs/{year}/*.tif       — georeferenced GeoTIFFs
data/stac/thumbs/{year}/*.tif             — COGs (synced to s3://stac-airphoto-bc/)
```

One STAC collection (`stac-airphoto-bc`), one item per physical photo (`airp_id`), multiple assets:

```json
{
  "id": "695106",
  "properties": { "title": "695106 — bc5281_084 — 1968-07-15" },
  "assets": {
    "thumbnail": { "href": ".../thumbs/1968/bc5281_084_thumb.tif" },
    "visual":    { "href": ".../scans/1968/bc5281_084.tif" }
  }
}
```

### Caching strategy

- `data/centroids_raw.parquet` — cached BC Data Catalogue query (gitignored, re-query with `force_refresh = TRUE`)
- `fly_filter()` re-runs fresh each time (footprint estimates may change)
- `fly_fetch(overwrite = FALSE)` skips existing files on disk
- `03_cog.R` skips existing COGs; `03_cog_tag.py` skips already-tagged COGs

### Known issues

- Diagonal flight lines (~230°, ~45° bearings) may still have rotation issues (fly#26). Workaround: set `rotation` column per roll.
- The `fly_georef(rotation = "auto")` rebuild (#13) **shipped 2026-03-12**. A further
  rebuild — fly 0.9, per-roll `rotation`, DEM-corrected footprints — is not yet filed
- 249/9,990 photos missing thumbnail URLs in BC catalogue
- **Digital frames are excluded.** `fly` (>= 0.4.0) will not size a footprint
  without a sensor width (fly#32). The Neexdzii Kwa items predate that and were
  sized as 9-inch negatives — `bcd12008` ships an 11,435 m footprint against
  2,286–7,242 m for film. Those wrong items are still published; the southeast
  AOIs simply stopped adding more.
- **`fly_footprint()` drops `footprint_basis` on tibble input** (fly#35), which
  is what `bcdata` returns. `aoi_centroids_as_sf()` coerces around it — remove
  that once fly#35 lands.
- No DEM-corrected footprints yet. fly 0.5.0's `dem` argument would grow
  footprint area by a median 14%; applying it to one region only would leave the
  collection half-corrected, so it waits for a rebuild of both.
- `stac_register-pypgstac.sh` on geopro **deletes and reloads** from
  `collection.json`, so that file is load-bearing. It also aborts after the
  delete if any item fetch fails, which leaves the collection briefly empty.

<!-- BEGIN SOUL CONVENTIONS — DO NOT EDIT BELOW THIS LINE -->


# Code Check — Shell

Tool-level traps in bash, sed, git and `gh`, and in the host toolchain those commands
depend on. These load everywhere because they are about the shell the agent runs
commands in, not about `.sh` files in the repo.
The general mechanisms — a guard that fails toward pass, a fixture that cannot
reach the failure mode — live in `code-check.md`; this file is the quirks.

### `git diff a..b` compares TIPS; a change on `a` shows up as the branch's

Two-dot is the difference between two commits. Three-dot (`a...b`) is the difference from
their **merge base** — what the branch actually did, and what GitHub shows in a PR.

So anything that landed on the base since the branch forked appears **inverted** in a
two-dot diff: a file `main` *deleted* reads as a file the branch *added*.

Measured 2026-09-04 in rtj. A branch touched four files. `git diff --stat main..branch`
listed five, the extra being a one-line addition to a CSV. `main` had removed that line in a
merged PR; the branch had never touched the file at all:

```
two-dot   : CLAUDE.md docs/… env/prod/main.tf progress.md manifest.csv
three-dot : CLAUDE.md docs/… env/prod/main.tf progress.md
```

It cost a wrong merge-order rationale written into a PR description ("merge #279 first,
both touch this file"), caught by the PR reviewer reading the diff GitHub renders. The
failure is quiet because the two-dot output is *correct* — it answers a question nobody
asked.

- Use `a...b` for "what does this branch change", which is nearly always the question.
- `git log a..b` is the opposite convention and two-dot is right there — it lists commits
  reachable from `b` and not `a`. The asymmetry between `log` and `diff` is the trap.
- Confirm against the branch's own commits when it matters:
  `git log --oneline a...b -- <path>` shows *which* side touched a file.

### git pathspec excludes: use the long form
- `:!path` is short-form magic, and git keeps parsing magic characters after the
  `!`. A path starting with one aborts the whole command:
  `:!_pkgdown.yml` → `fatal: Unimplemented pathspec magic '_'`.
- Use `:(exclude)path`. `:!./path` also works, but the long form says what it means.
- Anything building pathspecs from a file (`.Rbuildignore`, `.gitignore`) will
  eventually meet a leading `_`, `(`, or `^`.

### `sed 1d f1 f2 f3` strips only the FIRST file's header

`sed` treats multiple file arguments as one concatenated stream, so a line-address
script applies once across the whole set rather than per file. Stripping CSV headers
this way — especially via `find … -exec sed 1d {} +`, which batches many files into one
invocation — leaves every header but the first embedded in the data.

It is silent, and it lands rows that parse. Caught 2026-08-30 concatenating 24 paged WFS
responses: 23 stray header rows entered a 223,667-row analysis and showed up only as a
row-count reconciliation failing by exactly 23.

```bash
for f in pages/*.csv; do sed 1d "$f"; done > combined.csv   # per file
awk 'FNR>1' pages/*.csv > combined.csv                      # or FNR, which resets
```

Reconcile the row count against what the source said it would be. That is the check that
catches this, and it costs one line.

### `sed -n '/X/,$d' file` prints nothing at all

`-n` suppresses auto-print, and `d` only deletes — so nothing is ever emitted and the
output is empty. The intent (print up to a marker) needs `sed '/X/,$d'` without `-n`, or
`sed -n '1,/X/p'`.

Fails toward an **empty file**, which downstream reads as "no matches" rather than as a
broken command. Same family as "A guard that fails toward pass" in `code-check.md`: the
silent direction is the dangerous one.

### Reading a file line-by-line drops the last line without a trailing newline
- `while IFS= read -r line; do ...; done < file` skips a final line that has no
  newline after it. Use `while IFS= read -r line || [ -n "$line" ]`.

### Empty arrays under `set -u` on bash 3.2
- macOS still ships bash **3.2**, where `"${ARR[@]}"` on an empty array is an
  unbound-variable error under `set -u`. Guard with `[ ${#ARR[@]} -gt 0 ]`
  before expanding. Scripts written and tested on Linux bash 5 hit this only on
  a Mac, and only when the array happens to be empty.

### Quoting
- Variables in double-quoted strings containing single quotes break if value has `'`
- `"echo '${VAR}'"` — if VAR contains `'`, shell syntax breaks
- Use `printf '%s\n' "$VAR" | command` to pipe values safely
- Heredocs: unquoted `<<EOF` expands variables locally, `<<'EOF'` does not — know which you need
- Unquoted heredocs also run **command substitution**: backticks in prose (markdown code spans!) execute and are replaced by their output, usually empty. Writing markdown through an unquoted heredoc silently deletes every `` `word` `` in it — no error, and the damage only shows on re-read. Seen 2026-08-06 writing a memory index line: a markdown code span followed by "gone as a concept" landed as "gone as a concept", subject removed. Any heredoc carrying prose or markdown wants `<<'EOF'`.
  - **The rule collapses the moment you also need interpolation.** `<<'EOF'` is
    the fix for prose and `<<EOF` is the fix for variables, and a heredoc that
    needs both has no safe form — which is exactly when the trap fires, because
    the quoting choice now looks forced rather than careless. Seen again
    2026-08-26 in rfp#186 writing a findings file that had to carry a generated
    project name: `` `normal` `` in a markdown table ran as a command and its
    empty output replaced the word, leaving `| enabled, , **resolves** |`.
    Escaping the backticks individually is not a fix either — you have to get
    every one, and the misses are silent.
  - Fix: keep the heredoc quoted and substitute afterwards, or write the file
    from Python where there is no substitution layer at all:
    ```bash
    cat > out.md <<'EOF'      # prose safe, placeholder left literal
    Project: __NAME__
    EOF
    sed -i '' "s|__NAME__|$NAME|" out.md
    ```
  - Detection is cheap and worth doing whenever prose went through an unquoted
    heredoc: `grep -n ', ,\|(( ))\|  |' file` finds the empty spans a swallowed
    code span leaves behind.
- Pass-through-ssh args: `printf '%q'` escapes per-arg so workload paths with spaces / quotes / metacharacters survive the local-shell → ssh-argv → remote-shell round-trip. Without it, `ssh host 'cmd' "$path"` joins args with spaces on remote and re-parses, losing argument boundaries.
- **A plain `git commit -m "…"` runs command substitution too, and unlike the heredoc cases it
  SUCCEEDS.** The rules above are about forms that fail loudly. This one does not: backticks in a
  double-quoted `-m` string execute, bash prints `something: command not found` to **stderr**, and
  the commit lands anyway with the span replaced by empty output. Seen 2026-09-02 in floodplains:
  a message reading ``prov_keys() now takes a `part` argument`` committed as "now takes a
  argument". The only signal was one stderr line scrolling past above a successful commit.
  - Markdown code spans are exactly what a good commit message is full of — function names,
    arguments, file paths — so the failure targets careful messages, not sloppy ones.
  - Fix is the one already prescribed for multi-line bodies, applied to single-line ones too:
    write the message to a file and `git commit -F`, or use single quotes when the text has no
    apostrophes. `git commit --amend -F msg.txt` repairs it after the fact.
  - Detection, since the commit is already made: `git log -1 --format=%B | grep -n "  \|takes a $"`
    finds the collapsed double spaces an eaten span leaves behind.
- `git commit -m "$(cat <<'EOF' ... EOF)"` chokes on apostrophes in prose bodies in some contexts — the bash parser surfaces an unmatched-quote error even though heredoc bodies should be quote-neutral. Resilient default for multi-line commit messages: write the body to `/tmp/msg.txt` and use `git commit -F /tmp/msg.txt`.
- **The same trap has a silent variant: `Rscript -e` / `python -c` carrying backslash escapes.** The heredoc case above fails loudly, which costs a retry. Passing a regex inline does not: `\\b` reaches the interpreter mangled, so `grepl()` returns 0 matches against text it matches perfectly from a file. Nothing errors. Seen 2026-07-31 in rfp#93 — the 0 read as "my regex is wrong" and nearly triggered a rewrite of working code; the identical regex scored 4 matches the moment it ran from `/tmp/x.R`.
  - Rule: anything carrying a regex, nested quotes or backslashes gets written to a file and run (`Rscript /tmp/x.R`). Inline `-e` is for trivial one-liners only.
  - Diagnostic: when an inline command returns a surprising *result* rather than an error, suspect the quoting layer before the code, and re-run from a file to find out which is wrong. That one step separates a real bug from a shell artifact.

### Heredoc precedence in pipelines
- `cmd1 | cmd2 <<EOF` — the heredoc binds to `cmd2` (the rightmost simple command). If you intended `cmd1` to receive it, put `<<EOF` on cmd1 explicitly: `cmd1 <<EOF | cmd2`.
- Symptom when wrong: ssh body silently echoed by tee/cat/etc, ssh side gets empty stdin, exits 0 (or near-0) without doing anything. Caught the hard way 2026-05-01 in cypher_restore-fwapg.sh.

### Paths
- Hardcoded absolute paths (`/Users/airvine/...`) break for other users
- Use `REPO_ROOT="$(cd "$(dirname "$0")/<relative>" && pwd)"`
- After moving scripts, verify `../` depth still resolves correctly
- Usage comments should match actual script location

### Diagnose env/PATH problems in the shell that actually runs, not the ambient one
- Get ground truth **before** forming any theory:
  `env -i HOME=$HOME TERM=$TERM bash -lc 'echo $PATH | tr ":" "\n" | nl'`
  (swap in `zsh` to check the other side). Numbering shows ordering and
  duplication in one read.
- **Claude Code runs bash regardless of the user's login shell**, so a PATH
  measured from an agent shell says nothing about the terminal the user sees.
  Establish which shell is interactive (`echo $0`, or the prompt style) before
  opening any rc file.
- **The mutation is usually one level down from the obvious file.** A
  `for file in ~/.{path,exports,aliases,extra}; do source "$file"; done` loop in
  `.bash_profile` hides real `PATH=` assignments in files you never opened. Grep
  every sourced file, not just the rc files.
- Caught 2026-08-19: a 39-entry PATH with 12 duplicates took **three** wrong
  diagnoses — `.zprofile` (which did run `brew shellenv` five times, but the
  interactive shell was bash, so it was irrelevant), then `.bashrc` sourcing
  `.bash_profile`, then tmux inheriting a stale env. The cause was `~/.path`
  hand-prepending what `brew shellenv` already sets, plus three directories that
  no longer existed. One `env -i` run ended it.
- The same mistake closed an infra issue prematurely: MacPorts was removed and
  verified **in bash**, while `.zprofile` kept exporting `/opt/local/bin` on
  every zsh login for months. Verified in one shell, broken in the one that runs.

### Parallel writers sharing one output file interleave mid-record
- `xargs -P N ... >> shared_file` (or any fan-out where N processes append to the same fd/path) is only safe while each record fits in a single `write()`. O_APPEND makes individual `write()` calls atomic, but a large record (anything beyond pipe/stdio buffer size, ~64 KB) spans multiple writes — concurrent jobs interleave mid-record and corrupt the file.
- The trap is latent: small records never trip it, so the pattern looks proven until the first large payload arrives. Caught 2026-07-11 in rtj's `stac_register-pypgstac.sh` — 20 parallel `curl | jq -c` jobs appending STAC items to one NDJSON worked for every prior collection (KB-scale items), then 9 MB floodplain items interleaved and produced an orjson decode error ~864 KB into line 1.
- Fix pattern: each parallel job writes its own temp file (unique name, e.g. md5 of the input), concatenate after the fan-out completes:
  ```bash
  cat urls.txt | xargs -P 20 -I {} fetch_one.sh {} "$OUT_DIR"   # each writes $OUT_DIR/<md5>.json
  find "$OUT_DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- **Concatenate with `find -exec … +`, never `cat "$OUT_DIR"/*`.** This fix is what
  creates the file count that then blows `ARG_MAX` — see "`cmd dir/*` dies on
  ARG_MAX at scale" below. The two traps are a matched pair, and writing the glob
  form here is what put the bug into rtj's registration script twice.
- Pair with a count guard — parallel `curl` failures under xargs are also silent: `[ "$(wc -l < combined.ndjson)" -eq "$EXPECTED" ] || exit 1` before any downstream load.

### `mktemp` template needs enough X's, and a failed `mktemp` leaves an empty var
- BSD/macOS `mktemp -d -t <name>` requires the template to contain at least 3 `X`s (`XXXXXX` is the safe default). Without them, mktemp errors to stderr (`too few X's in template`) and **prints nothing to stdout**.
- Pattern: `SCRATCH=$(mktemp -d -t aider-smoke) && cd "$SCRATCH" && <destructive>`. When mktemp fails, `$SCRATCH=""`. `cd ""` is a no-op that **leaves you in the caller's cwd**. The destructive command (`rm`, `git init`, `git add+commit`) then runs in cwd instead of a throwaway tmpdir.
- Caught the hard way 2026-05-13: a Claude smoke test inside the rtj checkout did exactly this, accidentally committed a `demo.R` to the active feature branch, which then rode the squash-merge into rtj/main and had to be cleaned up post-merge.
- Fix patterns:
  - Always use `XXXXXX` (6 X's) in the template: `mktemp -d -t aider-smoke.XXXXXX`.
  - Guard the result: `SCRATCH=$(mktemp -d ...) || exit 1; [ -n "$SCRATCH" ] || exit 1`.
  - Use `set -euo pipefail` so the failed command-substitution kills the script.

### `cmd dir/*` dies on ARG_MAX at scale — and only after the expensive work succeeded

- A glob expands to argv. 98k filenames is roughly 6 MB against a ~2 MB limit, so
  `cat "$DIR"/*.json` fails with `argument list too long` — **after** whatever
  produced those files already succeeded. Silent-after-success: the costly stage
  worked and the cheap one threw it away.
- Caught 2026-07 in rtj#196: it killed a STAC registration following a completed
  80-minute download.
- **Recurred 2026-08-29 in the same script**, because #196 wrote this entry but
  never repaired `rtj/scripts/geoserv/stac_register-pypgstac.sh`, and the
  parallel-writers entry above still prescribed the glob. 102,460 downloaded item
  JSONs concatenated fine with `find`; the load then took 27 seconds. The costly
  stage had already succeeded both times.
- The cost is worse than a wasted download when the script **deletes before it
  loads**: that registration removes the collection in step 2, so failing in step
  4 left a live public API serving zero items until it was repaired by hand. A
  destructive-then-rebuild sequence turns "retry it" into an outage.
- Safe form — `find` batches under the limit itself:
  ```bash
  find "$DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- The trap is latent, and it rides in on the fix for a different one:
  per-file fan-out (see "Parallel writers sharing one output file interleave
  mid-record" above) is correct, and it is exactly what produces the file count
  that later blows argv. Small sets look proven for as long as you test on them.

### A `curl` in a parallel fan-out needs `--max-time`

- Without it, one hung connection pins a worker slot indefinitely. Since a fan-out
  usually prints nothing until it finishes, a wedged pool and a slow pool look
  identical from outside — there is no signal to distinguish "still working" from
  "will never finish".
- Set `--max-time` on every per-URL fetch, and pair any silent multi-minute stage
  with a periodic progress line (a file count is enough). Same reasoning as
  `statement_timeout` on long DB work: the point is to fail loud rather than hang
  quiet.

### BSD vs GNU sed/grep portability (macOS hits this constantly)
- macOS ships BSD `sed`/`grep`. Linux CI/cloud-init hosts ship GNU. Snippets that work on one silently misbehave on the other.
- **`\+` and `\|` are GNU BRE extensions.** On BSD they're treated as literal `+` and `|`, so the regex still "matches" but matches nothing useful — leaving raw input unchanged.
  - Symptom seen 2026-05-28: `sed 's/[^a-z0-9]\+/-/g'` on macOS left spaces in an issue-title slug, producing an invalid git branch name.
  - Fix: use `sed -E` (POSIX ERE) so `+`, `|`, `?`, `(...)` all work without escapes on both flavors. The same regex becomes `sed -E 's/[^a-z0-9]+/-/g'`.
- **`s|pat|repl|` delimiter conflicts with `|` in alternation/replacement on BSD.** Pick a delimiter that does not appear in pattern or replacement (`#`, `,`, `:` are common choices). Compound `s|x|y|; s|^| /||` chains where the trailing `||` looks like an empty delimiter break on BSD sed even when GNU accepts them.
- **Don't parse `ls`.** BSD `ls` emits ANSI colour codes when stdout is a TTY *or* when `CLICOLOR_FORCE` is set in env (often by shell rc files), and the codes leak through pipes. Downstream `grep`/`sed` chokes on the embedded escapes (`[01;31m...[0m`).
  - **A third cause, and the one that bites agents: an alias in the invoking shell.** Measured 2026-08-28 — in an agent Bash call `ls` was aliased to `command ls --color`, so `ls -A dir | grep -v '^\.gitkeep$'` returned `^[[0m^[[00m.gitkeep^[[0m`, the grep failed to filter it, and a directory-empty guard false-failed on a correct tree. The identical command was fine inside a script file, where no alias applies and `ls` resolved to GNU coreutils — so testing it from a script *proves nothing about how it will run inline*. `CLICOLOR_FORCE` was not involved in that instance; check `type ls` before trusting either.
  - Use `find <dir> -maxdepth 1 -mindepth 1 -type d -exec basename {} \;` for directory listings, or `printf '%s\n' <dir>/*/` for a glob, or `for d in <dir>/*/; do basename "$d"; done`.
- **When writing a snippet you expect to ship in a `skills/` SKILL.md or any cloud-init runcmd**: it must be POSIX-portable. Default to `sed -E`, avoid `\+`/`\|`, and don't pipe `ls`.

### `&` binds to the whole `&&` list, so assignments never reach the parent

- `cmd1 && VAR=$(...) && nohup prog > "$VAR.log" & disown` backgrounds the
  **entire list**, not just `nohup`. `VAR` is assigned inside the background
  subshell, so it is empty in the parent — and a following `tail -f "$VAR.log"`
  reads the wrong path or errors while the job runs fine, writing somewhere you
  are not looking.
- The symptom lies about which side failed: the `tail` says
  `No such file or directory`, which reads as "the job never started". It started.
- Fix: assign **before** the list — `VAR=$(...); cmd1 && nohup ... &` — or
  `printf` the resolved path from inside the backgrounded shell so the parent can
  read it from output.
- Hit twice in one floodplains session (2026-08-27) launching detached runs.

### `gh` CLI
- **`gh pr create` resolves branch from CWD, not `--repo`**. Specifying `--repo NewGraphEnvironment/X` does NOT switch branch resolution — the command still reads the current working directory's checked-out branch. To open a PR in repo X, `cd` into X's checkout first, or pass `--head <branch>` explicitly.
- **`gh issue create` / `gh pr create` with heredoc bodies fail on prose containing special shell characters** (apostrophes, dollar signs, backticks). Use `--body-file /tmp/issue.md` instead — every project's `newgraph.md` convention specifies this; codified here for the underlying class. The two are written interchangeably, so the trap applies to both: `gh pr create --body "$(cat <<'EOF' … EOF)"` breaks the parser on a prose apostrophe and bash reports `unexpected EOF while looking for matching '"'`, aborting the whole command before anything runs.
- **Do not let a base-branch deletion decide a stacked PR's fate.** Merging the base
  does not retarget the child: it still points at a merged branch, `gh pr view` reports
  it `MERGEABLE`/`CLEAN`, and merging it there is a no-op against history already on
  main (seen 2026-08-30 merging rfp#231 then rfp#234). GitHub documents auto-retargeting
  when the base branch is *deleted*, and it is not dependable: measured 2026-08-31 in
  rfp, `--delete-branch` on the base **closed** the child two seconds after the merge
  (`base_ref_deleted` and `closed` share a timestamp), left `base` unchanged, and
  `gh pr edit --base` then refused with *"Cannot change the base branch of a closed
  pull request"*. Commits are safe either way — the head branch survives on origin —
  but the PR, its review thread and its CI attach have to be recreated. Retarget
  explicitly **while the child is still open**, then merge the base:
  ```bash
  gh pr edit "$CHILD_PR" --base main      # FIRST, and while it is open
  gh pr merge "$BASE_PR" --merge --delete-branch
  gh pr view "$CHILD_PR" --json mergeable,mergeStateStatus,statusCheckRollup
  ```
  Checks are attached to the head SHA, not the base, so they survive the
  retarget — but confirm rather than assume, since a required check configured
  per-base may not. If the child is already closed, reopen it *then* retarget, or
  open a fresh PR from the surviving head branch.
- **Before you *cut* a branch, verify local is current with origin.** The mirror of the
  rule below, and easier to miss because everything about the working tree looks fine. A
  clean tree and the right branch name say nothing about whether that branch is 19 commits
  behind. A branch cut from a stale base regenerates its content from stale input, and the
  PR either conflicts (loud, cheap) or auto-merges non-overlapping hunks and quietly
  reverts someone's newer edit (silent, expensive). Assert it:
  ```bash
  git fetch -q origin
  [ "$(git rev-list --count HEAD..@{u})" -eq 0 ] || { echo "local behind origin"; exit 1; }
  ```
  Caught 2026-08-28 syncing CLAUDE.md across 25 repos: preconditions checked clean-tree
  and on-default-branch but not up-to-date. `nrp-nutrient-loading-2025` was 19 behind, one
  of those commits having touched the same file, and the PR conflicted. The 24 that merged
  cleanly still had to be proven safe after the fact — by asserting the sync commit changed
  nothing above the CLAUDE.md marker, which is the invariant the operation actually claimed.
- **A per-item loop reports the wrapper's exit, not the items'.** `for r in ...; do
  script "$r"; done` exits 0 whenever the *last* item succeeds, however many failed before
  it. The task notification then says "completed (exit code 0)" over a batch with real
  failures in it. Same family as "A wrapper's exit is not the work" in `code-check.md`, and
  the fix is the same shape:
  gate on in-band markers. Print a per-item `OK`/`FAIL` line and count the FAILs, or
  accumulate `RC=$((RC+1))` and `exit "$RC"`. Never read a loop's exit as "all items
  succeeded".
- **Distinguish "the action failed" from "the cleanup after it failed".** A wrapper that
  treats any non-zero from `gh pr merge` as *merge failed* will report a false negative
  when the merge succeeded and only `--delete-branch` errored. Two of three failures in the
  same 2026-08-28 run were misreported this way — one had already merged. Re-read the
  authoritative state (`gh pr view --json state`) before acting on a failure report, rather
  than trusting the exit code of the compound command.
- **And the same compound can half-succeed while reporting success.**
  `gh pr merge --delete-branch` deletes the local branch before the remote one, so a local
  delete that fails takes the remote delete with it — and the command still reports the
  merge as done, because it was. Observed 2026-08-31: a **worktree** held the branch, `gh`
  printed `failed to delete local branch ... used by worktree at ...`, and the remote
  branch survived. Nothing else in the output suggested a branch had been left behind.
  Benign in isolation; it matters because a surviving branch reads as unmerged work to the
  next person, and because the worktree-per-session rule in `code-check.md` ("A shared
  working tree") makes the trigger routine rather than exotic. Confirm the deletion rather than assuming it, and
  verify the branch is merged before cleaning up by hand:
  ```bash
  gh pr merge "$PR" --merge --delete-branch
  git ls-remote --heads origin "$BRANCH"        # expect empty
  git merge-base --is-ancestor "$BRANCH_SHA" origin/main \
    && git push origin --delete "$BRANCH"
  ```
- **Never send a push's stderr to `/dev/null`.** The rule below assumes you *notice* an
  unpushed branch. Suppressing the push's error removes the only signal that it happened,
  and the very next step in the usual sequence — `git branch -D` after a merge — then turns
  the commit into a dangling object. `git push -q ... 2>/dev/null` is the shape; `-q`
  already silences success, so the redirect can only ever hide a failure. Caught 2026-08-29
  in soul: a suppressed rejection meant `gh pr create` had no branch to open against, the
  cleanup deleted the branch anyway, and the commit survived only via `git reflog`. Keep
  stderr, or test the exit status explicitly:
  ```bash
  git push -u origin "$BRANCH" || { echo "push failed"; exit 1; }
  ```
- **Before `gh pr merge`, verify the branch is fully pushed.** `gh pr merge` merges the REMOTE branch — commits made locally but never pushed are silently excluded, so the PR merges "successfully" while `main` is missing work you know you committed. Check `git status -sb` shows no `ahead N` before merging (or that `git rev-list --count @{u}..HEAD` is 0). Worse: if you then delete the local branch (`--delete-branch`, or a follow-up `git branch -D`), the unpushed commits become **dangling** — recoverable via `git reflog` / `git fsck --lost-found` then `git cherry-pick`, but only if you notice they're missing. Caught twice 2026-07 in `floodplains`: PR #6 merged 1 of 3 branch commits (the drift#34 `changes_only` fix + a CLAUDE.md update were unpushed → stranded as danglers → recovered and re-merged via a follow-up PR); a second branch sat 4-ahead-unpushed at compact time. The same check belongs in the `gh-pr-merge` skill's pre-merge step.

### On a fork, `main` may track upstream by design — comparing it answers nothing

`gh api repos/ORG/REPO/compare/upstream:main...ORG:main` returning
`ahead: 0, behind: 0, status: identical` reads as *"this fork has no local work"*. On a
fork whose workflow keeps `main` synced to upstream and puts the org's own commits on a
**named branch**, it means the opposite of nothing: it is the branch model working, and
every local commit is somewhere the comparison never looked.

Measured 2026-09-05 on `NewGraphEnvironment/db_newgraph`, a fork of `smnorris/db_newgraph`:
`main` was byte-identical to upstream while `newgraph` was **12 commits ahead**, plus five
other branches and a merged PR history against `newgraph` as the base. The identical result
was reported to the user as "a pristine fork, no local commits at all", and the work being
asked about was on an unmerged branch off `newgraph`.

Enumerate the branches before comparing anything:

```bash
gh api repos/ORG/REPO/branches --jq '.[] | "\(.name)  \(.commit.sha[0:8])"'
gh pr list --repo ORG/REPO --state all --limit 20 \
  --json number,state,headRefName,baseRefName \
  --jq '.[] | "#\(.number) \(.state) \(.headRefName) -> \(.baseRefName)"'
```

**The PR list is the tell** — a `baseRefName` that is not `main` names the branch the fork
actually develops on. It is also the cheapest way to find the convention, because a fork's
own `CLAUDE.md` documenting the pattern is itself on that branch and invisible from `main`.

Same family as "The probe is broken before the world is" in `code-check.md`: the comparison
ran correctly and answered a question nobody asked. The tell is a result that is *too clean*
for a repo someone just told you has commits in it.

### A destructive setup and its undo must not share one timeout-able command

```bash
git stash -q && Rscript -e 'lint_package()' && git stash pop -q
```

`lint_package()` exceeded the 120 s Bash timeout, the command was killed, and
**`stash pop` never ran** — an entire branch's work sat in the stash with a clean
working tree while a review subagent was concurrently reading those files. Recovered
with `git stash pop`, and only because the next command printed a suspiciously empty
`git status`.

Any `save; do-slow-thing; restore` chain has a window where a timeout, a crash or an
interrupt leaves the system in the saved state, and the longer the middle step the
wider it gets. `&&` does not help — the undo simply never executes.

- **Never stash to compare against a baseline.** `git show HEAD:path > /tmp/x` is
  non-destructive and answers the same question.
- Where a save/restore genuinely is needed, put the restore in a `trap … EXIT` (one
  handler per signal — see "A second `trap … EXIT` replaces the first" below), or run
  the two halves as separate commands so a timeout cannot swallow the second.

### `git checkout <path>` restores from the index, not from HEAD

After a `git add`, `git checkout <path>` reinstates the broken *staged* copy — so the
"fix" reproduces the failure and reads as though the edit was wrong.
`git checkout HEAD -- <path>` is the one that means what people expect.

### A value validated with one numeric grammar and consumed with another

`test` and `case` read base 10. `$(( ))` reads a leading zero as **octal**. GNU `seq`
silently produces nothing for a descending range (BSD `seq 0 -1` prints `0` and `-1`,
so the same input fails differently on a stock Mac). Three predicates disagreeing
about the grammar gave five distinct failures of one guard (link#250, 2026-09-01 —
four review rounds, each finding a defect inside the previous round's fix):

| input | what happens |
|---|---|
| `0` | GNU `seq 0 -1` empty → loop body never runs → hang |
| `abc` | `[ abc -lt 1 ]` **exits 2**; `if` reads that as false → falls through → hang |
| `08` | `$((08-1))` → "value too great for base" → hang |
| `010` | **silently** becomes 8; the banner reports 10 |
| `99999999999999999999` | `10#` wraps to 7766279631452241919 → passes `>= 1` → hang |

Fix by **normalising once**, not by adding a fourth predicate: shape check
(`case ''|*[!0-9]*`), then `x=$((10#$x))`, then a bounded range. Put it where every
caller meets it, not only on the CLI flag that happens to have its own validation.

The complete candidate set for a string consumed as a count is **shape / sign / value
/ base / magnitude**. Enumerate all five or the class recurs one axis over.

### `wait` with no argument waits for every background job in the shell

Not just the ones the function started. A pool that ends with a bare `wait` silently
couples itself to whatever else the caller has backgrounded, and hangs outright if any
of them is long-lived — with all its own work already finished and nothing on screen
to say so. A 2-second sampler loop in a benchmark script wedged a pool whose four jobs
had all completed (link#250).

Track the pids you spawn and wait on those:

```bash
recompute_one "$w" &
all_pids="$all_pids $!"
...
for pid in $all_pids; do wait "$pid" 2>/dev/null || true; done
```

### `timeout` is GNU coreutils — a portable deadline

An assertion around something that might hang can only pass or hang, never fail
(`code-check.md`, "Restore the bug and prove the guard fires"). The deadline that
makes it able to fail cannot be `timeout`: that is GNU coreutils and absent from a
stock macOS, so depending on it makes the assertion skip on the machine it was
written for. Portable:

```bash
with_deadline() {  # $1 = seconds, rest = command; returns 124 on deadline
  local secs="$1"; shift
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -9 "$cmd_pid" 2>/dev/null ) & local killer=$!
  local rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true; wait "$killer" 2>/dev/null || true
  [ "$rc" -ge 128 ] && return 124
  return "$rc"
}
```

Distinguish 124 from a real non-zero, or a hang gets reported as a refusal. Same
reasoning as `--max-time` on a fan-out `curl` above: fail loud rather than hang quiet.

### `aws s3 cp` cannot tell a missing key from a missing bucket

Measured 2026-08-31, aws-cli 2.34.34. Both cases return **exit 1** with identical text:

```
fatal error: An error occurred (404) when calling the HeadObject operation: Key "..." does not exist
```

So absence cannot be inferred from a transfer command. Any "the object isn't there
yet, so create it" branch built on `s3 cp` also fires on a typo'd bucket or prefix —
and then writes the "first" copy somewhere nobody will look for it.

Establish absence positively with two probes: `s3api head-bucket` (reachable? exit 0
vs 254) then `s3api head-object` (present? exit 0 vs 254). Only *reachable AND
missing* is a confirmed absence. `head-object` returns **403, not 404**, for a missing
key when the caller lacks `s3:ListBucket`, so 403 must not count as absence either —
or a permissions problem reads as a first run.

Related: match error tokens anchored — `\(PreconditionFailed\)`, `\(412\)`, `\(404\)`
— never a bare `412`/`404` substring, which matches any request id or byte count
containing those digits.

### A verification command can be shadowed by a shell function or alias
- The shell is initialized from the user's profile, so `diff`, `grep`, `ls`, `cat` and friends may resolve to a wrapper rather than the binary you assume. Measured 2026-08-24 in gq: `diff` was a shell **function** delegating to `git diff`, so `diff -q a b` — a byte-comparison in an idempotency check — died on ``unknown switch `q' `` and the step reported **NOT IDEMPOTENT** for two files that were in fact identical.
- That direction is survivable because it is loud. The dangerous one is a wrapper that exits 0 on a comparison it never performed, which reads as "verified".
- For anything whose output you are about to treat as evidence, bypass the lookup: `command diff`, `\diff`, or a tool with no common wrapper — `cmp -s` for byte-equality, `md5` / `sha256sum` for a value you can print. Printing the digest beats printing a verdict: it stays checkable after the fact.
- `type <cmd>` tells you what you actually have. Worth running the first time a verification step returns something surprising, before believing the surprise.

### psql does not interpolate `:'var'` inside a dollar-quoted string, and `\quit N` exits 0

Two traps in the same file type, both of which read perfectly and fail at run time.

**Interpolation.** psql substitutes its `-v` variables in the query buffer, but a
dollar-quoted body is a *string literal* to it, so nothing inside `$$ … $$` is
substituted. The natural form dies with a message that points at SQL syntax rather
than at the quoting layer:

```sql
DO $$ DECLARE v text := :'run_uid'; BEGIN ... END $$;
-- ERROR:  syntax error at or near ":"
```

Pass parameters through session settings instead, set outside the block:

```sql
SELECT set_config('app.run_uid', :'run_uid', false) \gset
DO $$ DECLARE v text := current_setting('app.run_uid'); BEGIN ... END $$;
```

**`\quit` takes no exit code.** `\quit 1` warns `extra argument "1" ignored` and
exits **0** (measured, psql 16.10 and 18.3). So a guard written as

```
\echo 'FATAL: …'
\quit 1
```

prints FATAL in red and then reports **success** — fail-toward-pass on precisely the
branch that exists to stop a silent zero-row pass. Raise instead, with
`\set ON_ERROR_STOP on` at the top of the file:

```sql
DO $$ BEGIN RAISE EXCEPTION 'no run_uid supplied'; END $$;
```

Related, same family: a `.sql` file whose checks are all bare `SELECT`s has no exit
status at all — a human reading output is the only verdict. If the script is invoked
by anything, at least one check must `RAISE`.

Caught 2026-09-01 in link#262, in a verify script whose own header advertised that it
"exits non-zero on a real failure".

### A second `trap … EXIT` replaces the first

`trap` registers **one** handler per signal. Registering cleanup for a temp file and
then cleanup for a database schema leaves only the second — the first is silently
discarded, and nothing warns.

```bash
trap 'rm -f "$TMP"' EXIT
trap 'drop_schema' EXIT        # the rm never runs again
```

One handler, both jobs:

```bash
cleanup() { rm -f "$TMP"; [ "$MADE" = 1 ] && drop_schema; }
trap cleanup EXIT
```

**Arm it before the thing it cleans up exists**, guarded by a flag. Registering the
trap *after* the resource is created leaves a window in which `set -euo pipefail` can
exit with no handler installed — and that window is exactly where a failure lands.

The two halves interact, which is how this survives review: adding `ON_ERROR_STOP` to
a psql call can turn a previously exit-0 setup step into an abort *inside* that
window, reopening a leak the early trap was added to close. Both changes individually
right; neither measured against the other. Caught 2026-09-01 in link#262.

### A `local` statement cannot read a variable it is assigning in the same statement

`local a="$1" lab="$2" m="/tmp/marker_${lab}"` expands `${lab}` **before** `lab` is
assigned. Under `set -u` that is a fatal `lab: unbound variable`; without it, the
variable is silently empty and whatever it was building points at the wrong path.

It reads as one tidy declaration, which is the whole trap — the same three
assignments on three lines are correct.

```bash
run_one () {
  local a="$1" lab="$2" m="/tmp/fp_${lab}"   # WRONG: ${lab} is empty here
  local a="$1"                                # right: one per line
  local lab="$2"
  local m="/tmp/fp_${lab}"
}
```

**And the wrapper reported exit 0.** Caught 2026-09-02 in floodplains: the function
aborted on its first call, the script died before its `ALL RUNS DONE` line, and the
background task notification still said *completed (exit code 0)*. The only signal was
one line in a redirected output file. This is "A wrapper's exit is not the work"
(`code-check.md`) meeting a `local` bug — gate on the in-band marker (`ALL RUNS DONE`), never on the wrapper.

Same shape for `declare`, `readonly`, and `export` with multiple assignments, and for
`local -r`. If two names on one line have a dependency between them, they belong on
two lines.

### Inside an `EnterWorktree` session, the Bash tool refuses command text that names git

The harness applies an isolation guard to a session that entered a worktree: *"a
worktree-isolated session's git operations must target its own worktree."* It decides by
scanning the **command text**, not by what the command would do. Measured 2026-09-02 on
soul#166, four refusals in one session:

| refused | why |
|---|---|
| `cd "$WT" && git … && …` | compound with `cd` |
| `git -C "$WT" archive … \| tar -x` | a pipe containing git |
| `git -C "$WT" add a b && git -C "$WT" commit …` | two git commands chained |
| `python3 - <<'PY' … "git worktree" … PY` | a heredoc whose *prose* contained the word |

The last one is the trap: a multi-file text edit whose replacement strings happen to
mention git is refused for the mention, and the error reads as a git problem.

What works: one plain command per call, absolute paths (the shell cwd resets between
calls, so relative paths resolve outside the worktree after the first), `git -C
<worktree-path> <verb>`, and `--output=<file>` in place of pipes — `git diff --output=…`,
`git archive --output=…`. For edits that mention git, **write the script to a file with the
Write tool and run `python3 <path>`**: the command text then names no git. Do not spend
turns on phrasings; it is a property of the harness, not a setting.

Three more shapes, measured 2026-09-03 on soul#168, and the second is the one that
costs something:

- A `for` loop whose body runs `gh` with a path built from a shell variable is refused
  too — *"runs gh with a value computed at runtime … cannot be shown not to be git"*.
  Spell each `gh` call out with literal absolute paths.
- **`gh pr merge` from inside a worktree merges, then errors** — `fatal: 'main' is
  already used by worktree at …` — because its post-merge `git checkout main` cannot
  run. The merge has landed and the error says nothing about it; `--delete-branch` has
  *not* deleted the remote branch. Same recovery as the half-succeeding `--delete-branch`
  under `gh` CLI above: read `gh pr view --json state,mergeCommit`, then `git ls-remote
  --heads origin <branch>`, and delete by hand after `merge-base --is-ancestor`.
- `ExitWorktree(remove)` refuses while the local default branch is behind origin,
  because it counts the just-merged commits as unmerged. Exit with `keep`, `git pull
  --ff-only` on main, then `git worktree remove <path>` and `git branch -d <branch>` —
  lowercase `-d`, so git itself checks the branch is merged.

### A `git filter-repo` seed carries the source repo's tags, and a path sed misses the language's path constructor

Two traps from seeding one repo out of another's history (fish_passage_template_reporting#236,
2026-09-02), both silent.

- **Tags survive the path filter** whenever the commit they point at does. The first
  `git push -u origin main` of the filtered clone pushed three of the source repo's release tags
  into the new repo, where they squat on the names its own first releases need — the stray-tag
  trap in the seeding direction. `git tag -l` on the filtered clone before pushing; delete what is
  not the new repo's own.
- **`sed 's#data/planning#data#'` rewrites the string form only.** Every
  `file.path("data", "planning", ...)` — eight sites in four scripts — survived, and the grep that
  followed the sed reported zero remaining hits because it searched for the same string. Nothing
  static found it; running one consumer did (it aborted writing to a directory that no longer
  existed). After any path repoint, grep the constructor form too (`"planning"` as a bare
  segment, `os.path.join`, `Path(...) /`), and run one script that writes.

### `git check-ignore -v` prints the matching pattern, and its exit status is not a per-file verdict

`-v` reports the **last matching pattern**, negations included. So a path un-ignored by a `!` rule
prints a line *and exits 0* — which reads as "still ignored" when the file is in fact tracked.

Measured 2026-09-04 in stac_floodplains_bc, adding `!data/readme_items.rds` under `data/*.rds`:

```
$ git check-ignore -v data/readme_items.rds
.gitignore:9:!data/readme_items.rds   data/readme_items.rds     # exit 0 — but NOT ignored
```

`planning.md`'s "expect no output" is right for a plainly-unignored path (nothing prints, exit 1);
it does not hold once a negation is involved. Test each path and branch on the status:

```bash
for f in a b c; do git check-ignore -q "$f" && echo "IGNORED $f" || echo "ok $f"; done
```

And **not-ignored is not tracked.** The predicate that matters for anything a reader will fetch is
`git ls-files --error-unmatch <path>` — see "A link to a repo-hosted artifact must be *tracked*"
in `code-check.md`.

### `sips -Z` scales up as well as down

`sips -Z N` resamples so the longest side is N — in **either** direction. Run over a mixed set to
"shrink images for the web", it enlarges everything already smaller than N, and the batch can come
back barely smaller than it started.

Measured 2026-09-04 over 104 images: `-Z 1400` took a 934x700 PNG **up** to 1400x1049, and the set
went 60 MB → 51 MB where the intent was a quarter of that. Guard on the source dimension:

```bash
mx=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{if($2>m)m=$2}END{print m+0}')
if [ "$mx" -gt 1200 ]; then sips -Z 1200 "$f" --out "$o"; else sips "$f" --out "$o"; fi
```

The tell is a resize pass whose total barely moves. `-resampleHeightWidthMax` behaves the same way;
ImageMagick's `convert -resize '1200x1200>'` is the form that only shrinks.

### Assert capabilities, not versions — a tool upgrade can remove one silently

A tool upgrade across the fleet can remove a capability without reporting failure.
Version numbers do not predict the loss, exit codes stay zero, and the break surfaces
later somewhere unrelated. Four instances on one host in one session (2026-08-20):

- **GDAL silently lost its Parquet driver.** `brew upgrade` moved `apache-arrow` out
  from under a compiled link in libgdal. `ogr2ogr --version` still answered; `Parquet`
  simply stopped appearing in `--formats`. Exit 0 throughout.
- **GDAL 3.13.3 turned a GeoPackage-extension warning into a hard error.** Identical
  source: 0 failures on 3.13.0, 10 on 3.13.3. Package CI was green, so the repository
  alone could not surface it (rfp#149).
- **A checkout sat 93 commits behind** while `git status` reported in-sync, because it
  had not fetched; a package installed from it was reported as "latest".
- **Uncommitted work sat 15 days on one machine**, staged and never committed,
  invisible to every other host.

Two of these were mis-reported in-session before being caught — including an A/B test
"proving" a regression whose comparison keg was itself broken (a missing dylib meant
`ogr2ogr` never ran, producing a coincidentally identical failure count). The common
shape is real state with no signal.

- **Probe the operation, not the version.** `ogr2ogr --version` says nothing about
  whether Parquet works; `ogr2ogr -f Parquet` round-tripping two features does. Every
  check that matters performs the thing the fleet depends on: Parquet write and
  read-back with field types preserved, the PostgreSQL vector driver present, COG
  creation, `mergin push` incrementing the server version, a package's exported
  functions callable, QGIS at or above what the report templates target.
- **Probe, upgrade, re-probe, diff.** Never a bare `brew upgrade` (or `pak::pak`, or
  `uv tool upgrade`) on a working host. A capability that flips pass→fail becomes a
  loud failure with a named rollback instead of a silent one. Same reasoning as "A
  wrapper's exit is not the work" in `code-check.md` — a package manager is another
  wrapper that reports success while the work did not survive.
- **Declare what a repo needs.** Repos that shell out to external tools state the set
  (GDAL with COG support, `aws`, `jq`, `python3` for the STAC repos) so "can this host
  run this?" is answerable before a long job starts rather than halfway through.
- The probe also flags checkouts behind origin and uncommitted work older than N days —
  neither is visible from any single machine's routine output.

The honest failure mode is that this rots because nobody runs it: run the probe at
session start beside the CI scan, schedule it unattended, and commit the results per
host so any machine can see what the others measured. Implementation is kdot#37 (soul#69).


# Code Check Conventions

Structured checklist for reviewing diffs before commit. Used by `/code-check`.

This file holds the **mechanisms** — the shapes that keep producing bugs regardless of
language — and a short set of standalone rules. Tool-specific traps live beside it,
each gated on the repo's contents: `code-check-shell.md` (bash, sed, git, `gh`; always),
`code-check-r.md` (package internals; `NAMESPACE`), `code-check-spatial.md` (terra, sf,
bcdata, GDAL; bookdown, `DESCRIPTION` or QGIS repos), `code-check-infra.md` (provisioning;
`*.tf`, cloud-init, compose).

When a bug class is discovered, add a **row** under the mechanism it instances. Add a
new mechanism only when no row fits. Add to a tool file only when the rule is about
that tool rather than about a shape.

## Mechanisms

Thirteen shapes that keep producing bugs. Each is stated once; the table under it is
the evidence — every instance dated, with where it was caught and what it cost. The
rule is the thing to check a diff against. The rows are why the rule is trusted.

When a new instance turns up, add a row. Add a new mechanism only when no row fits,
which is rare: the previous version of this file carried 31 lines cross-referencing
another entry — "same family as", "sibling of", "mirror of", "refines" — and every
one was right.

### A guard that fails toward pass

A check decides whether to do something consequential — cut a tag, run a migration,
report a sweep clean. Work out which way it fails when the command *inside* it errors.
If the error path and the "nothing to do" path look the same, the guard is
indistinguishable from a working one right up until it silently eats the action.

The usual shapes: `IF=$(cmd)` tested with `[ -z "$IF" ]`, where an aborted `cmd` reads
as "nothing changed"; a loop over a computed list, where an empty list runs zero times
and exits 0; a `cmd | grep pattern` whose exit is grep's; a search whose regex the
local tool does not support, returning empty like an honest no-match; a `case`
allowlist that matches substrings. The mirror mistake is a guard that fails toward
**abort** on an operation where partial failure is certain — `exit 1 if errors` over
98k requests throws away completed work on a 0.002% transient rate.

**Assign first, test the exit status, then test the value. Branch on empty explicitly.
Test the guard against both known answers before shipping it** — one case that must
fire and one that must not. A guard nobody has seen fail is decoration.

| date | where | instance |
|---|---|---|
| 2026-08-12 | soul gh-pr-merge | **A guard must not fail toward "skip"** — `IF=$(git diff …)` aborted, empty read as "nothing shipped", five commits of real package changes classified as needing no release |
| 2026-08-26 | gq#56 | **An empty result set is not a pass — a loop over nothing exits 0** — GitHub never dispatched the PR's workflows; the watch loop iterated zero runs and reported all green; poll for the runs to exist, then branch on empty explicitly — and branch on the reported `conclusion` (`success\|cancelled\|skipped\|""`) rather than `--exit-status`, which reported a run r-lib's `cancel-in-progress` legitimately cancelled as a failure (2026-08-26) |
| 2026-08-29 | stac_dem_bc | **A guard must not fail toward "abort" either** — 98,040 items, 2 transient failures, exit non-zero skipped the publish and the manifest recording 98,038 successes was never committed; retry in-process before an error can reach the exit code, gate on a rate against a stated tolerance tested against both answers, persist progress on the failure path (`if: always()` in CI), and ask which direction the failure costs more |
| 2026-08-29 | rfp | **A grep that cannot show a failure is not a check** — `cmd \| grep -E "added"` matched the line printed one statement before `Error: could not find function`; the work was then finished by hand, hiding that the driver had not |
| 2026-08-31 | link | **A search that finds nothing has proven nothing until it has found something** — `\b` unsupported on macOS grep; an IP-address audit returned empty and was written into an issue as "no IPs in any tracked file" |
| 2026-09-01 | trap#18 | **A guard nothing corroborates has to count, not match** — `all(grepl(ok, v))` is TRUE for an empty `v`; the xpath needed `xml_ns_strip()` and without it found 0 of 600; only a count turned the tests red |
| 2026-08-31 | link | **A guard placed mid-operation can be defeated by the operation itself** — a clean-tree precondition placed after the run writes its own logs; fired on every real run, for a reason unrelated to what it guarded |
| 2026-08-31 | link | **A job that writes into its own tracked output directory poisons every dirty-check** — a provenance `dirty` flag set on all 21 dispatcher rows, every one false; the flag then carries no information and readers ignore the column; match the predicate to the subject — `git status --porcelain --untracked-files=no -- . ':(exclude)path/to/logs'`, long-form exclude because an aborted status reads as clean, `--untracked-files=no` decided deliberately since it also hides a new source file — and read provenance back against independently measured ground truth |
| 2026-08-31 | fly#42 | **A `case` allowlist matches a substring, not a token** — `case " $allowed " in *" $item "*)` passes an item whose name spans two entries; use an explicit equality loop (`for a in $allowed; do [ "$a" = "$1" ] && return 0; done`), and strip only the suffix that actually matched — `${b%.html}` then `${b%.md}` reduces `index.md.html` to `index` |
| 2026-08 | cyclops#10 | **`cmd > file` truncates before `cmd` runs — a failed command leaves a poisoned empty file** — a timed-out `op read` would have left a zero-byte credential that `[ -f ]` then blessed forever; guard on `-s`, write atomically |
| 2026-09-04 | stewardship_upper_wedzin_kwa | **A run that selects nothing must not overwrite the artifact a run that selected something produced** — a `--since` filter excluded every visit, the fetch loop iterated zero times, and the resulting empty frame was written over a 238-row manifest that had cost 238 live HTTP requests; the run reported success because nothing failed. Merge rather than replace, and skip the write entirely when the new set is empty |
| 2026-09-03 | rtj#259/#260 | **A completion check that enumerates the known-bad states passes for a state nobody enumerated** — a driver's post-condition filtered for its own four actionable outcomes, a copy of the todo filter written twice. A fifth outcome was later added (a form blocked from its rebuild) and landed in neither list, so a run that left the form stale printed `Done.` with the push command under it, on a project with no rollback. Its sibling path returned `Nothing to do.` and exited 0 *before* the check ran. **Invert to the complement**: assert every row is a deliberate resting place — `ok`, or one of the two report reasons that are deliberately final — so an outcome nobody has thought of defaults to **stop** rather than to pass. That does not prevent the next drift; it makes the next drift loud. Three review rounds had each fixed an instance of the same class; the complement is what stopped it being re-fixed |
| 2026-09-03 | stac_floodplains_bc#46 | **`if not parsed: continue` turns "I could not read it" into "it is fine"** — a style validator skipped every content check when its category parse came back empty, so a `nullSymbol` renderer (a real one that draws nothing) and a `singleSymbol` one both sailed through; every classified layer in every item could have shipped drawing nothing, green. An empty parse is a THIRD state beside pass and fail — name the expected shape and assert it, rather than treating unreadable as exempt. **And check which direction the mirror runs**: the same review found the paired defect, a guard asserting a *data* property ("this watershed lost trees") where it meant an *artifact* property ("this style draws what it categorizes"), which would have refused a correct release on a correct dataset — measured margin 3 across 48 layers. Ask of every assertion whether it is about the thing you built or about the data that happened to flow through it |
| 2026-09-04 | rtj#265 | **A coercion that truncates rather than refusing defeats a guard watching for NA** — `as.integer()` does not reject a fractional value, it silently truncates: measured `"2.5"`→`2`, `"0.9"`→`0`, `"-3.7"`→`-3`, no warning and no `NA`. A cast guard written as "report the values that became `NA`" therefore fires on `""` and `"5+"` (benign, or at least loud) and misses **every** instance of the thing it exists for — a column that is not an integer at all. `"0.9"`→`0` is the sharp case: a real measurement becomes zero with nothing said. Compare against `round()` with a tolerance instead of watching for `NA`, and split the two failures by what they cost — a parseable-but-fractional value should **abort** (truncation corrupts a real value; there is no correct silent behaviour), while unparseable→`NA` warns by value with empties separated out. Verify by restoring the old guard and running both over the same inputs: they should catch **disjoint** sets, which is what proves it is a gap closed rather than one guard swapped for another |
| 2026-09-04 | rtj#265 | **A rule stated in a comment is not an enforced rule, and the safe-looking default is usually the dangerous value** — a driver's header said `--themes` must NEVER be `"all"`, citing the incident that produced the rule, while the call site read `themes %||% "all"` and a dry run reported the plan and passed. Three artifacts disagreed — header, PR description, code — and the dry run printed the dangerous value as if it were information. Where a comment says "never X", grep the file for X before believing it; where a default exists because a value is required, make omission an **error** rather than a fallback, and put that check ahead of any dry-run return so a plan-only run refuses rather than reporting a plan it would not have been safe to run. Both this and the row above were found by a PR reviewer on a check reporting green — the review's *conclusion* was SUCCESS both times, and the finding was in the comment body |
| 2026-09-03 | link#278 | **A driver default that selects a methodology, a data scope or a deployment target answers a question nobody asked** — distinct from an ordinary default: `verbose = FALSE` is a preference, `config = "bcfishpass"` picks which of two biological methodologies you shipped, and the tell is that the alternative would also have run cleanly and produced different, equally plausible numbers. Fifteen drivers in one package defaulted to a parity config while the operator expected the package's own, so six watershed groups were modelled on the wrong methodology into a product line already seventeen deep, caught by an offhand question afterwards. Worse when the default is *named* like the safe one (`bcfishpass` vs a config literally called `default`). The remedy is not a policy fixing each answer; it is **removing defaults that silently answer for you**: make the argument required, and where a default must stay, print the resolved decision at start-up with the alternative named. Review question for any driver diff: does this fallback choose a method, a scope or a target? A fleet sweep of the shape is soul#178 |
| 2026-09-04 | floodplains#77 | **Widening a guard is how it starts refusing correct content, and case-insensitivity is the cheapest way in** — a catalogue-fact grep was widened after missing 5 of 12 restatements, and the new latitude pattern `\b\d{1,3}\.\d+\s*[NS]\b` ran under `re.IGNORECASE`, so `[NS]` also matched a lowercase **s**: `0.39 s`, a timing figure from the repo's own notes, was refused as a collection extent. Compile flags **per pattern**, not per sweep. Two habits that caught it: keep a **negative control set** of sentences the repo legitimately writes and assert they still pass, and check *what the guard reads* — this was the one arm of three not stripping `<script>`, so an embedded bootstrap payload with 30 CSS durations (`.15s`) sat one leading digit from failing a page that was fine |
| 2026-09-05 | stac_floodplains_bc#61 | **A currency gate read from the artifact the assertion pins downgrades FAIL to SKIP** — a byte-identity assertion pinned a built `meta.json`'s digest and gated itself on that same file's `produced_datetime`, so it would skip whenever upstream had re-run. Any regression that moved or nulled that field — a broken provenance read, a lost section, a rename — therefore made the gate skip **under a message blaming upstream**, on the one arm that exists to notice the code moving the artifact. Read a currency gate from the independent source it is really about (the producer's own file), never from the subject. A pin needs one gate per **independent input** to the digest, too: the same assertion's second gate covers the local sf/GDAL/PROJ triple, because the areas and geometry inside that file are computed on the machine that runs it, and an ungated toolchain difference FAILS rather than skipping |
| — | — | **Silent Failures** — `\|\| true` hides real errors; an empty variable before `rm`/`destroy` needs `[ -n "$VAR" ] \|\| exit 1`; `grep` returning empty feeds downstream silently |

### A fixture that cannot reach the failure mode

Hand-picked fixtures test the cases you thought of. If every one is structurally
incapable of triggering the bug class you are fixing, a green run means nothing — and
it is more dangerous than no test, because it licenses the word "validated". A fixture
that matches the code's happy path leaves whole branches not merely untested but
never executed: one raster in the data's CRS makes every reprojection an identity.

Before declaring a fix verified, ask what the fixtures have in common and whether that
shared property is the very thing the bug depends on. Vary the fixture along exactly
the axes it cannot reach. Prefer a global structural invariant — antisymmetry,
conservation, every node reaches a terminal — over more examples, because an invariant
cannot be gamed by fixture choice. And check a threshold against the **least
favourable** member of the population, computed, not the vivid one you remember.

| date | where | instance |
|---|---|---|
| 2026-08 | link#227 / fresh#214 | **A fixture set that cannot reach the failure mode is not validation** — 8 hydrology fixtures all compared groups with *differing* stream codes; the bug fires only between groups sharing one; the next case tried dropped the group the whole Fraser drains through |
| 2026-08 | rfp#139 | **A negative-case fixture rots when the positive set grows** — a refusal test picked EPSG:4326 because nothing supplied it; shipping an `<srs>` for a tracking layer made it resolvable and the test failed blaming the code; assert the premise beside the property |
| 2026-08-27 | flooded#40 | **A comparison test proves nothing if the fixture makes both sides identical** — grouping by `gnis_name` vs `blue_line_key` was a bijection in the test data, so the two runs were the same run with different labels |
| — | water-temp-bc#23 | **Test fixtures must mirror production column TYPES, not just shapes** — fixtures had `Grade` as string, production has double; a `coalesce(Grade, '')` sentinel passed 27 tests and broke on first contact |
| 2026-09-01 | stac_floodplains_bc#23 | **A cross-item consistency check cannot see a defect that hits every item** — a uniform-key validator measures variance; keying a new asset by a stem that was already a key would have overwritten a raster in every item and every check would pass; pair with one absolute assertion |
| 2026-09-01 | stac_floodplains_bc#34/#35 | **Declaring a schema extension is not evidence the field is populated** — the STAC classification extension's Item branch validates `classification:classes` without requiring it, so an item declaring the extension with the field on zero assets passes `pystac.Item.validate()` clean, and a loss that uniform is invisible to the cross-item check above as well; read the schema's own `required`/`anyOf` for the branch you actually validate (Item, Collection and Asset differ) rather than assuming the extension's purpose is enforced, and where the field is optional write the absolute assertion — a hardcoded count or key set, because one derived from the artifact goes empty alongside it |
| 2026-08-31 | floodplains | **A per-tenant key looks global whenever your test data has one tenant** — `patch_id` numbered within sub-basin; five areas had one sub-basin each, so it was observably unique; the only 13-sub-basin area had 2032 rows and 1973 distinct ids, a 6% mis-apportionment; ask what the id is unique *within* and prefer the composite (`patch_id`, `name_basin`) even where today's data makes the extra column redundant |
| 2026-08-30 | fly#38 | **Check a threshold against the least favourable case, computed — not a remembered example** — tolerance set to 1.10 against a remembered 0.442; the binding case was 0.0949, `log(1.10)` is 0.0953, 0.4% too loose, and it let through the one input it existed to catch |
| 2026-08 | rfp#168 | **Mocking the transport means the request is never built** — `local_mocked_bindings(.do_http=)` gives full coverage of response handling and none of the request; the wrong content type returned 400 on every Overpass endpoint with 130 tests green; make the wire format a pure function and assert it offline |
| 2026-09-02 | floodplains#64 | **A fixture that varies the artifact but not the reader tests nothing reader-dependent** — two GeoTIFFs with different containers, both read with the same terra in the same process, digests asserted equal; delete both normalization lines and all nine assertions still passed, because storage type only varies with what the *reader* does, and the real trigger was a `.aux.xml` sidecar beside one file that the fixture had no reason to model; closed by asserting the property on plain vectors with no file I/O — name the axis the guard exists to test, then check the fixture actually varies it |

### A proxy is not the property

A condition that stands in for the thing you actually want. It fixes the case in front
of you and leaves every other state with the same property wide open, because a proxy
is correlated with the property and a guard needs equivalence. The tell is a condition
naming a **mechanism** — "has no row in table X", "elapsed over 2 minutes", "block
size is 128" — where the requirement is a **capability** — "can be resolved", "is
well-supported", "costs N requests". Ask what property you were testing for, and
whether the condition is equivalent to it or merely adjacent.

Proxies compress (a 14,950x allocation difference showed as 5x in wall-clock, inside
CI jitter), and they can be **inverted** — a long GPS gap meant the subject stood
still, which is when interpolation is most accurate, so the time gate rejected the
best fixes. Assert the quantity that actually differs. Where the property is internal,
name it and observe it. Measure the sign of a correlation before trusting it.

| date | where | instance |
|---|---|---|
| 2026-08-29 | fly#9 | **A proxy assertion does not guard the thing it stands for** — elapsed time as a stand-in for cell count; 243M vs 16k cells showed as 1.0 s vs 0.18 s; the guard written for the defect passed on it |
| 2026-08-29 | rfp#218 | **A guard that encodes the cause you measured is a proxy for the property you want** — "has no `gpkg_spatial_ref_sys` row" stood in for "`st_crs()` can resolve it"; a row that exists and resolves to nothing passed; four review rounds, three failure arms, one guard each |
| 2026-09-01 | trap#25 | **A proxy can be inverted, not merely imprecise** — elapsed time to the nearer vertex as an error bound; the logger emits on movement, so long gaps are stillness; Spearman −0.154; 15 of 16 long gaps had the subject move ≤18 m and the gate rejected all 16 |
| 2026-08-31 | — | **A structural property is not a performance measurement** — 128×128 blocks vs 512×512 read as "16x the range requests"; `CPL_CURL_VERBOSE` counted 14 against 14; the block cache absorbs it |
| 2026-09-01 | drift#47 | **A structural prediction can point the opposite way from reality** — `gdalcubes::filter_geom()` at 64 px chunks skips 26.7% of the ground, so the read should get cheaper; over the wire it made 693 requests against 462 and took 47% longer, because the COGs are `Block=512x512` and a sub-block chunk refetches the same source block per chunk; "A structural property is not a performance measurement" compresses, this one reverses; the tell is a prediction that counts one thing while the bill is itemised in another — measure in the unit you are billed in |
| 2026-08-30 | fly#32 | **Do not branch on a value only some code paths populate** — `sized <- !is.na(half_side)` is a property of which route ran first; three conditions in one function each broke on the same `NA`-by-construction fact; batch-dependence is the confirming symptom; the remedy is distinct from the proxy's — derive the predicate from inputs known before any route runs, not a truer measurement |
| 2026-08-31 | gq#76 | **A premise check satisfied by the happy path's own structure is decoration** — `any(dir.exists(paths))` is TRUE whether or not the sweep recursed, because top-level dirs are always present; restore the defect and watch the premise fail |
| 2026-09-01 | link#250 | **Asserting a proxy instead of the property passes on the defect** — a pool's width asserted through its job count; 3 jobs at width 8 and at width 10 both write 3 result files and exit 0, so the assertion passed against an octal bug that halved the width — the proxy was blind to it, not merely compressing it; derive the property exactly: each job appends `+` on start and `-` on end (single small appends, atomic under `O_APPEND`), then `awk '$0=="+"{n++; if(n>m)m=n} $0=="-"{n--} END{print m+0}' events` is the width actually used, and with the bug restored it reports `ran 8-wide, expected 10`; ask whether your assertion could tell the property from a neighbouring value — if two widths produce identical observations, it is about something else |

### Verification that reads its own output

A check whose reference was produced by the thing it checks cannot disagree with it.
Hash-on-write proves nothing changed *since you hashed*; a reference generated by
feeding your artifact to the consumer is your artifact with a blessing; a round-trip
through your own reader validates only self-consistency; a verifier on the writer's
library shares every blind spot the library has; a probe that reads back the value it
was handed is a round-trip through your own assignment. Every one returns identical,
forever.

Measure at the furthest downstream point you can reach — the rendered primitive, the
bytes on the wire, the row as the consumer's own client reads it. Ground truth is the
**consumer's own output**, constructed from inputs that are not your artifact. Diff
the bytes at the boundaries, not just the parsed structure. And for every field you
write that your own code never reads back, name what does read it.

| date | where | instance |
|---|---|---|
| 2026-09-01 | stac_floodplains_bc#23 | **A checksum you compute yourself cannot detect corruption that predates it** — two unchecked `file.copy()` calls fed straight into checksum computation; a truncated copy would have published bytes plus a checksum confirming them; `file.copy()` signals failure by returning `FALSE`, not by erroring, so `stopifnot(file.copy(…))` |
| 2026-08-30 | rfp#227 | **A reference generated by feeding your artifact to the consumer is circular** — `loadNamedStyle(ours); saveNamedStyle(ref)` hands back your file; build the reference from the consumer's API instead |
| 2026-08 | rfp#17 | **A round-trip through your own reader proves nothing about interop** — `layer_styles` rows with `f_table_schema` NULL round-tripped through DBI; QGIS matches with `= ''` and NULL never equals, so every style was invisible and nothing logged; the same reader on both sides of a *fixture* is the floodplains#64 row under "A fixture that cannot reach the failure mode" |
| 2026-08-27 | rfp | **A verifier built on the writer's own library shares its blind spot** — ElementTree drops `<!DOCTYPE>` on write and does not need it to parse; the structural compare reported IDENTICAL |
| 2026-09-01 | stac_floodplains_bc#34/#35 | **A well-formed file the consumer ignores is worse than a malformed one** — GDAL's PAM parser silently ignores a `.aux.xml` sidecar carrying an `<?xml …?>` declaration: 0 RAT rows read, 2 with the declaration removed, bytes otherwise identical; Python's `ElementTree.write()` emits it for `xml_declaration=True` or, with the default `None`, for any encoding spelled other than `utf-8`/`us-ascii` — `encoding="utf8"` writes one, `"utf-8"` does not (measured, CPython 3.14) — so the writer's spelling of a string decides whether the consumer reads anything; a full run with the declaration on published COGs with no class labels at all, every gate green; pass `xml_declaration=False` explicitly; the third of this family — the round-trip row is your own reader, the verifier row is the writer's library, this is the production reader rejecting silently; put the guard on the consumer having read the file, not on the write having succeeded, round-trip through the real consumer once, and suspect the serializer's defaults — it fails toward *absent*, which reads as "nothing to find" |
| 2026-08-26 | gq#16 | **Measure the output, not the input you handed in** — `pointsGrob$size` read back gave 5.08 mm, the value tmap was handed; the engine draws 3.81 mm; every symbol shipped 25% undersized while documented as exact; 0.2 inch exactly was the tell |
| 2026-08-26 | rfp#186 | **A value nothing reads is wrong silently — get it from the consumer, not from reasoning** — QGIS `<alias index=>` off by one because OGR excludes the integer primary key too; QGIS resolves by name so nothing broke; settled by comparing 99/99 against aliases QGIS itself wrote |
| 2026-09-02 | floodplains#65 | **A guard suite that validates shape can be complete and still never read a value** — eight published values mutated one at a time, PASS on all eight; one had shipped 42x wrong; re-derive each value from the artefact it names |
| 2026-09-01 | stac_floodplains_bc#33 | **A check's detect step and its explain step must use the same predicate** — exact compare to detect, tolerant compare to explain; `'-738.20'` vs `-738.2` entered the block and produced an empty message |
| 2026-09-05 | floodplains#79 | **A cache keyed on fewer inputs than the comparison varies makes an A/B assert a file equals itself** — the plan was to prove a widened request left the shared results unchanged by running it both ways and diffing. `drift`'s `stac_cache_key()` hashes the AOI and request parameters but **not `years`**, and cache files are `<year>_<key>.nc` — so the narrow run's outputs are re-read off disk by the wide one, byte-for-byte, and the assertion is green against any regression whatever. The sibling half is worse because it looks like evidence: the upstream query range was `min(years)..max(years)`, identical for both, so the two runs issued *the same request* and a committed log already showed 14 items returned for a 3-year ask. **Before building an A/B, name the input you are varying and check it reaches the cache key and the wire request** — if it reaches neither, the comparison is a tautology and the honest move is to say the property holds by construction. Distinct from the under-keyed-cache row under "Written data outlives the fix": there the wrong data ships, here the *check* cannot fail |

### A guard's scope, escape hatches, and remedies

Every guard grows the things that silently disable it. An **exemption list** that
covers every input makes the assertion unreachable — and reads as more careful than
the correct version because it is longer. A **lookup** that matches a container rather
than the artifact checks a stranger's copy. A **literal set** used as a filter covers
whatever the data happens to contain today and grows blind as it grows. A guard that
compares against a **vendored witness** is pinned to the copy, not the world. A guard
that reads a **coarser grain** than its property passes on the grain. A **remedy** in
the error message is code the caller will run, and nothing checks it.

Read the escape hatches before the assertion. Enumerate the inputs programmatically
and diff against the declared set. Require a reason on every exemption — one whose
reason says the rule *is* satisfied is an entry to delete. Pin scope against its
source of truth. For every literal a guard rests on, ask whether it is a **contract this
repo chose** — hardcode it, because a derived expectation cannot fire — or a **fact about
a third party's behaviour** — read it from the artifact, because a value reasoned from how
a producer behaves is where the accidental scope comes from. Terminate by enumeration,
not by a reviewer saying you have converged: the class recurs one axis over, and three
"this is now terminal" claims were wrong on one PR.

| date | where | instance |
|---|---|---|
| 2026-08-28 | gq#66 | **A drift guard must cover every input it claims to** — walking all sources then comparing against their *union* passes for an item present in one and absent from another; the tell is a lookup whose key omits the source |
| 2026-08-30 | gq#77 | **A guard's scope is usually a coincidence, and it will not announce itself** — `opaque <- c("esri_world_topo")` pinned to nothing; five instances across four review rounds, two of which would have shipped an opaque satellite raster over every field map |
| 2026-09-04 | stac_floodplains_bc#26 | **A guard written against the whole artifact silently redefines every mode that passes it a subset** — new per-item checks also asserted whole-catalogue set membership, so a documented single-item republish path (`--only`) began refusing every item but the two the set named. Nothing announced it: the release harness shims the validator away, so its own suite could not see it. The line is not "set compare vs the rest" but whether an arm names an id the subset **contains** — six of seven did. Three review rounds each got that partition wrong in one direction, including one that fixed it for an arm and not its mirror; write the partition down beside the guard, because it is what the next person will get wrong |
| 2026-08-30 | gq | **A guard that compares against a vendored copy cannot see the copy go stale** — two of three vendored artifacts had silently drifted; the exemption test compared against `template_groups.csv` rather than the templates, so the issue saying "the suite is red" was itself stale; two remedies, not alternatives — a currency check gated on the source being present (`skip()` in CI, said out loud), and a date or upstream version stamped beside the witness |
| 2026-08-26 | gq#61 | **A guard's escape hatches are where it goes to die — read them first** — a `legend_exempt` list naming all nine drawn layers with reason "drawn and legended"; a `dir.exists("vignettes")` lookup that walked out of the package under `R CMD check` |
| 2026-09-04 | floodplains#73/stac_floodplains_bc#26 | **Comparing a published artifact against its local source cannot tell "already current" from "never regenerated"** — sweeping 20 published STAC items for staleness by diffing each one's published area against the upstream file, two items matched exactly and were labelled *already corrected*. They were the two that had **never been re-run**, so both sides were the same stale July output — the equality was the defect, not the absence of one. The discriminator is regeneration status (here, does `provenance.json` exist), never equality: a comparison whose two sides can share one source is blind exactly where nothing was updated. Byte comparison does not rescue it either — GeoPackages rewritten layer-by-layer differed by one 4096-byte SQLite page with identical content, so checksums answered "same build?" when the question was "same content?"; only a content measure (area) separated the cases, and a 2% tolerance on it then mislabelled a genuinely stale item at 1.5% |
| 2026-09-02 | stac_floodplains_bc#19/#40/#32 | **A guard that reads a copy of its subject, or a coarser grain of it, passes on the copy** — `NEWS.md` on disk vs `git show "$tag:NEWS.md"`; `git describe` picking a note tag; file mtime vs the section's own timestamp; three grains before the property was per-key |
| 2026-09-01 | stac_floodplains_bc#22 | **A new feature can silently invalidate an unrelated flag's stated rationale** — `--skip-sync` justified as "every href resolves"; adding `file:checksum` made that insufficient; grep the bypasses when you add a guarantee |
| 2026-09-02 | ngr#7/#36 | **A fix that reaches one enforcement surface reads as complete on all of them** — five in one issue, each correct in its own dimension and silent in an adjacent one: `^CLAUDE\.md$` in `.Rbuildignore` while pkgdown published `CLAUDE.html` to the public web; a publish gate tested against both answers except under `nullglob`, where the loop runs zero times over an empty site; a CI flag sparing five runners a live API while `R CMD check` then failed on the same vignettes; one property enforced by mechanisms that do not read each other's config, and the fix is *evidence to everyone afterwards that it was handled*; name every mechanism enforcing the property, verify against the artifact each one produces with a positive control, and when two requirements conflict outright find the third option — the R surfaces and their remedies are under `R CMD build` in `code-check-r.md` |
| 2026-09-01 | stac_floodplains_bc#34/#35 | **A literal reasoned from a producer's behaviour, when the artifact answers directly** — three review rounds on one guard, each fix resting on a new reasoned premise: `OVERVIEW_LEVEL=0` selects an overview (GDAL only *warns* on an unknown open option, so a typo opens full resolution and the guard compared a band to itself); width is the dimension that shrinks (a 1×1024 raster's first overview is 1×512, so a 400×4000 raster with overviews stripped returned CLEAN); 512 is the driver's threshold (it is the *default* `BLOCKSIZE`, which the writing script may override, and a correct 600×600 COG at `BLOCKSIZE=1024` blocked the release); the same file already parsed the TIFF tag by hand rather than asking GDAL, and that discipline was not applied to the premises; enumerated, the file's literals were contracts (row counts, property sets), format constants (multihash prefix, tag number) and one third-party default — read that one from `ds.block_shapes`, which has no level above it to be derived from |
| 2026-09-04 | floodplains#77 | **A guard and the ignore rule that blinds it can land in the same commit** — a render check asserted `git status --porcelain` gained nothing, to catch a chunk that plots inline and leaves `README_files/` behind. `.gitignore` listed that exact path five lines away, added by the same change, so porcelain reported **OK** with the directory sitting on disk. Check a named-artifact property **by name**, and pair it with `--ignored` as the complement for whatever nobody thought to name — measured, the two arms catch different things: shortening the name list left arm 2 green while `--ignored` still failed. The escape hatch here was not inherited; it was written by the same author, in the same hour, for a good reason |
| 2026-09-01 | fly#37 | **A guard's error message must not recommend a remedy that walks back through it** — the guard refused non-POINT and suggested `st_cast(x, "POINT")`, which reproduces the original 20→100 row bug; run the remedy for every input a clause can receive |
| 2026-09-01 | stac_dem_bc#34 | **A guard that fires correctly and then points at the wrong fix** — four on one branch: an id-mismatch guard telling the operator to repoint `STAC_BUCKET_URL` at a bucket they already had (the bucket had not moved, only the collection); a deterministic both-keys failure reported as "transient, RE-RUN" when every re-run raises the identical error; a message promising "the run still publishes what it completed" on the path where the exit code discards it. Ask what someone would *do* on reading it, not whether the guard fired |
| 2026-09-05 | stac_floodplains_bc#61 | **A guard that says "this would reach X" must read X's own exclusions, not enumerate the source** — a new arm compared each published item's whole directory against its assets and reported every extra file as one that "would reach the public bucket". The release syncs with `--exclude '.*' --exclude '*/.*' --exclude '*.json' --exclude '*.aux.xml'`, and its own comment records why: macOS drops `.DS_Store` into item directories and GDAL writes PAM sidecars when a read triggers statistics. So the guard would have **refused a release** over a file that provably cannot ship — opening the folder in Finder was enough — while telling the operator to delete something the transport already ignores. The fix is not a hardcoded skip-list but reading the patterns out of the shipper (here `catalogue_release.sh`), the same way a timestamp pin is read from the one file that defines it: a second copy is one fact derived twice and the two part company at the first edit. Assert the parse rather than trusting it — an empty pattern set fails toward refusal (loud), but one containing a bare `*` blesses everything, so reject that by name. **And check what already covers the thing you just sanctioned**: a `.aux.xml` here is still refused, by the guard that names the real defect (the RAT is not embedded) rather than claiming a bucket leak |
| 2026-09-01 | flooded#47 | **Deriving a guard's key is not the fix for hardcoding it — when the key is a judgement, deriving it inverts the guard** — the contract-vs-third-party sentence above, read as "never hardcode", produces the opposite defect, and the wrong version looks careful. A **set** (which layers exist, which columns a schema declares) has a source of truth to derive from; a **judgement** (which column means drainage area, which basemap is opaque) has none, and keying it to whatever a formal or default holds today couples the guard to a value free to move for unrelated reasons. A guard keyed to `formals(fl_stream_rasterize)$field` — commented *"derived from the formal rather than hardcoded, so the two cannot drift"* — inverted completely when only that formal was corrected: false alarm on the right input, silence on the actual defect, a self-contradicting message. The two that must not drift are the guard and *the wrong column*, so key it to the literal `"channel_width"`. And the test does not save you — its premise line reddens, but reads as "the default changed, update the expected name", and that repair leaves the suite green with the guard pointing the wrong way: a failure toward the **wrong fix**, not toward pass (soul PR #136) |

### A fix lands in one of two callers that share a harness

Two entry points over one library, two workflows over one action, two scripts sourcing
one shell lib. A defect found through one caller gets fixed there, and the sibling
keeps it — silently, because the shared code is fine and nothing compares the callers
to each other. The count is the signal, not the instance: if you have fixed the same
class twice in one of a pair, the pair is the bug.

Fix in the harness where the behaviour belongs to it. Where it genuinely belongs to a
caller, grep the sibling in the same commit, and assert the shared policy is the one
both use rather than trusting an import to have been wired up.

| date | where | instance |
|---|---|---|
| 2026-08-31 / 09-01 | stac_dem_bc#34 | **Five gaps between `item_migrate` and `item_backfill` over one extraction** — `--limit 0` read as "no limit"; a missing clobber guard; no completeness statement at all; a dry-run ordering fix; `get("assets", {})` returning `None` on an explicit null. Two were found by reviewers *after* the third, which is what made the pair rather than the instances the thing to fix. A test asserting `item_backfill.error_tolerable is _tolerable` is what stops the policy silently forking again |

### Restore the bug and prove the guard fires

A test that stays green against the code it was written to reject is decoration, and
reading it will not tell you. Put the defect back, run the test, watch it go red. Pull
the exact prior bytes from git — a hand-rewritten "previous version" is a different
program, more likely to fail than the real defect was, so a green reconstruction proves
nothing and a red one proves almost nothing. And print a value that proves the patch
took: in R, `load_all()` creates two bindings, and patching only `asNamespace()` leaves
test code calling the original. Then run the file with `testthat::test_file()` —
`test_local()` and `devtools::test()` reload the package and discard the patch.

| date | where | instance |
|---|---|---|
| 2026-08 | gq#52; flooded#41; fly#9 | **Restore the bug and confirm the test fails** — three tests in one PR whose input could not reach the assertion; a patched namespace giving a false green until `package:` was patched too; a reconstruction failing 4 tests where the real prior code failed 0 |
| 2026-08-30 | fly#38 | **`local_mocked_bindings(.env = )` is the cleanup environment, not the target** — `.env = asNamespace()` installs correctly and never unwinds; a stub returning TRUE leaked into every later test; the tell was `expect_true(f())` passing while `file.exists(out)` failed; the fix is `local_mocked_bindings(f = stub, .package = "pkg", .env = parent.frame())` — `.package` names the target, `.env` what the mock unwinds with |
| 2026-09-02 | spacehakr#20 | **A stub that never forces its argument leaves the inner call unevaluated** — `x \|> collect()` is `collect(x)`; a stubbed `collect` that never touches `x` means `bcdc_query_geodata` never ran and the spy on it stayed NULL; `force(x)` in the stub |
| — | fly#35 | **Restore-the-bug output is truncated at 10 failures, hiding guards you asked about** — three guards added, the restoration run showed only the first; testthat's reporters stop at 10, and the knobs differ per reporter: `set_max_fails()` sets `TESTTHAT_MAX_FAILS`, which only the progress reporter reads, while `reporter = "summary"` reads `options(testthat.summary.max_reports = )` (measured, testthat 3.3.2 — `set_max_fails(Inf)` left the summary cap at 10); set the one your reporter reads, or read the returned object — `as.data.frame(test_file(f))$failed` carries every failure whatever the console printed |
| 2026-09-01 | trap#2 | **`test_local()` reloads and silently discards the patch** — `testthat::test_local()` and `devtools::test()` call `load_all()`, which rebuilds both bindings after you patched them; four restored bugs read 0/0/0/0 through `test_local()` and 6/1/2/2 through `test_file()`, with the probe value printing correctly both times; run the affected file with `testthat::test_file()` and keep the probe — each catches a different half |
| 2026-09-02 | spacehakr#20 | **A green-but-empty test blamed on `.package =` not reaching `pkg::fn()` — it does** — the diagnosis was that `local_mocked_bindings(.package = "bcdata")` does not intercept a fully-qualified `bcdata::bcdc_query_geodata()` and only `mockery::stub()` does; measured 2026-09-03 on testthat 3.3.2 it intercepts inside `local()`, inside `test_that()`, and when installed before the namespace loads, because `::` resolves through the namespace binding `.package =` patches; the stub that was never reached was the unforced `collect` argument ("A stub that never forces its argument leaves the inner call unevaluated", same PR), and `mockery` "working" did not discriminate; when a mock is installed and not reached, prove the call was evaluated before blaming the mocking tool |
| 2026-09-01 | link#250 | **An assertion with no deadline can only pass or hang — never fail** — `if ( thing_that_might_hang ); then` is only reached when the call returns, so restoring the defect does not turn the test red, it sits there, and the suite reports nothing rather than a failure; wrap it in a deadline (`with_deadline()` in `code-check-shell.md` — `timeout` is GNU-only and absent on stock macOS) and distinguish its 124 from a real non-zero, or a hang is reported as a refusal |
| 2026-09-03 | stac_floodplains_bc#46 | **A restored bug can fire a DIFFERENT guard, and the exit code cannot tell you which** — five mutations of a GeoPackage's style table each exited 1, all read as "the guard fired", and none of them had reached the guard under test: mutating the file changed its bytes, so the checksum check ran first and short-circuited. The proofs only meant anything with the item builder re-run in between so the checksums matched. **Grep the output for the message you expect, never just the status** — a suite with N guards has N ways to exit 1 and only one of them is your evidence. A sixth proof in the same run was false the other way: the mutation was a plain-text replace on serialized XML, and `ElementTree` escapes `>` as `&gt;` in attribute values, so it matched nothing and silently tested the unmodified artifact. Assert the mutation took (`assert q.count(old) == 2`) before trusting what follows it |
| 2026-09-04 | stac_floodplains_bc#26 | **And a restored bug can exit 0, when the proof mutates the wrong copy of a deliberately-duplicated literal** — the mirror of the row above. Where literals are duplicated on purpose (a builder's and a validator's, so the guard is not `x == x`), a proof must mutate **the copy the guard reads**. Adding a bogus id to the builder's set marked no item, so the validator passed — correct behaviour, reported as `WRONG GUARD (rc=0)`. `rc=0` on a restored bug reads as a pass, so it is the direction that gets believed; before concluding the guard is broken, check which copy the assertion actually consults |
| 2026-09-03 | rfp#243 | **A test that drives the helper covers the other VALUE, not the call site that chooses it** — a fix changed which argument a builder passes its helper on one branch; the test added for it called the helper directly with two hardcoded literals, so restoring the defect left 587 assertions green across six files. The commit message and the test comment both claimed it was guarded. Guard the *chooser*: a spy on the helper that records the argument and delegates, asserting what the caller picked — and resolve the real function BEFORE installing the spy, or it records its own delegating call |

### A shared working tree, and what generators leave in it

A working tree has one checked-out branch. Two sessions in it can `git checkout` out
from under each other mid-edit, and uncommitted work then sits on the other session's
branch — a later commit lands it there, a `--delete-branch` strands it. Worse: a
`git push -u origin main` pushes the local ref named `main`, not `HEAD`, so a commit on
the wrong branch prints `Everything up-to-date` and nothing was sent. Generators —
config regenerators, formatters, `csv.writer` rewriting every line's terminator — put
side effects in the tree that `git add -A` sweeps into a commit describing something
else. And running a generator is not committing what it generated: a build in a temp
dir leaves the repo's artifact stale while the author truthfully reports having
verified it.

One worktree per session (`-b <new-branch>`, chained with `&&`). **The tag and release
step needs a worktree too.** Every example here is an edit, so a reader who follows the
rule still runs `git checkout main && git tag` in the shared checkout — which was on
another session's branch with 281 lines of its uncommitted work when it happened
(soul#141, 2026-09-01; nothing broke, by luck). Release from a throwaway tree detached
at `origin/main`, push `HEAD:main` and the tag from there, and leave the shared
checkout's `main` alone; `gh-pr-merge` step 5 carries the form. Assert the branch
before any commit or flip. Stage by path. Generate from the committed tree, never the
checkout — a mid-edit source is internally inconsistent, which is worse than stale.
Verify the artifact after a push, not the push output. **And a dirty peer repo you are
only passing through is someone's in-flight work, not leftovers** — `git pull` reporting
"Already up to date" says nothing about the working tree, and staged edits are invisible
to it. Do not tidy, commit, `git checkout .` or `git add -A` in a repo you came to read.

Recovery, when it has already happened: back up the touched files, confirm the other
branch's changes do not overlap yours, and `git checkout <your-branch>` carries
uncommitted work across. If you committed onto their branch, restore their pointer with
`git branch -f`. If their branch has an open PR, cherry-pick forward through a throwaway
worktree rather than force-pushing into someone else's PR.

| date | where | instance |
|---|---|---|
| 2026-07 / 2026-08 | floodplains; gq#57; rtj | **Two agent sessions must not share one git working tree — give each a worktree** — three collisions in one session including a `--public-clean` scrub that committed onto a parallel session's feature branch; a cross-repo fix landing in someone's open PR; a memory-audit commit reporting `Everything up-to-date` while absent from `origin/main` |
| 2026-08-26 | fly | **Generating from another repo's working tree copies its half-finished edits** — `karpathy.md` gained a section and its pointer was corrected minutes later in a separate commit; the sync landed between them and shipped "see §5" for a rule that had become §6; `git pull` said up to date throughout |
| 2026-08-27 | floodplains | **`git add -A` after a generator sweeps its side effects into your commit** — a "one-line config change" of 6 files, 28 insertions, 50 deletions; the file count was the only warning |
| 2026-09-03 | soul#168 | **A file staged for one commit and set aside rides into the next one** — "stage by path" assumes the index is empty when you start; two files staged for phase 2, then left while phase 3 was written in another file, landed in phase 3's commit with phase 3's message, and the only signal was a file count in `--stat`; before every commit read `git status --short` and expect exactly the paths you mean, and `git restore --staged <path>` anything you set aside |
| 2026-09-04 | stac_floodplains_bc#26 | **A file staged and then EDITED commits the version from before the edit** — the sibling of the row above, on content rather than paths: `git add NEWS.md`, then a correction to the same file, and a plain `git commit` ships the stale copy. Here the staged version carried a release-note figure already known to be wrong; `git status` says `MM` and nothing else does. Caught by a reviewer, not by the author. Read `git status --short` before every commit and treat a second `M` as unfinished, or diff what you are about to ship with `git diff --cached` rather than `git diff` |
| 2026-08-28 | rfp#219 | **Running a generator is not committing what it generated** — four schema CSVs gained a column, the builder ran clean in memory, the shipped GeoPackages were never rebuilt; CI caught it only because a drift guard rebuilds and byte-compares |
| 2026-08-29 | stac_dem_bc | **A writer that rewrites a whole file changes more than the rows you added** — Python `csv.writer` converted an entire CSV to CRLF on a two-row append; 21 insertions, 19 deletions for two rows; open in append mode with an explicit `lineterminator` and diff before staging — staging by path does not help when the churned file is the one you are staging |
| 2026-08-28 | floodplains#44 | **Config round-trips discard everything that is not data** — a "load, change a key, write back" update (`yaml::write_yaml`, `json.dump`, `toml.dump`, some `yq -i`) round-trips the data and silently drops comments, key order, blank lines and equivalent spellings (`null` vs `~`); the file still parses with the right values, so nothing fails, and what is lost is the only record of why a setting is what it is; the first working fix for a runner destroying hand-maintained config then deleted 8 lines of rationale in one `area.yml` and an open question in another — a fix for silent data loss is itself a prime candidate for it; edit only the lines you own (locate the key, rewrite that line keeping its trailing comment, append new keys past the block they must not land inside, refuse rather than mangle a nested block), reserve the full serialize for the create path, and assert it — count comment lines before and after and check `all(before_lines %in% after_lines)`; the region run went from 50 deletions to 2 insertions |
| 2026-09-04 | stac_floodplains_bc#53 | **A committed generated artifact churns on every render unless every id and timestamp generator is pinned — and a `self_contained` renderer may reach the network to make one** — a 5.8 MB `index.html` rewrote itself identically on each build from three sources: `htmlwidgets` container ids, `mapgl`'s `paste0("legend-", as.hexmode(sample(...)))` legend id, and — the one that mattered on its own — pandoc's `--embed-resources` **fetching the shields.io badges at render time**, putting a network call inside a render documented as needing none and varying the output with whatever came back. `htmlwidgets::setWidgetIdSeed()` and `set.seed()` pin the first two; the third is fixed by keeping remote images off the self-contained target. Same class the repo pins `OGR_CURRENT_DATE` and uuid5 for, one toolchain over. **Assert it rather than assuming: render twice and compare digests** — the byte-compare is what found all three, and what will find the fourth |
| 2026-09-01 | — | **The two safe ways to edit a CSV each break the other's case** — `csv.writer` re-quotes every field by its own rules, so editing 2 rows of a 6-row file rewrote all 6 and buried the real change ("A writer that rewrites a whole file changes more than the rows you added" covers the terminator half, not the quoting half); the obvious fix, plain-text replacement inside the field, then put a comma into an unquoted field, every data row gained a column, and `read.csv` silently consumed column 1 as row names; the rule is conditional — plain-text only when the field is already quoted or the inserted text carries no delimiter, `csv.writer` (with `lineterminator='\n'`) only when every data row is being edited anyway; afterwards assert field count per row and the reader's column names, because a column shift produces data that parses |
| 2026-09-05 | stac_orthophoto_bc | **`git checkout -b` in a shared checkout branches off whoever else's branch is out, and drags their uncommitted work with it** — a new branch for issue #6 was cut while the tree sat on a parallel session's `9-…` branch, so it started at *their* baseline commit and inherited eight of their modified/untracked files. Nothing in `checkout -b` says which base it used. The tell came one step later and reads as unrelated: `git checkout main` refused with `Your local changes to the following files would be overwritten` — naming *their* files, in a session that had edited none of them. `git checkout -b x main` pins the base but still carries their working tree; only a worktree separates both. Before branching in a shared checkout, `git branch --show-current` and `git status --short`, and if either is not yours, `git worktree add <path> -b <branch> main` instead. Recovery is cheap **if nothing was committed**: `git checkout <their-branch>` (same SHA, so no file moves) then `git branch -D` yours |
| 2026-08-26 | fly | **Dirty files in a peer repo are another session's work, and tidying them destroys it** — `soul/conventions/` went dirty and clean three times inside ten minutes while another session authored convention text; a well-meant `git add -A` or `git checkout .` from a session that only came to read would have committed or discarded a half-written rule. The worktree rule above covers two sessions *editing* one repo; this is the cheaper read-only case, named in the paragraph above only since this row — leave the tree alone, and if you must know whether it is yours, `git status` and `git diff --cached` before touching anything (soul#116) |

### A wrapper's exit is not the work

A wrapper reports its own exit. `caffeinate`, `time`, `ssh … | tee`, a background
task, a per-item loop, a `;`-chained pair — all routinely surface exit 0 while the
inner job hit `Execution halted`. Merging stderr into stdout corrupts the stdout you
parse, and only on a long line; a `\r` progress bar on stderr makes interleaved log
lines vanish entirely; `system2()` quotes the command and pastes the arguments raw, so
a path with a space silently splits and the empty stdout reads as "nothing to report".

Gate on the artifact: in-band error markers (`grep -c "Execution halted\|Error:"` is 0)
**and** the output's mtime is newer than a marker touched at run start. `set -euo
pipefail`, `&&` between steps of one operation, stderr to a file whose contents you
carry onward (not its path — a temp file is gone by the time the assertion needs it).
Read the exit status, not just the output.

| date | where | instance |
|---|---|---|
| 2026-07 | floodplains | **A wrapper's exit 0 is not "the work completed" — gate on in-band error + output mtime** — a Pass-2 change declared "12.4×, byte-identical" and merged; the run had halted before writing, so the A/B compared the unchanged baseline against its own backup |
| — | — | **pipefail with ssh+tee** — `ssh … \| tee log` returns tee's exit; remote work skipped, notification said completed |
| 2026-08 | — | **Never silence stderr on a mutating command, and never chain one with `;`** — `git mv … 2>/dev/null; mv …` succeeded doing the wrong thing and the failure surfaced one command later as "cannot stat" |
| 2026-08-29 | stac_dem_bc | **A progress bar on stderr silently eats your log lines** — per-item `logger.warning` beside tqdm; failing ids unrecoverable from the log locally and in CI |
| 2026-08-30 | rfp#227 | **Merging stderr into stdout corrupts the stdout you are parsing** — a 145-field JSON line with `QObject::killTimer` spliced into it after a year of working on 20-field payloads; and the fix's temp file was unlinked before the assertion that needed it |
| 2026-08-29 / 08-31 | gq#64, gq#76 | **`system2()` shell-quotes the command but not the arguments** — `git -C "/some path"` split, empty stdout read as "not a git checkout", every later check skipped; and it *raises* on a missing command, so a skip written after the call is unreachable; `shQuote()` every path argument and read `attr(out, "status")` |

### Zero-length, empty, and unset are three different things

`paste0(character(0), "x")` is `"x"` — one phantom row from an empty frame. A
zero-length value in a row-builder yields zero rows, so the whole group vanishes from
a `map_dfr()` and the output looks correct, just shorter. `x == character(0)` is
`logical(0)`, so every branch is false and the fallback runs — usually *create*,
producing an unnamed object rather than an error. `VAR="${A:-}"` sets the empty
string, which passes a presence test (`"PROJ_LIB" in os.environ`) that `unset` fails.
`names(character(0))` is NULL, which `expect_setequal()` refuses — so the guard breaks
the day you finally earn the empty state.

Guard the empty frame explicitly (`if (!nrow(x)) return(character(0))`). Fold to a
scalar at the boundary (`sum()` over `st_area()`). Test the argument, not the search
result. Build commands as arrays and add an assignment only when there is a value. Use
`stats::setNames(character(0), character(0))` and say why.

| date | where | instance |
|---|---|---|
| 2026-08-24 | trap#14 | **`paste0()` treats a zero-length argument as `""`** — an empty annotation table produced one composite key, reported as "an annotation matching no session" |
| 2026-08-28 | fly#30 | **A zero-length value in a row-builder drops the whole record, group and all** — a coverage table silently omitted a photo-year whose frames all had unresolvable footprints |
| 2026-08-28 | rfp#213 | **A zero-length value in a comparison makes every branch false and silently picks the fallback** — two exported writers documented `group = NULL` as "root" and "registry default"; both created an unnamed group at the end of the tree where everything draws under the basemaps |
| 2026-07-31 | rfp#93 | **Empty is not unset — `VAR=` passes a presence check that `unset` fails** — `PROJ_LIB=` made rasterio call `set_proj_data_search_path("")` and fail with "Cannot find proj.db"; read as a missing dependency; and never write `[ -n "$X" ] && arr=(…)` as a bare top-level list — under `set -e` a false test aborts the script; use an explicit `if` |
| 2026-08 | gq | **`expect_setequal()` refuses NULL, and `names(character(0))` is NULL** — the "every exemption still needed" assertion errors at the exact moment the list is correctly emptied |
| 2026-09-05 | floodplains#79 | **`is.null()` cannot tell a key that is absent from a key that is present and empty, and both skip the guard** — a config flag guarded by `if (!is.null(cfg$x) && <malformed>) stop(...)`. `x:` with no value, `x: ~` and `x: null` all parse to `NULL`, so the guard short-circuits and `isTRUE(NULL)` is FALSE: the area ran the default while its committed config *read* as opted-in, silently. Measured on all three spellings. The three states are absent / present-empty / present-valued, and the predicate collapsed the first two — the same shape as "Empty is not unset" above, one layer up in the config parser. `"x" %in% names(cfg)` discriminates (TRUE for present-empty), which keeps an explicit `x: false` legal. The tell: a guard written to catch a *wrong* value, on a key whose *absence* is also meaningful — ask what the parser returns for the empty spelling before trusting the null check |

### The probe is broken before the world is

When an ad-hoc probe reports that long-shipped code is broken, the prior belongs on
the probe. The tell is an obviously-correct item in the failure list: a probe reporting
13 things missing, one of which you can see with your own eyes, is wrong about all 13.
A 100% failure rate on shipped code is as implausible as 50%. A 200 with a perfect
schema can still be a placeholder image or a "trial expired" page — every cheap
assertion passes because the shape is right and only the meaning is wrong. And
constructing a sibling path from a known-good one assumes a uniform naming convention;
the 404 then reads as "does not exist" rather than "I guessed wrong".

Print a positive control. Reconcile the count against the population. Enumerate the
container rather than construct the path. Inspect the bytes you are acting on, never a
formatted rendering of them. When a claim is flagged as under-evidenced, narrow it —
widening adds a quantifier over a population you have not enumerated, and on one memo
every widening broke and every narrowing held.

| date | where | instance |
|---|---|---|
| 2026-08-29 / 09-01 | rfp#216, rfp#242 | **A probe reporting a defect in long-shipped code is usually a broken probe** — 13 theme groups "dangling" because the path walk anchored at the unnamed root; 0 of 25 when anchored right; and 13 of 13 "mismatches" from `identical(length(x), 1)` — integer vs double |
| 2026-08 | gq#57 | **A valid response is not a correct one — services fail in the shape of success** — Carto went key-only and served an "API KEY REQUIRED" watermark through a vignette, `R CMD check`, and a pkgdown deploy; the watermarked tile had *fewer* dark pixels than the clean one, so the measured detector could not separate them — measure before shipping one; prefer providers that cannot enter the degraded state (keyless, pinned), detect only the separable degenerate cases, canary on a human's machine not CI, and warn rather than discard |
| 2026-08-27 | BC LidarBC | **List the container; do not construct the sibling path** — swapping `/dem/` for `/dsm/` 404'd on 2017 tiles (suffixed `_dsm.tif`); "no surface model" became a project's central constraint for weeks; listing showed DSM in 25 of 38 |
| 2026-08-27 | rtj#221 | **Do not build an exact-match edit from a formatted display** — `sed 's/^/  /'` padded the read; the replace matched nothing; two failed rounds before `repr()` showed two spaces where the display implied four |
| 2026-09-01 | flooded#52 | **A claim flagged as under-evidenced gets repaired by widening, and widening is what breaks** — six review rounds, 36 findings; every fix added a quantifier over a ragged dataset×resolution×lineage grid; terminated by reproducing the old behaviour to the digit and measuring every row |
| 2026-09-03 | rtj#243 | **A defect rate is a claim about the population filter first, and the subject second** — a photo-reference audit reported 142 of 290 references (49%) dangling on the server, which flipped a design conclusion and was one command from being written into another repo's issue as fact. The filter for the *reference* side was right; the filter for the *server* side required the path to contain a `photos/` directory, so every image stored elsewhere was invisible and counted as missing. Re-run on all image extensions, case-insensitive: **6 of 290, 2%** — and those six reconciled exactly to an already-filed issue about bare filenames. A 49% failure rate in a shipped project was the tell, and the reconciliation that catches it is cheap: **count both sides of a ratio with independently-justified filters, and re-run the denominator's filter one notch looser before believing a rate**. Sibling of the positive control above — here the control is a *second, more lenient* population, not a known-good item |
| 2026-09-05 | rfp#275 | **A differential baseline stops being one the moment the parent moves** — a branch suite was compared against a baseline measured earlier the same session, at a commit that had since stopped being the branch point: another session shipped a release into `main` in between. The comparison still *ran*, still produced two numbers, and would have attributed six failures on a parent that no longer existed. Re-run at the real branch point the counts moved 4409 → 4711 on the baseline side alone. **A baseline is only valid against `git merge-base HEAD origin/main`**, so in a shared checkout re-derive it at push time rather than reusing the one taken at branch time — and note the failure direction: the stale baseline was *lower*, which flatters the branch. Sibling of "a measurement carries the time it was taken", where what expired is the reference rather than the reading |
| 2026-09-04 | rtj#282/#283/#284 | **And the filter can be right while the *predicate* is wrong** — the refinement of the row above, met three times in one session on one number. A photo manifest reported 142 of 290 present; the count then moved to 35, to 11, to **0 genuinely lost**, and no step was an arithmetic error. First the resolver named three directories photos were known to live in and the project also had a fourth. Then the denominator included **form-template placeholders** — six dummy filenames on a worked-example record, which is why three different projects reported *exactly six* missing, a tell sitting in my own summary table unexamined. Then the predicate itself: `exists in the project directory` was standing in for *is this photo safe*, while photos are **deliberately moved off** to control project size — so the check penalised the housekeeping it should encourage, on the gate that precedes destroying a generation. **Ask what the predicate is a proxy for before trusting the rate**, and when several independent subjects report an identical count, that equality is the finding. Each correction came from workflow knowledge no amount of re-measuring would have supplied — so when a rate survives one correction, ask who else knows what the number means |
| 2026-09-05 | rfp#268/#271 | **When you cannot list, read the PRODUCER — "unlistable" is not "unknowable"** — a bucket answered `403 AccessDenied` to a list (correct for a `s3:GetObject`-only policy), so the artifact was reported as unconfirmable and a shipped feature was documented as blocked on it, with a follow-up issue filed saying so. The job that writes the object recorded the exact key in its own source; one `HEAD` on it returned **200, 66,635,819 bytes, staged the previous day**. The reasoning was "guessing a key is the construct-the-sibling-path antipattern" — true of a key *derived from a pattern*, and the opposite of true for one *read from the code that writes it*, which is that rule's own remedy. **Before concluding an artifact's presence is unknowable, grep the producer for the path it writes**; and treat a self-filed "blocked on X" as a claim to check rather than a conclusion, since nothing downstream will ever re-test it |
| 2026-09-04 | rfp | **An error naming its own remedy, mapped onto a remembered failure instead of read** — a memory note said `op read` "times out on authorization"; the actual error was `couldn't connect to the 1Password desktop app… update to the latest version and restart the app`, and the app was running with `--just-updated --should-restart`. Not a timeout, not an authorization problem, and the fix was in the text. Cost: the *preferred* documented route was abandoned for the last-rank fallback, the user was escalated to, and then the credential's **name** was doubted — it had been right all along. Two tells, both cheap: the error prescribed an action nobody took, and the remembered failure mode had a different **shape** (a hang) than the one observed (an immediate error). **Read the error's own words before matching it to a prior**, and when a convention ranks routes, confirm the preferred route's prerequisite is genuinely absent rather than merely erroring once |
| 2026-09-03 | drift#48 | **A sibling guard that passes is only a control if it was pinned before the event** — two frozen cache-key goldens, one red and one green, and the green one was read as evidence that the shared inputs were fine. It was not: it had been **re-pinned after** the environment moved, so it could only ever agree. Recomputing its *contemporaneous* predecessor showed that value had moved too, which flipped the diagnosis from "one key's inputs changed" to "the hash function changed under all of them" and changed the fix entirely. The filed issue had reasoned from the green tick and named the wrong cause. **Before treating a passing sibling as a control, date its pin against the event** — a guard re-pinned afterwards is a photograph of the new world, not a witness to the old one. Same family as the vendored-witness rule below, arriving through a re-pin rather than a stale copy |
| 2026-09-04 | knowledge#4 | **A per-project config file can shadow the user-level one entirely, so the value you read is not the value that loads** — a repo-root `.Renviron` holding one line made R skip `~/.Renviron` completely, and every `PG_*`, `AWS_*` and `GITHUB_PAT` came back empty for any R process started in that repo. The symptom accused the world: `invalid integer value "NA" for connection option "port"`, which reads as a broken database config. `grep` on `~/.Renviron` showed the variable set, so the file was believed and the code doubted. **The positive control is the same command from a different working directory** — `PGPORT` was `5432` from `~` and empty from the repo, which localises it in one step. R, direnv, npm, git and ssh all resolve config by a search order in which a nearer file wins, and several stop at the first hit rather than merging. Ask *which* file actually loaded before trusting any variable's absence, and note the redundant-shadow shape: the offending file duplicated a value already set in `.Rprofile`, so it added nothing and hid everything |
| 2026-09 | rfp | **Write the numbers last, against the final tree** — a figure written into prose mid-change is measured against a tree that no longer exists by the time the prose ships, and the second actor is usually *you*, one commit later: *"I had even reordered the phases to write prose against the final state — and then changed the state again."* The time-stamping rule in `karpathy.md` §7 warns about measurements staled by an earlier session; this is one staled by your own later work inside a session. When a fix lands after the prose, re-measure rather than assuming the prose still holds (soul#176) |

### Written data outlives the fix

Changing the writer changes nothing already written. The code is correct, the tests
pass, the issue closes — and every existing record keeps the defect, sometimes
self-perpetuating when a job reads the published artifact back and rewrites it. A
change-detection cache persisted at detection time strands every input whose
processing then fails, invisibly, forever. A cache keyed by fewer inputs than the
write depends on returns plausible wrong data. Tightening a consumer's assertion
breaks every producer that legitimately left the field empty, and the producer that
bites is the install script nobody thinks of as one. Teaching a build step to record
provenance makes it safety-critical: a wrong SHA satisfies every guard built to catch
its absence.

Reconcile existing records — rewrite in place, do not rebuild through today's code
path. Write caches last, or atomically with the output. Over-key, never under-key, and
hash resolved values. Grep the producers before tightening the consumer, and move the
check as early as the fact is knowable. Gate a provenance write on the build's own
exit status; pin only what has no other identity; resolve an identifier once per run.

| date | where | instance |
|---|---|---|
| 2026-08-31 | stac_dem_bc#34 | **A progress manifest is a claim about a step that may not have run** — `run_rewrite` appends on the LOCAL write; CI's cache commit is `always()`; the sync is skipped on failure. So a failed run persisted a ledger asserting items were published that never reached S3, and `todo = published - manifest` skipped them forever with the completeness check and the audit both passing. Ask what an entry *claims* and whether the thing it claims actually happened — where that depends on a later step, gate the persistence on that step, not on the one that produced it |
| 2026-08-29 | stac_dem_bc | **A fix to code that writes data is not done until the written data is reconciled** — four instances in one day; 90 published items kept hrefs that could not form an HTTP request, and the monthly job wrote them back out every run |
| 2026-02 | stac_dem_bc | **A cache written before the work succeeds strands its inputs permanently** — 2,107 URLs marked seen and never built; found only by diffing the cache against outputs |
| — | drift#25 | **Cache keys must cover every output-affecting input** — rasters cached as `<source>/<year>.nc` with no AOI in the key; a second watershed received the first's raster masked to its extent, ~3% overlap looking plausible enough to almost ship; hash *resolved* values, sf geometry as WKB (`st_as_binary(…, endian = "little")`) with the CRS as a separate key member, `as.numeric()` first because `10L` and `10` hash differently, and canonicalize the geometry before serializing it (ring order and orientation are not fixed by topology — `code-check-spatial.md`) — and check the `force` escape hatch actually overwrites: drift#25's `force = TRUE` errored on the existing file, so prefer the writer's `overwrite = TRUE` over a bare `unlink()` |
| 2026-09-01 | link#264 | **Making an optional field mandatory breaks every producer that legitimately left it empty** — four producers, three fine, the fourth `update_hosts.sh` installing from a tarball with no `Remote*` fields; the rejection landed after cloud instances were paid for |
| 2026-09-01 | link | **Teaching a build or install step to record provenance is a change to a safety-critical path** — `R CMD INSTALL \| tail -3` wrote the pin for a build that failed; an env pin beat a checkout's own git state; nothing expired it; five findings inside one ~40-line fix |
| 2026-08 | gq#57 | **An inventory is only complete relative to a boundary — name the boundary** — 9 lines in 6 files, verified twice, complete for gq; consumers read `soul/skills/cartography`, which shipped its own snippet naming the broken provider |
| 2026-08-31 | flooded; flooded#49 | **A defect's magnitude is dataset-specific — measure it where it lands** — a 3.59x depth error measured as ~2x area on the 10 m fixture and 16% on the 30 m production watershed; percent-of-AOI moved 27.51 → 27.50 — but a ratio is stable only when its denominator is inside the affected region too: floodplain-as-percent-of-watershed fell 8.67 → 7.35 on the same defect, the same ~15% as the hectares, because the watershed does not shrink, and three report appendices publishing that ratio beside the absolute needed both numbers restated; ask what is in the denominator before calling a proportional claim safe |

### Serialization loses meaning silently

A serializer's default for "no value" is rarely a null: `NA_real_` becomes the string
`"NA"`, R `NULL` becomes `{}`, GDAL has no null and `str(None)` writes `'None'` — each
a valid value every schema check accepts, and `{}` passes `is not None` on the far
side. A rename emits two signals — an expected key missing, an unrecognised sibling
present — and reading only the first cannot distinguish rename from absence; the
ambiguity is different at each depth, so it recurs one level out. A system that both
records and renders drifts: the sidecar computed `finish(start(x))` on one line and
reported 0.0 s for a multi-minute build. A structure transcribed from an external form
is a snapshot: the 2026 permit portal swapped Easting and Northing columns. In-place
metadata writes move a COG's IFD to the end — still valid, still hash-verifiable, no
longer cloud-optimized. Raw XML/JSON diffs report attribute order as drift.

Set `na=` and `null=` explicitly and say why; build records with `list()`, never
`[[<-`. Reject unknown keys where the set is closed, pin the key shape where keys are
data. Prefer the record over the rendering. Assert on magnitude or format, not
position. Order the layout-aware writer last, and assert the property (`cog_validate`),
not the parse. Canonicalize before diffing, and name every field you mask.

| date | where | instance |
|---|---|---|
| 2026-09-01 / 09-02 | stac_floodplains_bc#17, #36 | **A serializer's default for "no value" is rarely a null, and every wrong answer is silent** — three defaults wrong in one afternoon; a colon in a GDAL tag key collapsed eleven fields into one; and the serving API omitted the published nulls the store kept |
| — | cred#23/#25 | **jsonlite serializes NA numerics as the string `"NA"`, not `null`** — and only the numeric types: `NA_character_` and logical `NA` become `null` correctly (jsonlite 2.0.0), so a record with a failed count carries `"documents": "NA"` beside integers and round-trips unchanged forever; `na = "null"` on every `toJSON()`/`write_json()` that can receive one, and identical flags on any preview path, or the preview is not what gets written |
| 2026-09-01 | stac_floodplains_bc#17 | **A rename emits two signals, and reading only one cannot distinguish it from absence** — leaf, section, root: three review rounds, the same defect at three depths; `{"algorithm": "sha256"}` published `"sha256"` as the value |
| 2026-09-01 | link / floodplains | **When a system both records and renders, the rendered copy drifts into fiction** — `aquatic_network.stamp.md` said 0.0 s elapsed for a 4,877-segment build whose run log put the four groups at 1.04–4.12 min; the sidecar was a candidate STAC field |
| 2026-08 | template_permit_fish | **A structure transcribed from an external form or API is a snapshot, not a contract** — `UTM Zone \| Northing \| Easting` became `\| Easting \| Northing`; four of five sites transposed on a submitted permit application |
| 2026-08 | rfp#17 | **Canonicalize serialized documents before diffing them** — raw compare said 5 of 43 layers matched, arguing for an architecture change; canonicalized with uuids masked it was 46 of 47 |
| 2026-09-01 | stac_floodplains_bc#33 | **An in-place metadata write can break a format's layout contract, and nothing will say so** — every COG in a published catalogue had its main IFD at 98.9–99.6% of the file; checksums verified; `IGNORE_COG_LAYOUT_BREAK` read as boilerplate |

### One fact derived twice

A count taken from one artifact and the things counted produced from another, with a
guard comparing the two. It fires on healthy input, and because it looks like
diligence the fix goes onto the inputs rather than the comparison — so it comes back.
Line tools disagree with each other and with the truth: `wc -l` misses an unterminated
last line, `grep -c ''` exits 1 on an empty file under `set -e`, and both count lines
rather than records. A paged API's default page is a well-formed 200 whose missing
items read as *absent from the server* rather than *not requested*, and it survives
review because the fixture was smaller than the page.

Derive the expectation from the artifact the consumer actually consumes. For each
guard, name the producer of each side; if they differ, it can fire on good input.
Count records by parsing, not with a line tool. Set the page size explicitly on every
request treated as evidence, and assert it at a size larger than any plausible default.

| date | where | instance |
|---|---|---|
| 2026-08-30 | stac_dem_bc | **One fact derived twice, never reconciled** — three times in one change: 600 ids vs a page of 10; a duplicate counted twice, fetched once; one id → two hrefs counted once, fetched twice; eight of nine counts were structural and every bug landed on the ninth |
| — / 2026-07-30 | — / mdb-export | **Counting lines: `wc -l` and `grep -c` fail in opposite directions** — `grep -c` returned 1 for 102,460 single-line JSON records; `wc -l` reported 556 lines for 517 records with embedded newlines, and the number reached a README; use a `count_lines()` helper (`grep -c ''` with `\|\| n=0`) checked against all four inputs — empty, unterminated, terminated, missing — and parse records inside a structured file rather than counting lines |
| 2026-08-30 / 08-31 | stac_dem_bc; STAC catalogue | **A paginated API's default page size silently truncates a lookup used as a check** · **A paged API's default `limit` reads as absence** — `POST /search` with 600 ids returned 10; `limit=200` reported two of sixteen surveys absent; paging returned 230 with every one present |
| 2026-09-03 | rtj#259/#260 | **The set you compare against, derived from the artifact under test** — an acceptance script asserted a GeoPackage held only its form's own tables, and built "its own tables" from `st_layers()` on the *deployed* file. That listing includes the foreign table the check was hunting, so `setdiff()` came back empty and it passed on exactly the file it existed to flag; a fixture carrying `layer_styles` reported 0 failures until the set came from the *shipped* artifact instead. Not caught by four review rounds — found by running the check against a deliberately-bad fixture. **For a guard of the form "X contains only the expected set", the expected set must come from a producer the subject cannot influence**, and the same iteration must then walk the expected set rather than the subject's, or a *missing* member is invisible too |
| 2026-09-04 | floodplains#77 | **A fix that derives one literal introduces another whose other half lives in a file the code never opens** — the mechanism behind four review rounds (7, 4, 7, 9 findings). Each round replaced a hardcoded value with one read from an artifact, added a new literal beside it, and wrote a *comment asserting the agreement* instead of a line checking it. Three of those comments were measurably false: `BYPRODUCTS` claimed to be `.gitignore`'s list and was missing two entries; a figure caption claimed to describe `config/disturbance.yml` while the cause list stayed hardcoded; and `nzchar()` claimed to filter empty cells it could not reach. **Terminate by partitioning every literal**, not by another round: a **contract this repo chose** must be hardcoded or the guard can never fail, and a **fact about another artifact** must be read from it or `stop()` on divergence — the two genuinely unavoidable ones carry a source-and-date stamp naming the file that makes them true. And enumerate *mechanically*: a curated list of 22 missed 7, all on one axis — literals inside strings that get **printed** (titles, captions, `fig.alt`) rather than inside values that get used, which is where a wrong caption hides because nothing consumes it |

## Rules that stand alone

General, and not an instance of a mechanism above.

### Do not edit files a long test run is reading

- `devtools::test()` (and most runners) load each test file **when they reach
  it**, not at launch. A 30-minute run therefore reads whatever is on disk at
  that moment, so edits made while it runs are half-applied and the result
  describes a tree that never existed.
- The tell is a **changing pass count** across runs of "the same" tree —
  3490, then 3496, then 3500. A moving denominator means the input was moving.
- Cost 2026-08 in rfp#178: two full Docker suites (~1 hour) both reported
  `FAIL 1`, and the failure was a test written *during* the run, executing
  against source from *before* the fix that made it pass. It was nearly reported
  as a regression.
- **Commit before a long run.** While it runs, do work that touches nothing it
  reads — issue bodies, PR text, planning. And when a long run fails, get the
  `file:line` before forming any theory: a mid-flight edit and a real regression
  look identical in a summary line.

### Adopting Existing Config

When importing config from one location into a canonical one (legacy `~/.bash_profile` → dotfiles repo, old script's env → repo, another project's `settings.json` → soul):

- **Verify every referenced path/binary exists.** Dead PATH exports, missing interpreters, stale env vars should be cut, not codified.
  Shell paths: `for p in $(echo "$PATH" | tr ':' ' '); do [ -d "$p" ] || echo "DEAD: $p"; done`
- **Ask before dropping a reference** — it may be something the user forgot to reinstall on this machine, not something to delete.
- **Curated subset, not verbatim copy.** The diff should reflect what you verified, not the whole source.

### Test the cold/create path of idempotent code, not just the warm no-op
- Idempotent provisioning code (a resolver-file writer, a config installer, a "create unless present" block) has two paths: the **cold** path that actually creates/writes, and the **warm** path that detects "already present" and skips. They exercise almost-disjoint code.
- Testing only on a host where the artifact already exists hits **only the warm no-op** — which cannot catch any cold-path bug: missing-directory, a derivation that returns empty, a pipefail abort before the write, wrong permissions, a flush that never runs. The warm path's job is literally to do nothing, so a green warm test proves almost nothing about onboarding.
- Every fresh host runs the **cold** path — that's the one onboarding depends on. Test it deliberately: back up + remove the artifact, run cold, assert it was created correctly, then re-run to confirm the warm no-op. (Caught 2026-06-23 on rtj#75: the resolver-writer's first test plan only ran the warm path on a host that already had `/etc/resolver/<suffix>`; a Plan-agent review flagged that the cold path — the one every new host takes — was untested. Fixed by `sudo rm`-ing the file and running cold before close.)
- Generalizes beyond shell: any "ensure X exists / converge to desired state" operation — Terraform resources, migrations, package installs — wants the from-absent path tested, not just the already-converged re-run.
- **The warm path is not always the trivial one.** "The warm path's job is literally to do nothing" holds for a provisioning check and inverts for anything that *compares before deciding* — a signature check, a schema diff, a content hash. There the warm path runs the most code and the cold path is the one that skips. A suite whose fixtures always build into a fresh `withr::local_tempdir()` only ever runs cold, stays green, and the comparison it never reaches can be outright broken. Caught 2026-08-28 in rfp#207: the signature built its geometry names with `paste0("gpkg_geometry_columns.", character(0))`, which is length one, so `setNames()` errored on a child table with no geometry row — but only against an existing file, so `devtools::test()` passed and `build_forms.R`, the one caller rebuilding in place, failed. When the code compares rather than converges, add a rebuild-in-place test.

### Do not write to an artifact a human is testing on

- Handing someone a deployed thing to test — a synced project, a staging
  database, a preview build — and then continuing to push changes into it makes
  two writers for one artifact. The tester chases versions, and any client-side
  lock or "another process is running" error that follows is **yours**, not
  theirs to debug.
- It also corrupts the evidence. When the tester reports a problem, you no longer
  know which version they were on, so a symptom cannot be tied to a change.
- Caught 2026-08-26 in rfp#186/#196: three pushes into a live Mergin project
  during a field test, taking it from v1 to v9 while the phone was syncing. The
  app reported "another process is running" and the tester tried removing and
  re-adding the project before the cause was identified as the other writer.
- Rule: **hand over one version and stop.** If a fix is needed mid-test, say so
  and let the tester decide when to take it. Batch changes rather than pushing
  each one. When you must push, say which version you pushed and what changed, so
  a later report can be anchored to it.

### Percent-encode a URL at construction, not at consumption

- A URL built by string-concatenation from filenames inherits whatever those
  filenames contain. An unencoded space is accepted by lenient clients — browsers,
  `aws-cli` — and rejected by strict ones, so the break is deferred and then
  arrives all at once.
- Caught 2026-07 in stac_dem_bc#25: hrefs carrying literal spaces worked for
  months, then every strict `curl` fetch failed together — 90 items, 0-byte
  fetches. Nothing changed about the hrefs; the consumer changed.
- Encode where the URL is **built**. Encoding at the point of use means every
  future consumer has to remember, and the one that forgets is the one you find
  out about in production.

### A preview flag is only safe if it previews

- `--dry-run`, `DRY=1`, `--plan` conventionally mean "show me what would happen".
  **Nothing enforces that.** A flag that skips the *expensive* step while still
  performing the *destructive* one is worse than no flag, because it is exactly
  what people reach for when they are unsure.
- Symptom: you run the preview to check something unrelated, and `git status`
  afterwards shows deletions you never asked for.
- Caught 2026-08-27 in floodplains#44: `run_region.R` prints
  `[DRY] plan + configs written; no pipeline runs` — it skips the pipeline, not
  the config write. A `DRY=1` run to verify an unrelated one-line change deleted a
  watershed group's second-species scenario rows, every literature citation in two
  `flood_scenarios.csv` files, and a `break_points.csv`. 50 deletions from a
  command documented as "plan only".
- Before trusting one, read what it actually gates. If you own it, make the flag
  return **before the first write**, not before the first slow call.
- Cheap audit either way: run `git status` immediately after a dry run.

### Bare `y`, `n`, `on`, `off`, `yes`, `no` are booleans in YAML 1.1
- The YAML 1.1 core schema resolves `y`, `Y`, `n`, `N`, `yes`, `no`, `on`, `off`, `true`, `false` (and their case variants) to **booleans**. Most parsers in wide use — libyaml, PyYAML, R's `yaml` — still do this.
- So a column, key, or field literally named `y` stops being a string the moment it is written unquoted:
  ```yaml
  cols:
    - name: y        # parses as logical TRUE, not "y"
  ```
  Nothing errors. The consumer simply never matches that entry again, and whatever it was supposed to do to it silently does not happen.
- Bites hardest in **schema and config files**, where single-letter names are normal: coordinate columns (`x`, `y`, `z`), flags, short codes. Quote them: `- name: "y"`.
- Caught twice in one file 2026-08-24 (crate#9) — once in a canonical column list and once in a variant's column list. Both found by a guard that asserted every declared name `is.character()`; reading the YAML had not found either.
- Worth an assertion rather than vigilance: after parsing any config that carries user-chosen names, check they are all strings. The failure is invisible otherwise, because the wrong value is a perfectly valid one.

### Documentation Staleness
- Moving/renaming scripts: update CLAUDE.md, READMEs, usage comments
- New variables: update .tfvars.example
- New workflows: update relevant README

### An ordered dispatch makes severity ordering load-bearing, and nothing enforces it

A `CASE`, an `if/elif` chain, or any first-match dispatch that reports a *verdict*
carries an unwritten invariant: every serious arm precedes every advisory one. Adding
an arm is the natural edit; ranking it correctly is a judgement — so the invariant
breaks quietly, and the symptom is a real failure that is never printed.

It recurs one axis over, which is the tell that the class is wrong rather than the
instance. Measured across three rounds on one file (link#262):

| round | edit | result |
|---|---|---|
| 1 | added a NOTE arm under a FAIL | shadowed the FAIL two lines below it |
| 2 | partitioned FAILs above NOTEs, wrote the invariant in a comment | correct, briefly |
| 3 | added a *conditionally* sanctioned state into a FAIL slot | shadowed the same arm again |

The invariant was never "FAILs before NOTEs" but "every arm above the line is
**unconditionally** a failure" — which no comment reliably enforces.

**Accumulate instead of dispatching.** Report every condition that holds:

```sql
coalesce(nullif(concat_ws('; ',
  CASE WHEN <a> THEN 'FAIL: …' END,
  CASE WHEN <b> THEN 'FAIL: …' END,
  CASE WHEN <c> THEN 'NOTE: …' END), ''), 'OK')
```

`concat_ws` skips NULLs, so arm order changes only the order of the joined tokens.

Two checks worth making once you have one:

- **Enumerate how the accumulator itself could drop an arm** — a false condition, a
  NULL-valued condition, an empty-string arm, a NULL separator, a nested `CASE` with
  no `ELSE`. That set is small and finite, which is what makes "this class is closed"
  a measurement rather than a claim.
- **No arm labelled FAIL may exit 0.** Sweep every single-fault state and check the
  label against the exit status; a reported-but-unenforced FAIL trains people to
  ignore the word. Where a condition is deliberately advisory, label it NOTE.

### A link to a repo-hosted artifact must be *tracked*, not merely present

When the published site **is** the repository — GitHub Pages serving `docs/`, or a
`raw.githubusercontent.com` URL — the question "does this file exist" is the wrong
predicate. The right one is "is it in the repository", because that is what a reader
gets. A file written by a script and never `git add`ed exists for exactly one person:
whoever last ran the script.

The failure is invisible from the inside. The build succeeds, the page renders, the
link opens locally, and it 404s for everybody else. It surfaces only on a fresh clone
or a real visit.

```r
in_git <- repo_path %in% system2("git", "ls-files", stdout = TRUE)
```

Three instances in one project, each with a different cause and the same symptom:

- an interactive map written by a manual script, never committed — the appendix
  linking it 404'd on the published site for months
- 32 generated popup pages whose build script was in no build chain
- photo URLs built from the wrong id column, pointing at directories that had been
  renamed upstream

Note this is the *inverse* of the dirty-check case under "A guard that fails toward
pass" (the job writing into its own tracked output directory), where untracked
outputs are noise and `--untracked-files=no` is right. The distinction is whether the
repo is the input to a build or is itself the artifact being served. Both predicates
are correct for their own subject and wrong for the other.

**Corollary — the DOM is not the whole document.** Harvesting `href`/`src` with an
HTML parser misses anything a script tag reconstructs at runtime. A leaflet map
serialises its popups as JSON, so every link inside them is invisible to
`xml2::xml_find_all(doc, "//@href")`. A DOM-only pass over a report with 51 dead links
found 2. Scan the raw text as well, and be permissive about the shape: markup built by
`paste0('<a href =', x, '.html ', 'target="_blank">')` emits `href =…` with a space
and no quotes, which most href patterns skip. In PCRE, lookbehind must be fixed width,
so `(?<=href *= *)` will not compile — match the attribute name and strip it after.

Cheap enough to run on every build, and it belongs there rather than in a checklist: a
check that must be remembered has the same failure mode as the script that had to be
remembered.

### An assertion that matches an interpolated value cannot see the claim around it

`expect_error(f(x), "some_column")` looks like it pins the guard. It pins the
**field name**, which the message interpolates — so it matches whatever sentence
is built around that name, including a sentence that is false. The guard's
predicate is tested; the guard's *claim* is not, and nothing distinguishes the two
from a green suite.

The failure mode is a package asserting opposite things about one thing, in two
places, both with tests passing:

```
`sessions` is missing named_by, which is an override column.        <- guard A
`annotations` carries named_by, which is not an override.           <- guard B
```

Measured 2026-09-02 in trap#28. Guard A's predicate had been widened to cover
`named_by` and its sentence was left behind; guard B refuses `named_by`
*precisely for not being an override*, twenty lines above it. The test written
for that exact column asserted `expect_error(..., "named_by")` — a working guard
on the predicate, structurally blind to the sentence. It pointed a reader at the
remedy the other guard rejects.

**The tell is a message that says what something *is*, rather than only naming
it.** "which is an override column", "the layer was altered", "carried from the
capture source" are claims. `{.field {col}}` alone is not.

Where a guard's message makes a claim, assert the **rendered text**:

```r
render <- function(expr) tryCatch(expr, error = function(e) conditionMessage(e))

msg <- render(f(x))
expect_match(msg, "crew-supplied")                       # the claim, positively
expect_false(grepl("is an override|are override", msg))  # and the wrong one
```

Two notes on doing it well:

- **`conditionMessage()` on a `cli_abort` condition returns the bullets too**, not
  only the headline — so the `i` and `x` lines are reachable. Every assertion that
  matched only the first line was blind to them.
- **Prefer a positive `expect_match` over a negative `grepl`.** A negative catches
  the regression it was written for and is evaded by a rewording; the positive
  assertion beside it is the load-bearing one.
- **testthat makes this stable**: `local_reproducible_output()` sets
  `cli.condition_width = Inf`, so messages are emitted unwrapped and the
  assertions do not depend on console width or on how long `TMPDIR` is. Rendering
  the same message *outside* testthat wraps it and appears to fail — a false alarm
  worth recognising rather than debugging.

**Terminate by enumerating the messages, not by reading them.** Parse the file and
walk every `cli_abort` / `warning` / `stop`, dump the literals, and mark which
make a claim. That set is finite and small — six in the trap case — so "all of
them are pinned" becomes a measurement. Doing it from recollection is what left
the sixth unpinned, and the sixth was the false one.

### A pluralisation marker takes the quantity of whatever was substituted last

`cli`'s `{?a/b}` reads the most recent quantity in the string, and **any**
substitution resets it — including a length-1 one that is not what the marker is
about. So a `cli::qty()` at the head of a message is overridden by the first
`{.path {x}}` that follows it.

Worse, the two failure directions look identical when you only render one case:

```r
# n = 4 drifted columns
"{cli::qty(length(d))}{.path {p}} carr{?ies/y} {.field {d}}, which differ{?s/} ..."
#> '/x.gpkg' carries A, B, C, and D, which differ ...     <- qty reset by {.path}
"{.path {p}} {cli::qty(length(d))}carr{?ies/y} {.field {d}}, which differ{?s/} ..."
#> '/x.gpkg' carry A, B, C, and D, which differ ...       <- the FILE "carry"
```

**And markers in one sentence may legitimately have different subjects.** Above,
`carr{?ies/y}` is about the file — always one — and `differ{?s/}` is about the
columns. The original was correct and a "fix" made it wrong, because the two
halves were assumed to disagree when they were describing different nouns. The
right answer was to delete the `qty()` and write `carries` literally, letting
`{.field {d}}` supply the quantity for the markers that genuinely track it.

Caught 2026-09-02 in trap#28, and it cost two review rounds: one to introduce the
regression and one to find it. Neither was visible by reading.

- **Identify each marker's subject before touching a quantity.** If a marker is
  about something singular, no `qty()` is wanted at all.
- **Put `cli::qty(n)` immediately before the marker it governs**, never at the
  head of the string, when one is needed.
- **A quantity does not carry between bullets.** Each element of a `cli_abort()`
  vector is its own string, so a `{?it/them}` in an `i =` bullet has no quantity
  in scope even when the headline above it interpolated one — and this failure is
  loud rather than silent: `Cannot pluralize without a quantity` replaces the
  whole message, so the abort still fires and says nothing about what was wrong.
  Each bullet needs its own `qty()`. Caught 2026-09-03 in trap#32, in a refusal
  whose headline pluralised correctly two lines above.
- **Render at n = 1 and n = 2 through the real code path**, not through
  `cli::format_error()` on a hand-built string. A single-quantity test cannot see
  either direction, and a message rendered outside its function may substitute
  different values than the function does.

Also worth knowing: a length-1 **numeric** substitution sets the quantity to the
*number itself*, so `{cli::qty(length(x))}... {length(x)} item{?s}` is fine and
looks like the same defect. Do not "fix" it.

## Security

### Process Visibility
- Secrets passed as command-line args are visible in `ps aux`
- Use env files, stdin pipes, or temp files with `chmod 600` instead

### Secrets in Committed Files
- `.tfvars` must be gitignored (contains tokens, passwords)
- `.tfvars.example` should have all variables with empty/placeholder values
- Sensitive variables need `sensitive = true` in variables.tf

### Firewall Defaults
- `0.0.0.0/0` for SSH is world-open — document if intentional
- If access is gated by Tailscale, say so explicitly

### Credentials
- Passwords with special chars (`'`, `"`, `$`, `!`) break naive shell quoting
- `printf '%q'` escapes values for shell safety
- Temp files for secrets: create with `chmod 600`, delete after use

### Gitleaks pre-commit hook
Configuration patterns and false-positive handling for the `gitleaks` pre-commit hook (kdot's Brewfile ships `gitleaks` + `pre-commit`; cyclops standardizes the hook):
- **`.gitleaks.toml` schema in v8.30+**: top-level table is `[[allowlists]]` (PLURAL, array of tables). Each entry MUST include at least one of `commits` / `paths` / `regexes` / `stopwords`. The singular `[allowlist]` and `fingerprints = [...]` forms shown in older docs fail to validate. Use `paths` + `regexes` together for targeted file-and-content allowlists. Example in `soul/.gitleaks.toml`.
- **PEM marker regex spans multi-line**: gitleaks's `private-key` rule is `(?i)-----BEGIN...PRIVATE KEY-----[\s\S]*-----END...-----`. It matches across comment prefixes, blank lines, and code-fence boundaries. **Commenting out the markers does NOT neutralize the match.** Only fix in content is to omit the literal `-----BEGIN/END...-----` strings entirely and replace with prose ("Paste your private key here, preserving headers" etc.). See the `rtj` cypher `tfvars.example` precedent.
- **`curl-auth-header` rule false-positives on non-auth headers**: matches any `-H "X: Y"` shape, not just credential-bearing headers. Trips on docs with custom CORS or app-specific headers (e.g. `Zotero-Allowed-Request: true`). Fix: targeted `[[allowlists]]` with `paths` + `regexes`. Don't path-allowlist the whole file unless content is entirely safe.
- **`pre-commit install` legacy-hook handling**: running `pre-commit install` on a repo with an existing `.git/hooks/pre-commit` renames it to `.legacy` and keeps invoking it after framework hooks. No breakage, but means hook surface is split between `.pre-commit-config.yaml` and `.git/hooks/pre-commit.legacy`. For full visibility, migrate the legacy check into `.pre-commit-config.yaml` as a `local` hook so the whole hook surface is declared in one place.
- **AWS canonical example keys are allowlisted by default** (`AKIAIOSFODNN7EXAMPLE` etc.) — don't use those in test fixtures expecting a block. Use `ghp_`-shape PAT lookalikes or other non-allowlisted patterns for hook-trigger tests.

### "Public bucket" ≠ listable: GetObject vs ListBucket
- A bucket policy granting only `s3:GetObject` on `bucket/*` makes exact-key fetches public but NOT listing — and dataset discovery (`arrow::open_dataset()`, duckdb globs, STAC `/vsicurl/` directory reads) requires `s3:ListBucket` on the **bucket ARN** (no `/*`; it's a bucket-level action).
- The breakage hides: anyone with ANY ambient AWS credentials lists fine, so "anonymous access works" goes unverified for years. Caught 2026-07-18 (water-temp-bc#23 → rtj#187): anonymous `open_dataset()` had never worked on a bucket whose whole purpose was credential-less querying.
- Review checks: for an open-data bucket, the policy needs BOTH statements (GetObject on `bucket/*`, ListBucket on `bucket`); acceptance-test anonymous access from a credential-stripped environment (`env -u AWS_ACCESS_KEY_ID ... AWS_CONFIG_FILE=/dev/null`). Note ListBucket makes the full key listing publicly enumerable — intended for open data, wrong for mixed-content buckets.

## Spreadsheets and PDFs

### A stored value is not wrong just because the raw number looks wrong

Before reporting that a spreadsheet value is off by a factor, check the cell's
**number format**. A cell formatted `0.0%` multiplies by 100 for display: stored
`0.028` renders as `2.8%`. Reading raw values with `readxl` and comparing them against
what the column header implies will make correct data look 100x wrong.

- `tidyxl::xlsx_formats(path)$local$numFmt[cell$local_format_id]` gives the format.
- The header text is not the signal. A column headed `(%)` may legitimately store a
  proportion, because the format supplies the percent.

**Why:** this cost a full wrong turn in the fish data submission work — a formula
`AVERAGE(...)/100` was reported as a provincial template defect, a correction notice to
the ministry was drafted, and the "fix" would have shipped `280.0%` where `2.8%` was
meant. Caught only because a human opened the file and looked at it.

### Verify PDF links from the annotations, not the extracted text

`pdftotext` returns anchor text, not the href. A link whose anchor reads "here" leaves
no URL in the text layer, so grepping the text proves nothing either way. Extract the
annotation instead:

```bash
qpdf --qdf --object-streams=disable in.pdf - | strings | grep -oE 'https?://[^ )>]*'
```

`pdftotext` also splits ligatures — "fish" comes out as " sh" — so a grep for any term
containing `fi`, `fl` or `ffi` can report a false absence.

### Extracted PDF text carries corrupted glyphs, and a tolerant parser turns them into wrong numbers

Worse than the ligature case above, because it fails silently with a plausible value
rather than a missing match. Three shapes, all met in one set of 18 camera calibration
reports (fly#32, 2026-08-30):

| what the PDF renders | what it means | what a naive parser does |
|---|---|---|
| `2001Opixel` | 20010 | `gsub("[^0-9.]", "", x)` **deletes** the O and returns 2001 |
| `Pixel Size [<U+F06D>m]` | `[µm]` in a Symbol font | a literal `\[µm\]` misses; a human reading the extract sees `[m]` and takes **metres** |
| `Pixel Size  5.200 m` | 5.200 µm, sign dropped entirely | reads as metres — a factor of 10^6 |

The micron sign is the common one: U+F06D is a **Private Use Area** codepoint emitted by
Word-generated PDFs, so it is neither `µ` (U+00B5) nor `μ` (U+03BC) and matches neither.

Three habits:

- **Anchor on the label, not the unit.** Take the first number on the `Pixel Size` line
  rather than matching a unit that is written three different ways.
- **Never strip non-digits to "clean" a number.** That silently deletes a corrupted
  glyph instead of failing on it. Substitute deliberately (`[Oo]` preceded by a digit
  → `0`) and let an independent check prove the result.
- **Have an independent identity to check against.** These reports state pixel count,
  pixel size *and* image size in mm, so `px × pitch == mm` catches any one of the three
  being wrong — which is what made the O→0 substitution safe rather than reckless. Where
  the document states only two of the three, the check is vacuous; know which rows those
  are rather than counting them as passes.


# NGE Feature Workflow

For non-trivial issue-driven work, follow this checklist. Each step exists for a reason — skipping leads to rework, broken builds, and avoidable bugs that we've hit repeatedly.

## The Sequence

1. **Start with `/planning-init <N>`** — given an issue number, enters plan mode for codebase exploration, presents a phase breakdown for user approval, then scaffolds branch + PWF baseline with the approved phases. One command replaces the manual issue → explore → plan → branch → scaffold dance.
2. **Write robust tests first** — failing tests that reproduce the issue or document the new behavior. Tests are the contract; they fail until the work makes them pass.
3. **Name with intent** — functions, parameters, internal helpers carry the naming style of the package they live in. Look at existing exports as the guide; consistency over cleverness. For files rather than functions — shell scripts and operational R scripts under `scripts/` or `data-raw/` — the standard is the `noun_verb-detail` pattern in `newgraph.md`, noun first.
4. **Examples that run** — every exported function gets a runnable `@examples` block. Pkgdown renders them; CI executes them. An example that doesn't run is documentation rot.
5. **Code-check before each commit** — `/code-check` on staged diff. Catches what tests miss: edge cases, hard-coded paths, unguarded variables, security issues.
6. **Atomic commits** — each commit bundles code change + checkbox flip in `task_plan.md`. The diff and the progress live in the same commit; `git log -- planning/` tells the full story.
7. **`/planning-archive` when complete** — moves PWF to `archive/YYYY-MM-issue-N-slug/`, creates a fresh `active/`. Then `/gh-pr-push` opens the PR; `/gh-pr-merge` handles the release bookkeeping.

## Where the checkpoints are not

Step 1's plan approval is the authorization for every step after it. Run steps 2–7
through to the **open PR** without stopping to report between phases — the merge in
step 7 is outside the mandate unless the instruction includes it; put the decisions that
genuinely change what gets built at the plan gate, batched, with a recommendation
first; report once when the PR is open. The rule, its boundary (before a plan
exists, a question wants an answer) and its exceptions are `karpathy.md` §8.

## Re-read origin before you open the PR, not just before you cut the branch

Verifying local is current with origin (`code-check-shell.md`, "Before you *cut* a
branch") protects the branch point. It
says nothing about the build window, which is where a parallel session lands: measured
once, a second session filed, built and merged the same feature in 18 minutes, entirely
inside the first session's planning phase, and merged 15 seconds before its first
commit. Both sessions' pre-flight checks passed and both were correct when they ran; the
duplicate surfaced hours later as a version-bump conflict across eight files.

Before opening a PR, and again before merging:

```bash
git fetch -q origin
git log --oneline HEAD..origin/main          # what landed while you worked
git diff origin/main -- DESCRIPTION NEWS.md  # a version you did not bump
```

**A version bump you did not make is the tell**, and usually the only one — the tree is
clean, the branch is healthy, and nothing in git hints that someone solved your problem
an hour ago.

On a collision, do not resolve conflicts file by file. The merge conflict hides the
useful question, which is *which body of work survives*. Ask, then re-land the delta on
top of what shipped; two independent attempts at one problem are usually complementary
rather than redundant, and a mechanical resolution keeps whichever half git preferred.

## The version lives in one place

Do not restate the current version in `README.md` or `CLAUDE.md` prose. A version
string typed into prose drifts from the moment it is written — the release step
maintains `DESCRIPTION` and `NEWS.md`, and one report repo's
`CLAUDE.md` was found eight minor versions behind, its `README.md` one behind, with both
canonical files correct. Link to `NEWS.md` instead. Where a claim genuinely must stay in
prose, `/gh-pr-merge` step 7 greps for the previous version string outside the two
canonical files and updates the prose restatements it finds, reporting each.

## When to Skip

For one-line typo fixes, version-bump-only PRs, or trivial documentation edits, the full workflow is overhead. Use judgment. The threshold is roughly: **multi-step issue, multi-file change, or anything that requires scoping** → use the workflow.

## Skills That Slot In

- `/planning-init <N>` — start
- `/planning-update` — sync checkboxes mid-session
- `/code-check` — before every commit
- `/planning-archive` — when issue closes
- `/gh-pr-push` — open the PR
- `/gh-pr-merge` — merge with release bookkeeping

## Issue bodies get edited, not appended

When work changes what an issue should say, **edit the body**. Don't add a
comment that corrects it, and retitle when the scope moves.

**Why:** an issue is read as a spec by whoever picks it up. A body saying one
thing with a comment three screens down saying the opposite costs the reader the
reconciliation, every time.

**How to apply:** `gh issue view N --json body -q .body` into a file, revise,
`gh issue edit N --body-file`. Name what changed and why when the correction is
load-bearing — the goal is a body that reads correctly top to bottom, not an
erasure of history. Comments are for genuine commentary: a merge notice, a
cross-repo pointer, a question. Applies to PR bodies too. Commit messages are
immutable history and are never rewritten this way.

**The failure mode that keeps recurring: research findings feel like
commentary.** They are not — they are the spec. If a finding changes what
someone would *build*, it belongs in the body, with the durable version in
`research/` and the body linking to it.

**Bodies drift at the moment work finishes, not while it is in flight.** Four
instances in a single day of rfp work, all of the same shape — the code learned
something and the issue did not:

| drift | what a reader saw |
|---|---|
| premise disproved by measurement | an issue arguing for a fix that was no longer needed |
| a conclusion asserted in the body but never landed in code | body and tree contradicting each other |
| the shape of the work moved during exploration | a spec describing a design nobody built |
| a decision made and shipped, body still listing options A–D | "decision needed" on a decision a year old |

Vigilance does not catch this, because the drift happens exactly when attention
moves to the merge. `/gh-pr-merge` reconciles at that moment — see its step 3b.

## Why This Exists

We've hit snags repeatedly when half-doing this — branches that mix concerns, tests bolted on after, code-check skipped (and then a bug ships in the diff), examples that fail in pkgdown. Each step is small; the cumulative reliability gain is real. The convention is here so it becomes the default expectation, not a thing the user has to remind every session about.


# LLM Behavioral Guidelines

<!-- Source: https://github.com/forrestchang/andrej-karpathy-skills/main/CLAUDE.md -->
<!-- Last synced: 2026-02-06 -->
<!-- These principles are hardcoded locally. We do not curl at deploy time. -->
<!-- Periodically check the source for meaningful updates. -->

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. You Have No Clock Between Tool Calls

**Every duration claim comes from `date`, never from how much waiting felt like
it happened.**

Background `sleep` returns immediately from the agent's side, and the number of
times you have polled is not evidence of elapsed time. Two consecutive tool
calls can be 15 seconds apart by the clock while feeling like ten minutes of
waiting.

The failure is stating it out loud before checking. Observed 2026-08: a CI run
was reported to the user as "pending for over an hour — unusually long, probably
a stuck runner", after roughly eight background sleeps. One `date -u` showed the
run was **three minutes old** and entirely normal. The whole diagnosis — stuck
runner, duplicate triggers, something wrong with the workflow — rested on a
duration that had been invented.

**How to apply:** before saying *any* duration — "still running after N
minutes", "this has been X a while", "longer than usual" — run `date -u` and
subtract a real start time. `gh run list --json createdAt` gives it for CI. If a
claim about slowness would change what the user does next, it needs a measured
number or it does not get made.

The same rule covers process state. `ps` and task-status listings have both been
observed wrong; check the artifact (an output file's size, its mtime, the
service's own API) rather than the wrapper.

### The same blind spot picks the wrong waiting tool

Not having a clock also makes a **chain of background sleeps** feel like
waiting when it is not. Observed 2026-08 on the same session as the above:
roughly a dozen `sleep 570; check` background tasks were spawned to wait out a
55-minute test suite and then CI. Two consecutive foreground checks printed the
*same minute* — no wall time had passed between them, because the sleeps run
detached and the polling happened around them rather than after them. Every one
of those tasks was waste, and killing them produced a batch of eleven
exit-code-144 notifications that read like failures.

Pick the instrument by how many answers you need:

| you need | use |
|---|---|
| one notification when a condition becomes true | `Bash(run_in_background)` with an `until` loop that exits |
| one per state change, ending on its own | `Monitor` with a command that emits and then exits |
| a value you must have before the next step | a **foreground** call, so the blocking is explicit |

A repeated `sleep N; grep` is right in none of them. **Tell: if you are about to
spawn a second waiter for the same thing, the first one was the wrong shape.**

A `Monitor` filter must also match the failure states, not just the success
one — silence looks identical to "still running", so a watcher that greps only
for the happy path stays quiet through a crash.

### Don't edit files a long-running suite is still reading

`devtools::test()` and its equivalents load each test file **when they reach it**,
not at launch. A 30-minute run therefore reads whatever is on disk at that moment,
so edits made mid-run are half-applied and the result describes a tree that never
existed.

Cost two full Docker suites (~1 hour) on rfp#178, both reporting `FAIL 1`. The
failure was a test written *during* the run, executing against source from *before*
the fix that made it pass — nearly reported as a regression. **The tell is a moving
denominator:** 3490 passes, then 3496, then 3500, on "the same" tree.

Before a long run, commit. While it runs, do work that touches nothing it reads —
issue bodies, PR text, reading, planning. If an edit cannot wait, kill the run
rather than let it produce a result that has to be re-litigated. And when a long run
fails, get the `file:line` before forming any theory: a mid-flight edit and a real
regression look identical in a summary line.

## 6. Subagents Are Evidence, Not Dependencies

**Spawn on your own judgment. Don't block on one. Don't trust its status. Verify its claims in both directions.**

### Spawning is your call, not the user's

Deciding to spawn a subagent is an engineering judgment, the same kind as choosing
to write a test or run a grep. **Do not ask permission for it.**

The user is usually not positioned to answer. Knowing whether a fan-out beats a
sequential read requires knowing the shape of the work — which you have and they do
not, so the question forces them to guess at a technical call. Under **Always Away**
it is worse than useless: the work stalls until they wake up, for an answer that was
yours to make. *"I wouldn't be in the know enough to know when that is"*
(airvine, 2026-08-27) is the whole problem in one line.

This does not soften §1's asks — *"if uncertain, ask"* and *"if something is unclear,
stop and ask"*. Those are about **what the user wants**: intent, scope, an ambiguous
requirement, a tradeoff only they can weigh. This is about **how you carry it out**.
Ask about intent; decide about mechanism. A question starting "should I use…" is
almost always the second kind, and almost always yours to answer.

#### Standing authorization: the harness bars the Agent tool by default on Opus 5

Sessions on Opus 5 carry a hardcoded instruction from the CLI itself —
*"Do not call the AgentTool unless the user requested it"* — alongside the same
line for workflows and deep-research. It is not a setting anyone here
misconfigured, and it cannot be turned off locally: measured 2026-08-29 in
`claude` v2.1.251, the string is a literal in the bundle, emitted when the
session is on the `opus_5_prompt_bundle` and the server-side flag
`tengu_fennel_godwit` is off. That flag and the replacement text
(`tengu_heron_brook`) are both remote config; nothing in `~/.claude/settings.json`
reaches them.

The symptom is a skill quietly doing less than it says: `/code-check` reporting
*"the subagent rounds did not run — your session instruction bars the Agent
tool"*, which is the review the command exists to perform. It reads as a
configuration problem, so the fix gets looked for in the wrong place.

**The clause is conditional, so this convention is the request.** Invoking a
skill that mandates subagents — `/code-check`'s three rounds, the Plan review in
`planning.md` — **is** the user requesting them. Spawn them. This paragraph is a
standing user instruction, written for exactly that purpose (airvine,
2026-08-29), and CLAUDE.md project instructions override default behaviour by
their own terms.

It authorizes the mandated spawns and nothing wider: the bounds in this section
still hold — two or three concurrent, about five per task, no fan-out from a
child — and a workflow or deep-research run fanning out dozens of agents remains
a spending decision that needs an explicit ask.

**Spawn without asking when:**

- A skill or convention mandates it — `/code-check`'s review rounds, the Plan review
  in `planning.md`. That decision is already made; re-asking it is friction carrying
  no information.
- You want fresh eyes on your own work. The mechanism and the measurements behind it
  are in `code-check/SKILL.md`.
- A sweep over many files will **locate** what matters faster than reading serially.
  The sweep finds candidates; it does not replace the read — `planning.md` is
  explicit that agents sometimes report existing files as absent, so read directly
  whatever you are going to act on.
- Independent items can run concurrently and nothing downstream needs them ordered.

**Do it yourself when:**

- One grep answers it.
- The work depends on conversation context a subagent will not have.
- You would sit idle waiting — spawn and keep working, or do it inline.

**Bounds and defaults you enforce yourself, rather than converting into questions:**

- **Two or three concurrent is the working default, and about five per task** is
  where spend stops being incidental. Concurrency and cumulative total are different
  quantities — `/code-check`'s three rounds plus a Plan review plus an ad-hoc sweep
  never exceeds three at once while spending well past a handful. Bound both.
- Past that total, **say so in your next message.** An escape you grant yourself
  silently is not a bound; it has to land in front of the user, after the fact.
- **Do not let a subagent fan out again.** Intent does not enforce this — the child
  decides what it calls — so use the structure: the `Explore` and `Plan` types are
  defined without the `Agent` tool and *cannot* spawn. `general-purpose` can, so when
  you use it (as `/code-check` does), put "do not spawn subagents" in the prompt. The
  one case on record — a research agent that had spawned 5 children and deadlocked
  for **~3 hours** while still reporting as running (below) — never had a root cause
  established, which is exactly why this bound is structural rather than advisory.
- Unnamed, delivering by file — `planning.md` carries the mechanics.
- **Report after, not before.** Say what you spawned, and relay what it found (per
  `code-check/SKILL.md` — a subagent's report never reaches the user on its own). A
  user can object to a spawn that already happened; they cannot usefully approve one
  that has not.

**What is genuinely the user's call is budget, not mechanism.** A workflow or
deep-research run fanning out dozens of agents is a spending decision and needs an
explicit ask. Two or three reviewers is not — that is just doing the work.

Worth being concrete about the value, because the cost is the visible half and the
benefit is not: on 2026-08-27 two reviewers over one conventions draft returned
**20 findings**, caught **six** false factual claims in it, and killed a section that
would otherwise have shipped contradicting `code-check.md`. None of that review
happens if the spawn waits on a user who is away.

### Don't block

Spawn a background subagent, then keep working on the lowest-risk part of the
task — scaffolding, data files, tests. When findings arrive, treat them as a
review of landed work rather than a precondition for starting it.

If a result genuinely must precede the next step, run it synchronously
(`run_in_background: false`) so the blocking is explicit and visible.

Three observed cases where waiting would have been the expensive choice:

- A research agent spawned 5 children and deadlocked for **~3 hours**, still
  reporting as "running". The user caught it, not the agent.
- A `Plan` agent asked to review a `task_plan.md` *before the baseline commit*
  returned after the issue was implemented, reviewed, merged and tagged.
- The same pattern on a later issue: findings arrived after all four phases had
  shipped. Because the work had not waited, this cost nothing — three findings
  were still new and landed as follow-up commits.

That last one is the shape to aim for. Concurrent review is not a degraded
version of blocking review; it is often better, because the reviewer reads real
code instead of a plan.

### Don't trust status

**Never report an agent as "still running" without evidence.** Agent status and
`TaskList` have both been observed to be wrong — `TaskList` reported "No tasks
found" for an agent that was alive and later replied. Check the output file's
mtime before claiming progress, and say what you checked.

**And never record a review as "Clean" on the strength of an idle notification.**
From the parent's side an idle ping is indistinguishable from an agent that had
nothing to say, so a lost review reads as a pass — a whole `/code-check` pass was once
reported as finding nothing while three reviews were stranded, one of which had found
a data-loss bug (measured 2026-08-25; the numbers are in `planning.md`, "Spawn review
agents UNNAMED"). Passing `name` turns a spawn into a persistent teammate that idles
instead of completing; pass it only for a collaborator you will keep messaging, and
shut it down when done. The rule that survives either spawn shape:
the reviewer **writes its findings to a file and reports only the path**, and a
missing or empty file means the round produced nothing and is re-run — never
"Clean". `planning.md` carries the mechanics; `code-check/SKILL.md` applies them.

### Verify claims, in both directions

Subagent output is evidence, not verdict. Both failure modes are real:

- **Acting on a wrong finding.** One labelled BLOCKER — "`glue()` will choke on
  the literal braces in this fragment" — was disproved by a 30-second probe,
  because glue does not re-parse interpolated values. Acting on it would have
  meant rewriting a working generator.
- **Dismissing a late review wholesale.** In that same review 2 of 9 findings
  were real, including a dead link. In a later one, a finding that a
  `path|layername=` check would delete KML/GPX layers was correct, and was
  confirmed against 207 real datasources before the fix landed.

The rule that separates them: **cheap probe first, then act.** Reproduce the
claim before you fix it, and before you dismiss it. A finding you cannot
reproduce is a finding you do not yet understand.

### Fan out inside one process

A workflow that shells out **once per item** costs one permission prompt per item,
unless the command happens to be allowlisted. The same work done **inside one
process** costs one prompt total, and nothing says so until the run is already
going. Measured 2026-09-04 (knowledge#4): a harvest script issuing two `curl` calls
per report inside each subagent meant hundreds of approvals across a run — the user
had flagged it as *"a big time suck last time"* without knowing the cause — while a
sibling script doing the same fetch-download-upload work with Python `urllib` in a
single process cost **one** prompt for the entire run. Same task, same volume, three
orders of magnitude apart in interruptions.

It breaks **Always Away** directly: an unattended run that stops for approval on item
3 of 200 has not failed loudly, it has gone idle, and the wrapper reports nothing.

- **Prefer one process doing N items over N processes doing one.** Loop inside the
  language runtime; shell out once, for the batch.
- Where a per-item subprocess is genuinely required, allowlist its command **before**
  the run, not one refusal at a time during it — the allowlist fixes the commands you
  predicted, and the one that blocks is the one you did not.
- Diagnostic: if a run keeps stopping for approval, look at whether the loop sits
  inside or outside the process boundary before adding allowlist entries.


## 7. Evidence, Not Impressions

**Measure before you characterise. Presence is not provenance. "Unknowable" is a
claim.**

Six principles that all fail the same way: something *feels* established — because
it is visible, because it is present, because someone said so — and gets offered
with the confidence of a measurement.

### Measure before you characterise

When a decision turns on **what something contains**, open it and count. Do not
describe it from its structure, from an issue's claim about it, or from a tag list.
A heading tells you a thing is *present*, never that it is *populated* — an empty
`<conditionalstyles/>` and one with rules look identical in a list of child names.

Four instances in one rfp session, each corrected by the user's follow-up question
rather than by review: a tradeoff described as three times its real size; an issue's
stale claim repeated as current; an installed version reported as sixteen releases
behind when a parallel session had updated it eighteen minutes earlier; and "nothing
on main addresses this" from a local `main` three commits behind — one `git fetch`
away from the truth.

**A measurement carries the time it was taken.** One made earlier in the same
session is not a current one, least of all for anything another session can change
underneath it. For anything git-backed, `git fetch` first: reading a local clone and
reporting it as the state of the world is the same error with a longer fuse.

**And before hand-rolling a parser for a probe, check whether the code already has
one.** A bespoke parser silently narrows the population it can see, and the result
looks like a measurement rather than a sample — worse than not measuring, because it
carries a number. Measured 10 of 80 with a hand-written matcher; routed through the
package's own resolver it was 14 of 117.

### Presence is not provenance

When something's **presence** is offered as evidence for **how it got there**, find
the fact that actually discriminates. A QGIS project's `3.30.1` stamp was offered as
evidence a desktop had opened it — but the template it was copied from carries that
stamp, so a never-opened project reads the same. What actually proved it was a
tracking key the template does not contain.

The tell: reaching for the *most visible* fact rather than the *discriminating* one,
because the visible fact is consistent with the conclusion. **Consistency is not
support.** Before offering "X shows Y", ask what else would produce X. If anything
would, X is not evidence.

When the user pushes back on an inference, re-derive rather than defend. The
conclusion often survives; the reasoning that reaches it is usually different.

### Documents that share an ancestor corroborate nothing

Sibling of the rule above, one level out: there a *fact* was consistent with the
conclusion, here several *documents* are. Finding the same claim in three places
feels like triangulation and is not — if one was written from another, they are one
source wearing three hats, and the agreement is a copy, not a confirmation.

**The tell is agreement with no independent derivation.** Ask of each restatement:
what did its author read? If the answer is "one of the others", the count is one.
Prose repeats; code does not, so the discriminating check is almost always to read
the thing the prose describes.

**The release note is where this costs the most, because its readers cannot check it.**
Measured 2026-09-04 in stac_floodplains_bc#26: three claims in one set of release notes were
wrong, each restated from a prior document rather than derived from the artifact — "18 items
changed" (the count of upstream *re-runs*, six of which moved nothing; 13 changed), "5-33%"
(the issue's own summary line, contradicted by its own per-item table; 1.5-33.5%), and worst,
*"the correction is visible in the checksums, so a consumer can tell replaced data from
unchanged"*. That last one measured **140 assets across 20 items, zero unchanged** — the
re-encoding touched every byte, so the checksum answers "are my bytes current" and can never
answer "did the values change". It would have sent every consumer to a signal that cannot
answer the question they have.

Two habits, both cheap:

- **Derive every number in a release note from the artifact it describes**, at the moment you
  write it. Not from the issue, not from the last release's notes, not from memory.
- **For any sentence of the form "you can tell X by looking at Y", check that Y actually
  separates X from not-X.** A discriminator that fires on everything discriminates nothing,
  and it reads as helpful right up until someone relies on it.
- **A carve-out is a number too, and reasoning one from the shape of a literal understates
  it.** A release note recording someone else's regression said a broken smoke test "could
  validate any group except the two named in `EXPECTED_DEPRECATED`" — reasoned from the
  literal being the thing the check consults. Driven over one-group trees it could validate
  **none**: the literal names two items, so a one-group tree is always missing at least one,
  including each of those two, which are missing each other. Wrong in the direction that
  understates the reach of a defect, in the document a reader uses to decide whether to
  backport. Run the check over the population before writing the exception
  (stac_floodplains_bc#61, 2026-09-05).

Measured 2026-09-02 in link. `CLAUDE.md`, `research/study_area_run.md` and
`research/recompute_parallel_2026_09_01.md` all stated that a post-consolidate
recompute "runs over every WSG in the schema, not the run's own set, so it does not
scale with scope". One line of shell disagreed — `ALL_WSGS` is the union of the host
buckets — and the run's own log said `recompute (lnk_access, 34 WSGs)` against a
95-WSG schema. Two later commits had changed the behaviour and none of the three
documents was updated.

It was quoted to the user twice in one session as a live planning input before anyone
checked, and it was load-bearing: the claim was the *premise* for concluding that
parallelising that stage beat adding machines. A false premise had produced a
plausible roadmap.

Two habits:

- **When a document states a quantity or a scope, read the code that produces it
  before repeating it.** Especially a status section — it describes a moment, and
  nothing fails when the moment passes.
- **When you find one instance stale, grep for the sentence, not the file.** The
  claim above sat in three documents; fixing the one that was quoted would have left
  two, both reading as authoritative.

### "It can only be answered by testing" is a claim with an author

An issue or a colleague saying a question needs a field season, a device or a deploy
is stating a claim, not a property of the problem. Spend the cheap probe first.

rfp#186 opened with "three questions decide whether this is viable, and none can be
answered by reading." Two fell in about twenty minutes — one to reading a call
graph, one to re-reading a file already on disk — turning "run a field season, then
decide what to build" into "build it, then confirm one thing."

The claim is usually made by someone who knows the domain, at a moment before they
looked. Not wrong so much as **unexamined**, which is what lets it survive into the
plan. Then **bound what the probe closed**: reading a desktop plugin says nothing
about the mobile app. An over-claimed probe is worse than none.

### A real bug is not necessarily the reported bug

A defect found while investigating a symptom is **evidence, not the answer**. Before
offering it as the cause, check that it produces *exactly* the symptom described,
including the details that sound incidental.

Two confident wrong causes in a row on rfp#196 — a layer missing from a map theme
(a real bug, fixed) and a sub-pixel geometry (a real measurement). Both true;
neither explained the report. The actual cause was draw order, and the user named it
himself. The discriminating fact was in his words all along: *"as soon as I stop
tracking I can't see the track"* rules out both theories in one line.

Finding a genuine defect feels like finding *the* defect — the relief of having an
explanation is what stops the check. Write the reported symptom out and ask whether
the proposed cause produces **all** of it. Say which parts are still unexplained:
"this is a real bug and it may not be your bug" is honest and cheap.

### An enumeration is not a checklist

A probe listing what exists — subkeys present, columns found, files listed — answers
"what is here", never "what do we want". Scope arriving this way looks
evidence-backed, so it survives review.

On rfp#68, "the two Mergin subkeys that exist" became "the settings to verify",
then an item on a field checklist a human had to walk outdoors to complete. Nothing
in the codebase read or wrote `PhotoNaming`. Before a probe's output becomes work,
grep for each item and ask whether anything consumes it. When it duplicates
something already done another way, name the comparison — the existing approach
usually wins for a reason worth stating.


### A relative descriptor is meaningless without its anchor

"Upstream", "downstream", "above", "below", "before", "after", "parent" — each is
relative to something named **elsewhere in the document**, often paragraphs away and
sometimes only in a table. Resolve the anchor before drawing any inference from the
term.

Getting it wrong does not produce uncertainty, it produces a confident and specific
wrong answer — and it fails in the worst direction, because you now believe you have
*evidence* against a claim rather than merely lacking evidence for it.

Measured 2026-09-02. A field report read *"downstream sampling confirmed the presence
of coho"*. Taken as downstream of the crossing under discussion, it appeared to
disprove the user's recollection that coho were present above that crossing. The
sampling site was actually at a road crossing 1.5 km further up the stream, so its
"downstream" was still **1.1 km above** the crossing in question — the claim was true
and the correction nearly removed it from an email to the infrastructure owner, on the
one point the email existed to make.

**Where a source describes a sequence — crossings on a stream, releases in a
changelog, stages in a pipeline, commits on a branch — write the order out before
interpreting a single relative term in it.** The ordering is usually one sentence in
the source and takes seconds to find; the inference built on the wrong anchor survives
every later check, because nothing downstream re-examines it.


### A safeguard whose mechanism is a human reading a diff is not a control

When a design says "the writes are uncommitted, so the diff is the review", check
whether anyone reads diffs. Here nobody does — the user says "commit" without opening
one, stated plainly and confirmed 2026-08-28 — so every per-action confirmation loop
built on that premise was latency wearing the costume of a control. Two skills had one.

Gate on **blast radius** instead, because that fires without anyone reading anything: a
write that reaches one repo just happens; a write that reaches every repo (a soul
convention) may be appended to freely but edited or removed only through an issue. Where
a real check is needed, make it mechanical — a grep for a contradicting rule, an
assertion that nothing above the `CLAUDE.md` marker moved, a guard that resolves every
heading against a base SHA. Those are the controls; a prompt is not.

The user still wants a short, honest account of what was written. That is a report, not a
review, and confusing the two is how the loops got built.

### Not finding it is not evidence it does not exist

Before building a fetcher, harvester, backup or sourcing routine, **search the sibling
packages for the verb**. One command, and it is the difference between adding a function
and adding a second copy of one.

```bash
# Enumerate the org's installed packages rather than listing them: a hardcoded list
# named four packages; thirteen other org packages were installed on the machine this
# was measured on (2026-09-05), and the gap will grow again. Match
# on any URL-ish field, case-insensitively: RemoteUsername is set only by GitHub
# installs (a package installed from a local checkout has none) and the org name is
# not always cased the same. Forks of upstream packages come along; that is fine.
# `collapse` matters: paste() over fields that are all NULL is character(0), and
# `if` on a zero-length grepl() aborts the whole enumeration (measured, soul#171).
for p in $(Rscript -e 'for (p in rownames(installed.packages())) {
  d <- packageDescription(p)
  u <- paste(c(d$URL, d$BugReports, d$RemoteUrl, d$RemoteUsername), collapse = " ")
  if (grepl("newgraphenvironment", u, ignore.case = TRUE)) cat(p, "\n") }'); do
  echo "== $p"; grep -E "^export" "$(Rscript -e "cat(system.file(package='$p'))")/NAMESPACE" \
    | grep -iE "source|fetch|harvest|backup|manifest|download|ingest|store|snapshot|read|write|conform"
done
ls ~/Projects/repo/rtj/scripts/gis/     # operational drivers live here, not in a package
```

**Then read the README ownership table and the above-marker `CLAUDE.md` of any package
plausibly adjacent — exports understate remit.** `trap`'s README states it exists "so a
report does not have to harvest its own copy", with a manifest pinning per-snapshot
sources, schema, md5 and row count; no export says that. The old hardcoded list would
not have searched it at all; the grep finds functions; the README is the load-bearing
artifact. Measured 2026-09-04: a harvest-and-manifest layer was
proposed across three issues before `trap/README.md` was opened, with `trap` checked out
and current on the machine (soul#183).

The failure is not carelessness — it is that **a decision is invisible from where the work
is happening**. The tool exists, is correct, and is three repos away in a directory you had
no reason to open. So the path of least resistance builds it again, and the duplicate is
plausible precisely because the original was never visible.

Four instances in one session (2026-08/09), all by an agent that had just read the thread
documenting the pattern:

| Built or proposed | Already existed |
|---|---|
| a Mergin form-harvest script | `rtj/scripts/gis/mergin_data-harvest.R` — dry-run by default, parquet, photo manifest, excludes `.mergin/` cache copies |
| ad-hoc project layer curation | `rtj/scripts/gis/mergin_manifest-create.R` + per-project manifests git-tracked in rtj |
| "photo functions should go to ngr" | `sred#26` assigns photo batch ops to rfp |
| "the source fetchers should go to ngr" | `spacehakr` already existed, holding all twelve `spk_*` |

**Tell:** you are about to write something whose name is a verb the ecosystem already does
somewhere. Fetch, sync, harvest, backup, source, register, publish.

Two corollaries worth holding:

- **A function existing in two places is worse than it existing in neither.** Measured on
  `ngr_spk_geoserv_dlv` versus `spacehakr::spk_geoserv_dlv`: same name, same signature, and
  by the time anyone looked the first printed an error and carried on where the second
  aborts. Two live copies drift silently, and the drift is invisible until someone has both
  installed — which nobody did.
- **Check what the *architecture* says, not just what exists.** Two of the four above were
  wrong-home *proposals*, not duplicate code. `sred#26` had already assigned the boundary;
  reading it would have cost less than arguing the case from first principles.

Sibling of *"An inventory is only complete relative to a boundary"* in `code-check.md`, one
step earlier: that one is about a search that was complete for the wrong scope, this is
about never having searched the scope where the answer lived.

#### The storage version: one store is not the world

The same error with buckets instead of packages, and it produced three wrong answers in
one session (2026-09-04). Each was a single negative check reported as a fact:

| claim made | what was checked | where it actually was |
|---|---|---|
| "not an `aws` layer" | `rfp_source_aws.txt`, 11 entries | `db_newgraph/jobs/` — that list is what rfp *pulls*, not an inventory of what is staged |
| "not staged anywhere" | one Postgres host, one S3 prefix | a **different bucket**, written by a job that drops its temp table afterwards |
| "the imagery is not backed up" | `aws s3 ls` on two AWS buckets | **DigitalOcean Spaces** — 228 GB, reachable only via `s3cmd` |

The third is the most general: **`aws s3` and `s3cmd` address different clouds and are
invisible to each other.** A repo whose backup script uses `s3cmd` has stores that no
`aws s3 ls` will ever list, so "I checked S3" is not a statement about where the data is.

Two habits, each one command:

- **Enumerate the stores before searching them.** `s3cmd ls` and `aws s3 ls` with no
  argument each list only their own provider's buckets; the backup script names the rest.
- **Prefer the definition to the artifact.** The job that stages data says what exists; a
  bucket only shows what some past run happened to leave. Checking artifacts returned
  nothing three times here; reading the job answered it immediately.

A negative result is only ever as wide as the store you looked in. Stating it without that
qualifier is how a gap in your own search becomes a fact in an issue body — which is where
all three of these ended up before they were corrected.

And the same shape once more for **checkouts**: a `grep` across `~/Projects/repo` searches
the repos this machine happens to have, not the ecosystem. Repos are cloned per-machine and
the set differs between them — `stewardship_upper_wedzin_kwa` was absent on m4 while holding
the answer to two separate questions on 2026-09-04, so a local grep returned clean twice and
was reported as absence twice. Use `gh api -X GET search/code -f q="org:NewGraphEnvironment <term>"`,
and note it indexes **default branches only**, so a file on a feature branch is invisible to it
and needs `gh api repos/<owner>/<repo>/contents/<path>?ref=<branch>`.

## 8. Decisions Up Front, Then Run

**Ask at the plan gate. After approval, run to the PR. Before a plan exists, a question wants an answer.**

The first three subsections are one rule on one axis — *when* to come back to the
user — and they are only correct as a set; each was learned separately in a different
repo and re-derived, usually by getting one of them wrong first. The rest are
handover rules that belong beside them because they decide what the user is handed
when you do come back.

### After plan approval, run every phase to the PR

Plan approval is the authorization for every mechanical step after it. Run every
phase, commit atomically per phase, archive the PWF, push, open the PR, and report
**once**, at the end. Do not stop between phases to report progress: the decisions
that needed the user were taken at the gate, and a check-in that only reports
spends attention already committed. Under **Always Away** the cautious answer is the
wrong one — the work stalls on a question the user answered by approving the plan.

The instruction arrives as one short message covering many commits, reviews and
repos: *"Go all phases to PR"* (airvine, flooded#49, 2026-08-31; flooded#47 and
floodplains#33, 2026-09-01; trap, 2026-09-01; soul#169, 2026-09-04). One of those
runs carried four phases, a plan review, four code-check rounds, two issue-body
reconciliations and two cross-repo PRs with no further input. The merge is a separate
instruction: on soul#188 the user typed `/gh-pr-merge` once the PR was open, and asked
directly (2026-09-05) confirmed that *"to PR"* ends there.

Two things are inside the mandate; these are not:

- **Correcting the plan is inside it.** A review that disproves an approved design
  decision gets fixed mid-run and reported in the summary; that is the run working,
  not a reason to stop — unless the correction is itself a fork of the kind below (a
  key, an identifier, a schema), which goes back to the user. Blockers that cannot be resolved are filed as issues and
  named in the final report rather than held open.
- **Our own repos are inside it.** Filing issues, opening PRs and editing bodies in
  NGE repos is normal work; one run produced a follow-up issue and two cross-repo PRs
  without asking, and that was right.
- **Outward-facing actions are not** — see "Never post outside our own repos" below.
  Neither is anything a convention names as its own gate: **the merge** — *to the PR*
  ends at the open PR; `/gh-pr-merge` runs when the user invokes it or the instruction
  says so (airvine, 2026-09-05; `gh-pr-push/SKILL.md`, "Ask user before merging") — a change to the machine
  (`newgraph.md`, "State the plan before changing the machine"), or a push into an
  artifact a human is testing on (`code-check.md`). A push to the feature branch is
  inside the mandate.

### Before a plan exists, a question wants an answer

The same terseness that means "go" after approval means "answer me" before it. A
turn that ends in a question mark, with no approved plan, gets an answer and a
one-line offer of the work — not the first commit toward it. Twice in one day
(floodplains, 2026-09-02) a question was read as approval and editing started — once
after *"why not fix before publish?"*, and once after a gap had been explained, stopped
with *"do not take on 70. i want to understand"*. When the ask is to understand something, keep it short and concrete; a
worked example beats a taxonomy. *"small answers here"*, *"keep it short"* (airvine).

This is the boundary condition on the rule above, which is why they are one section:
a standing mandate to run autonomously, stated alone, is exactly what reads every
terse message as "go". **The mandate starts at plan approval.**

### What still interrupts, and where it goes

A decision that permanently shapes stored data — a key, an identifier, a schema
choice, a deprecation shim versus a hard rename — is the user's, and it goes to the
**plan gate**, batched, as two or three concrete options with the recommended one
first and the consequence stated. Two such forks put at one gate (flooded#47) were
both load-bearing and neither was derivable from the issue: the rename would also
have broken a production driver in another repo, which only the sweep surfaced.
Asked at the gate a fork costs one round-trip and buys the whole run; discovered
mid-execution it costs a stall with nobody there to answer it. Found mid-run, it is
still not the agent's to decide: ask it the same way — options, recommendation first,
phone-answerable — commit, and continue on the phases that do not depend on it while
the answer is outstanding (`planning.md`, "When Something Keeps Failing" — escalating
is not stopping).

During plan-mode exploration, keep a list of "this changes what I build" forks and
ask them together before `ExitPlanMode`. Questions are welcome; status updates are
not. Mechanism — whether to spawn reviewers, which regex, how to build a fixture — is
never a question (§6, "Spawning is your call"), and anything with a conventional
default is not one either: pick it, say so, move on.

### Never post outside our own repos without approval

Never post to a venue outside NGE's own repositories without the user's explicit
approval for that specific post — upstream GitHub issues and PR comments, mailing
lists, forums, third-party trackers. **Drafting is welcome and expected**: write the
comment, show it, wait. It is the sending that needs the word. *"Never post things
upstream without my explicit approval"* (airvine, 2026-09-02, after an offer to draft
comments on two of a vendor's upstream issues).

**Why:** an upstream comment is published under the organisation's name to a venue we
do not control, is indexed immediately, and cannot be unpublished. It is a
communications act, not an engineering one, and the judgement about tone, timing and
what we are willing to say in public is the user's.

- Our own repos are unaffected; filing and editing issues there is the standing
  disposition and needs no asking.
- **Reading upstream is unrestricted and worth doing.** Checking issue state before
  filing ours has caught a wrong citation in our own roxygen and found an upstream
  issue already proposing the feature we were about to request.
- Offer the draft in the reply, not as a fait accompli, and say plainly that nothing
  has been posted when the work obviously produced something postable.

### Hand the user bare commands

When the user must run a command themselves — an interactive login, a
sudo-needs-TTY operation, anything the Bash tool is blocked from running — give the
**bare command**, in a fenced block, ready to paste. Never prefix it with `!`.
*"Give me the cmd without the ! - that never works btw"* (airvine, 2026-08-21);
*"stop giving me the ! at the start. that doesn't work. i need the raw cmd"* (`cd`, 2026-08).

**Why, twice over.** Default session guidance proposes the `!` prefix as a way to run
a command in-session, so this recurs in every repo unless written down. On this
operator's terminals it either does not run at all, or — where it does — **it ran from
`$HOME` rather than the session's working directory** (one measurement, 2026-09-02): a
handed-over `! mkdir -p pursuits/x && cp … pursuits/x/` created `~/pursuits/x` and the
file had to be found and moved. Absolute paths are right whichever directory it
resolves against. So:

- Emit the command plain. Applies to fenced blocks and inline commands alike.
- **Absolute paths** in any handed-over command that touches files
  (`~/Projects/repo/<repo>/…`), whichever form the user ends up running it in.
- Keep it paste-safe: prefer `grep`/`awk` over a nested `python3 -c "…"` inside a
  single-quoted remote command, so the quoting survives the trip.

**A file under `~/Downloads` is unreadable by the agent process, and no retry helps.**
`Read`, `cp` and `pdftotext` on `~/Downloads/*` all fail with `Operation not permitted`
(measured 2026-09-02). It is macOS folder protection (TCC) on the process, not a
Claude Code permission mode, so `/permissions` does not change it; Desktop and
Documents behave the same. Do not retry variants — ask for **one** copy into the repo,
with absolute source and destination paths, then continue from the copy. (Granting
the terminal app Full Disk Access removes it on one machine; the fallback stays for
the next machine.)

### Link every issue and PR you name to the user

When a message to the user names an issue or a PR, make the number a link the user can
click: `[soul#191](https://github.com/NewGraphEnvironment/soul/issues/191)`,
`[soul PR #192](https://github.com/NewGraphEnvironment/soul/pull/192)`. Terminal output
renders markdown, so a bare `#191` costs the user a browser, a repo, and a click through
several pages to learn what it was — for every number in a report that may carry a
dozen. *"want to be able to follow up without opening new browser and clicking through
mult pages to find"* (airvine, 2026-09-05).

- **Issues under `/issues/N`, pull requests under `/pull/N`.** They are different paths,
  and the type is not always obvious from a number. When unsure, ask `gh` rather than
  guess — it returns the canonical URL for either:
  ```bash
  gh issue view 192 --repo NewGraphEnvironment/soul --json url -q .url \
    || gh pr view 192 --repo NewGraphEnvironment/soul --json url -q .url
  ```
- **Cross-repo references carry the repo**: `rfp#268`, never a bare `#268` from inside
  soul.
- **Spot-check a subset, not every link.** Before sending a report with many numbers,
  resolve two or three through `gh` — the ones you typed from memory or whose type you
  inferred — and let the rest ride. Checking all of them would slow every message; checking
  none is how a wrong repo or an issue-path link to a PR ships. Measured 2026-09-05: three
  constructed links checked against `gh`, two matched, one was a PR filed under the issue
  path.
- **Scope is messages to the user** — terminal replies, the compact-prep report, PR and
  issue bodies where a reader lands from outside the repo. Commit messages and issue bodies
  read *on* GitHub autolink `#N` already; do not bloat those.

### Surface upstream defects; do not work around them

When a dependency or an external API misbehaves, surface it and ask rather than
coding around it. *"dont' do workarounds for things like zotero api problems. surface
and ask as there may be simple solution"* (airvine, 2026-09-03).

**Why:** a workaround hides the defect from whoever could fix it properly, and the user
often has upstream context or a simple fix the session lacks. Most of the dependencies
in question are **first-party** — an upstream bug is usually ours — so a local patch
is strictly worse than an issue: it leaves the bug in place for every other consumer
while making this repo look fine. Same instinct as `newgraph.md`'s "install missing
packages, don't workaround", applied to a *broken* dependency rather than a *missing*
one.

**How to apply:** reproduce it minimally, file an issue in the owning repo with the
repro and the exact lines, report it, and carry on if it is not blocking. The rule is
*do not hide it*, not *do not continue*: the day it was recorded, a search function
failed on a list column and broke a documented pipeline step; the local guard would
have taken minutes and hidden a bug affecting every consumer, so it was filed with a
three-line repro and the pipeline continued, since its data path did not use search.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


# Planning Conventions

How Claude manages structured planning for complex tasks using planning-with-files (PWF).

## When to Plan

Use PWF when a task has multiple phases, requires research, or involves more than ~5 tool calls. Triggers:
- User says "let's plan this", "plan mode", "use planning", or invokes `/planning-init`
- Complex issue work begins (multi-step, uncertain approach)
- Claude judges the task warrants structured tracking

Skip planning for single-file edits, quick fixes, or tasks with obvious next steps.

## The Workflow

1. **Explore first** — Enter plan mode (read-only). Read code, trace paths, understand the problem before proposing anything. When the work codifies a pattern that already exists in multiple places (reference implementations across repos), read **every** reference in full, not just the canonical one — variation across references surfaces patches before v0.1 instead of as churn later (soul#52: reading all 4 references preempted 5 of the 7 fixes a dry-run would have found). Don't substitute Explore-agent summaries for direct reads; agents sometimes report existing files as absent.
2. **Plan to files** — Write the plan into 3 files in `planning/active/`:
   - `task_plan.md` — Phases with checkbox tasks
   - `findings.md` — Research, discoveries, technical analysis
   - `progress.md` — Session log with timestamps and commit refs
3. **Plan-review with the Plan agent — concurrently, not as a gate** — Once `task_plan.md` is scaffolded, spawn the Plan subagent (`Agent({subagent_type: "Plan", prompt: "..."}`) and ask it to critically review the task_plan against the issue body + actual codebase. Categorize findings as Blocker / Gap / Ordering / Assumption / Scope / Acceptance. The agent reads files fresh — it catches what you miss when you've been thinking about the design too long. Real example: caught 21 issues including hardcoded literals across 4 files not listed in the plan, untested DB column mismatches, and a baseline-cache-shadow that would have produced a 6-second no-op run.

   **Do not wait for it.** Spawn, then start the lowest-risk phase. Background agents have repeatedly returned late — in one case after the entire issue had shipped — so treating the review as a precondition stalls the work for as long as the agent takes (see `karpathy.md` §6). Fold findings in whenever they land: pre-baseline they edit the plan; mid-implementation they become follow-up commits — unless the finding is a stored-data fork of the kind `karpathy.md` §8 reserves for the user. A review that arrives after the code is written is not wasted — the reviewer reads real code instead of a plan, which is how one late review still contributed three fixes that no earlier reading had found. If you genuinely cannot proceed without the result, run it with `run_in_background: false` so the blocking is explicit.

   Verify before acting, in both directions. Findings have been confidently wrong (a "BLOCKER" disproved by a 30-second probe) and confidently right about things nobody suspected. Reproduce the claim first.

   **"Both directions" includes the reviewer's conclusions, not just its findings.**
   A review is wrong in the *alarming* direction loudly — a BLOCKER you probe and
   disprove costs one round-trip. It is wrong in the *reassuring* direction
   silently, because nothing prompts you to check a sentence telling you that you
   are finished. Measured 2026-08-30 in gq#77: round 4 fixed its own finding and
   characterised the residual as "definitional". Two commands showed it was not —
   the leftover axis had exactly one member and no margin, the same shape as the
   instance that reviewer had just fixed. Treat *"this is now terminal / complete /
   definitional"* as a claim with an author, exactly like an issue asserting a
   question can only be answered by testing.

   Corollary on when to stop: **convergence is not a reviewer saying you have
   converged.** Across four rounds on that PR, five instances of one defect class
   were found, and three separate "this is terminal now" claims — two of them mine
   — were wrong. What ended it was enumerating the complete candidate set and
   showing nothing sat above its source, not another round.

   **Spawn review agents UNNAMED.** Passing `name` to the `Agent` tool changes what you get: a named spawn becomes a persistent *teammate* that goes **idle** rather than completing, so there is no final report to auto-deliver and its output must be pulled with `SendMessage`. An unnamed spawn is a fire-and-return subagent whose report arrives on its own in the completion notification. Measured 2026-08-25 on one machine, one session, unchanged settings: the unnamed spawn returned in **6.4s**; three named reviewers returned nothing at all, sending only empty idle pings. Pass `name` only for a collaborator you intend to keep messaging, and shut it down when done — it pings indefinitely otherwise.

   That mis-spawn is what produced the silent-delivery failures below, so check `name` before suspecting settings. Teammate mode (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `teammateMode`, merged globally from `soul/settings/defaults.json`) shapes what a *named* spawn becomes; it is not by itself why findings go missing, and an unnamed spawn delivers fine with it enabled.

   **Get the findings into a file — but check who is doing the writing.** Message delivery has silently failed twice: one review arrived as idle notifications with no content, and one was routed to a different session on the user's phone, surfacing only because the user mentioned it. From this side an idle ping is indistinguishable from an agent that had nothing to say, so the loss is invisible. A file (`planning/active/review-<N>.md`) survives routing, survives the agent exiting, and is greppable later.

   **The `Plan` and `Explore` agent types have no Write tool, so they cannot write that file.** Both plan reviews on 2026-08-26 (gq#61, gq#40) were instructed to and were structurally unable to; one said so outright — *"I have no Write/Edit tools and am explicitly barred from creating files; an agent instruction can't lift that"* — and returned the full review as reply text instead. Both arrived intact, ~26 findings each. So:

   - **Read-only agent** (`Plan`, `Explore`): ask for the findings **in the reply**, then write them to `planning/active/review-<N>.md` yourself. The file is still the deliverable; you are just the one creating it.
   - **Agent type that can write**: put the file-path instruction in the first prompt, not as a follow-up.

   Asking for a file the agent cannot produce costs a round-trip, and — worse — sets you up to read an absent file as an absent review. Check the agent type's tools before writing the instruction.

   **Review the fixes, not just the code.** The second pass is where the value concentrates, because a fix written under a wrong assumption reproduces the same defect. Measured on gq#52: pass 1 found 13 defects, pass 2 found 7 more — including a blocker sitting *inside the fix* for pass 1's blocker, the same class twice (`lty`, then `fill_alpha`) because completeness was reasoned about rather than computed. Pass 3, scoped narrowly to the file edited most, found no new instances; **convergence is the signal to stop, not a fixed number of rounds.**

   Convergence is measured, not felt — a quiet round and an exhausted reviewer look
   identical. The rule that terminated trap#28 (five rounds; each of the first four
   found its best defect *inside the previous round's fix*) was to **enumerate the
   candidate set mechanically and show nothing sits above its source of truth**: parse
   the files and walk every `cli_abort`/`warning`/`stop` rather than recalling them, so
   "all of them are pinned" is a count. `code-check.md` states it under "A guard's
   scope, escape hatches, and remedies" — terminate by enumeration, not by a reviewer
   saying you have converged. `/code-check` treats three rounds as the floor and keeps
   going while a round finds a defect inside the previous fix.

   Ask for the **mechanism**, not more instances. Pass 3's best finding was that an invariant was enforced by two lists happening to agree — which is what had produced instances two and three.

   The thing reviewers catch that self-probing does not is **interop**: 18 tests inspected a legend object and none handed it to the renderer, which rejected it outright. Ask the consumer.
4. **Lock naming before the baseline** — If naming feedback surfaces during planning (legacy filename, inconsistency with an existing file family), fold the rename into the convention + task_plan BEFORE the baseline commit, not as a follow-up. Pre-baseline it's free; retrofitting after implementation cascades (soul#52: `build_exec_pdf.R` → `run_pagedown_exec_summary.R` locked in pre-baseline meant zero downstream rework).
5. **Commit the plan** — After Plan-agent review + fixes. This is the baseline.
6. **Work in atomic commits** — Each commit bundles code changes WITH checkbox updates in the planning files. The diff shows both what was done and the checkbox marking it done.
7. **Code check before commit** — Run `/code-check` on staged diffs before committing. Don't mark a task done until the diff passes review.
8. **Archive when complete** — Move `planning/active/` to `planning/archive/` via `/planning-archive`. Write a README.md in the archive directory with a one-paragraph outcome summary and closing commit/PR ref — future sessions scan these to catch up fast. Where the work produced measurements, that README is also the evidence record; see below.

## The archive README is the measurement record

Debugging and benchmarking sessions are systematic investigation: a stated unknown, an
experiment, a number, a conclusion, and usually two or three informative dead ends. That
is SRED evidence, and it scatters — into PR bodies, issue comments, and log files whose
names encode a timestamp and nothing else. In six months the chain *we did not know X,
we measured Y, therefore Z* survives only in a chat transcript.

**The archive README is where that chain lives.** Not a separate run record: the PWF
triple already holds every part of it — the question in `task_plan.md`'s frame, the
method in `progress.md`, the numbers in `findings.md`, the dead ends in its "Errors
Encountered" table. A second document would restate all of it and be half-populated.
The README is the index over them.

So an archive README for work that produced measurements carries two more sections:

```markdown
## Measurement

m1 0.0391 vs cypher 0.0872 min/1k segments — hosts are 2.23x apart.
Moved the provincial estimate 5.0 h -> 4.3 h and changed how work packs across machines.

## Evidence

`data-raw/logs/study_area_run/20260831_19*` — four spins, one defect each.
```

Three rules on those sections:

- **Numbers carry units, and say what changed because of them.** A measurement nobody
  acted on is still worth recording if it turned an assumption into a number — say that
  too. "Confirmed the expected" is a real outcome.
- **Cite a prefix or glob, never a file list.** A list rots the moment a run is re-run;
  a prefix survives. This is why campaign subdirectories exist (`newgraph.md`, "Which
  logs to commit").
- **Keep the wrong turns.** A diagnosis made, retracted on a bad inference, then
  confirmed by measurement *is* the evidence of systematic investigation. Sanitising it
  into a tidy conclusion destroys exactly what makes the record worth keeping.

**The case this does not cover.** Measurement that predates an issue has no PWF to
attach to — `/planning-init` takes an issue number, and exploratory runs often *produce*
the issues rather than follow them. That measurement belongs in the issue or PR it
spawned, with the log directory's own README as the index. Do not build a third system
to close this gap.

## Atomic Commits (Critical)

Every commit that completes a planned task MUST include:
- The code/script changes
- The checkbox update in `task_plan.md` (`- [ ]` -> `- [x]`)
- A progress entry in `progress.md` if meaningful

This creates a git audit trail where `git log -- planning/` tells the full story. Each commit is self-documenting — you can backtrack with git and understand everything that happened.

## File Formats

### task_plan.md

Phases with checkboxes. This is the core tracking file.

```markdown
# Task: <issue title> (#<N>)

<issue body — Problem section if present, otherwise first paragraph>

## Phase 1: [Name]
- [ ] Task description
- [ ] Another task

## Phase 2: [Name]
- [ ] Task description
```

Mark tasks done as they're completed: `- [x] Task description`

### findings.md

Append-only research log. Discoveries, technical analysis, things learned.

```markdown
# Findings

## [Topic]
[What was found, with source/date]

## Errors Encountered

| Error | Resolution |
|-------|------------|
```

### progress.md

Session entries with commit references.

```markdown
# Progress

## Session YYYY-MM-DD
- Completed: [items]
- Commits: [refs]
- Next: [items]
```

<!-- The Reboot Test and the error ledger below are adapted from -->
<!-- OthmanAdi/planning-with-files (MIT). Soul does not install or invoke that -->
<!-- plugin — the useful parts are carried here as text. Adapted 2026-08-26. -->
<!-- Same precedent as the attribution header in karpathy.md. -->

## The Reboot Test

The planning files exist so the work survives an interruption. Whether they
actually do is checkable: at any point mid-task, these five questions must be
answerable from the files alone, without the conversation.

| Question | Answer source |
|----------|---------------|
| Where am I? | Current phase in `task_plan.md` |
| Where am I going? | Remaining phases in `task_plan.md` |
| What's the goal? | The `# Task: <title> (#N)` frame and problem statement at the top of `task_plan.md` |
| What have I learned? | `findings.md` |
| What have I done? | `progress.md` |

If an answer lives only in the session, **write it down and commit it**. Written
is not sufficient: an uncommitted `findings.md` does not move between machines,
and a repo whose `planning/` is gitignored accepts `git add planning/` with exit
0 while tracking nothing — see Directory Structure below.

This is the operational check for the rule that every interruption should be a
resume point: a session death, sleep, or machine swap should cost a re-run at
most, never lost context. That rule states the goal; this tests it.

Run it before any long wait, before compaction, and before switching machines —
the moments that take a session without warning. `/compact-prep` and
`/planning-update` are where it gets run; this section is what it asks.

## Directory Structure

```
planning/
  active/          <- Current work (3 PWF files)
  archive/         <- Completed issues
    YYYY-MM-issue-N-slug/
```

If `planning/` doesn't exist in the repo, run `/planning-init` first.

**`planning/active/` must be tracked, not gitignored.** The atomic-commit rule
above requires each commit to carry its own checkbox flip in `task_plan.md`; an
ignored `active/` drops it silently, so `git log -- planning/` shows archives
appearing fully-formed with no history behind them. In-flight PWF also stops
surviving a move between machines.

The failure is quiet in both directions. `git add planning/` reports nothing and
exits 0 on an ignored path, and files tracked *before* the rule existed keep
being tracked — including through a `git mv` into the ignored directory. So a
repo can look like it is working right up until the first genuinely new PWF file,
which simply never appears in a commit.

Check rather than assume:

```bash
git check-ignore -v planning/active/task_plan.md   # expect no output
```

Found 2026-08-24 in gq, where the rule dated from the scaffold commit and the
#17 files had only survived because they predated their move into that
directory. gq and roli were the only 2 of 32 repos carrying it; roli still does.

## When Something Keeps Failing

Before a second attempt, name the failure class. A **deterministic** failure
returns the same result to the same inputs, so re-running unchanged only spends a
turn — change the inputs or change the approach. A **transient** failure
(network, a provider read, a rate limit, a resource still settling) is the case
where a re-run *is* the attempt: `code-check-infra.md` prescribes exactly that for a
tofu plan that falsely reports a resource deleted. The rule is not "never retry";
it is never retry unchanged while expecting a different answer.

Escalate rather than iterate once the approach itself is in question. Report what
was tried and the exact error, and hand over the commands to run — the user is
assumed to be away, so a question answerable from a phone beats a retry loop they
cannot see. Escalating is not stopping: commit the current state, then move to
the lowest-risk independent part of the plan while the question is outstanding.

Two classes escalate immediately rather than after retries, because further
attempts make them worse:

- **A clamped session.** Once a live credential has been read, later
  system-mutating commands are refused regardless of route — seven consecutive
  refusals across unrelated routes is the documented case (`newgraph.md`,
  "Reading a secret clamps the rest of the session"). Trying more phrasings is
  the failure mode, not the remedy, and `/permissions` does not clear it.
- **Rate limits.** Retrying extends the block (`ci-monitoring.md`).

### Log the errors that cost a retry

An error that took more than one attempt to get past goes in `findings.md`, so
one task does not hit the same wall twice:

```markdown
## Errors Encountered

| Error | Resolution |
|-------|------------|
| `fatal: Unimplemented pathspec magic '_'` | Long-form `:(exclude)path` |
```

That row is also what graduation looks like: it began as one task's blocker and
now lives in `code-check-shell.md` as a general rule about pathspec magic. Most rows
never make that trip and should not — the ledger's job is to stop one task
repeating itself.

When a failure does generalize, it graduates to the convention that owns its
class: the `code-check*.md` family for a bug class in a diff — `code-check.md` for a
mechanism, `-shell`, `-r`, `-spatial` or `-infra` for a tool quirk — `ci-monitoring.md` for CI
behaviour, the domain convention otherwise.

## Skills

| Skill | When to use |
|-------|-------------|
| `/planning-init` | First time in a repo — creates directory structure |
| `/planning-update` | Mid-session — sync checkboxes and progress |
| `/planning-archive` | Issue complete — archive and create fresh active/ |


# Reference Management Conventions

How references flow between Claude Code, Zotero, and technical writing at New Graph Environment.

## Tool Routing

Three tools, different purposes. Use the right one.

| Need | Tool | Why |
|------|------|-----|
| Search by keyword, read metadata/fulltext, semantic search | **MCP `zotero_*` tools** | pyzotero, works with Zotero item keys |
| Look up by citation key (e.g., `irvine2020ParsnipRiver`) | **`/zotero-lookup` skill** | Citation keys are a BBT feature — pyzotero can't resolve them |
| Create items, attach PDFs, deduplicate | **`/zotero-api` skill** | Connector API for writes, JS console for attachments |

**Citation keys vs item keys:** Citation keys (like `irvine2020ParsnipRiver`) come from Better BibTeX. Item keys (like `K7WALMSY`) are native Zotero. The MCP works with item keys. `/zotero-lookup` bridges citation keys to item data.

**BBT citation key storage:** As of Feb 2025+, BBT stores citation keys as a `citationKey` field directly in `zotero.sqlite` (via Zotero's item data system), not in a separate BBT database. The old `better-bibtex.sqlite` and `better-bibtex.migrated` files are stale and no longer updated. Query citation keys with: `SELECT idv.value FROM items i JOIN itemData id ON i.itemID = id.itemID JOIN itemDataValues idv ON id.valueID = idv.valueID JOIN fields f ON id.fieldID = f.fieldID WHERE f.fieldName = 'citationKey'`.

**BBT citekey format is locally patched to strip `&`:** the `citekeyFormat` pref (`extensions.zotero.translators.better-bibtex.citekeyFormat` in `~/Library/Application Support/Zotero/Profiles/*/prefs.js`) has a `.replace(find = "&", replace = "")` segment added by hand. Without it, institutional authors containing `&` (e.g. "BC Species & Ecosystem Explorer", "WA Dept of Fish & Wildlife") leak `&` into the citekey, and pandoc's `@key` parser stops at `&` — so cites render broken in any bookdown/quarto build even though biblatex accepts the key. Reapply via Zotero → Tools → Run JavaScript: `Zotero.Prefs.set("translators.better-bibtex.citekeyFormat", val)` (also patch `citekeyFormatEditing` to match). Survives Zotero/BBT auto-updates; reverts only on a profile reset or a manual edit via the BBT preferences UI. Detect drift: `grep citekeyFormat ~/Library/Application\ Support/Zotero/Profiles/*/prefs.js` should show the `.replace(find = "&", ...)` chain. Teammates on Skeena/Fraser/restoration machines that hit the same `@key`-breaks-at-`&` drift should run the same `Zotero.Prefs.set`.

## Which routes are live by default

Measured 2026-09-04 on a freshly provisioned machine. Four of the six routes below were
dead, and each dead end costs a session time it has no reason to expect:

| route | state on a default setup |
|---|---|
| **Web API** | **works** — the route to use for writes; targets a collection directly via `"collections": [...]` and needs Zotero neither open nor restarted for the write itself |
| **read-only SQLite** | works, and remains the best route for *searching* (`/zotero-lookup`) |
| MCP `zotero_*` | unavailable until an API key is configured — the install script registers the server but never configures a key |
| Local API | `403 Local API is not enabled`, with and without the `Zotero-Allowed-Request` header |
| Connector `saveItems` | HTTP 500 on a minimal item with exactly the documented headers — a defect, not a permission; reads on the same port (`ping`, `getSelectedCollection`) are fine, and `getSelectedCollection` returns the whole collection tree in one call |
| JS runner (`zotero_run_js.sh`) | `osascript is not allowed assistive access` until the terminal has Accessibility |

**Zotero's server takes about 30 s after launch to respond.** An early failure does not
mean it is not running, which is exactly the wrong conclusion to draw at that moment —
wait and retry once before diagnosing.

The key's location, the password-manager item that holds it and the local port are
infrastructure identity and stay in machine-local memory, not here (soul#177).

## Citation keys are BBT-auto-derived

**Never set `Citation Key:` in the `extra` field.** BBT honours it as a manual override,
and that breaks the convention that every key follows one formula: stable, reproducible,
the same key for the same paper on every collaborator's machine. Leave `extra` empty, or
use it only for other Zotero-supported fields (`Original Date:`, `tex.shorttitle:`).
Ten items created with hand-set keys in one lit review (cd#58, 2026-05-05) had to be
PATCHed clean after the user caught it.

- **Web API-created items get no key until Zotero restarts.** Sync alone does not trigger
  BBT. On macOS:
  ```bash
  osascript -e 'tell application "Zotero" to quit'; sleep 3; open -a Zotero; sleep 30
  ```
  Thirty seconds covered seven fresh items (cd#61); scale the wait with the batch.
- **Corporate-author guard.** CrossRef sometimes returns no individual authors (a paper
  bylined to a working group), so the POST lands with empty `creators` and BBT falls back
  to a `<title-prefix><year>` key. PATCH the individual authors from the paper's roster
  into `creators` before triggering the restart.
- **BBT and Zotero version lines are paired** — BBT 8.x for Zotero 7, 9.x for Zotero 8/9.
  If Zotero auto-disables BBT after an update, keys silently stop generating for new
  items; reinstall the matching line via Plugin Manager → gear → "Install Plugin From
  File…" from the BBT releases page.

`/lit-search` and `/zotero-api` point here; this is the authority (soul#43).

## Adding References Workflow

### 1. Search and flag

When research turns up a reference:
- **DOI available:** Tell the user — Zotero's magic wand (DOI lookup) is the fastest path
- **ResearchGate link:** Flag to user for manual check — programmatic fetch is blocked (403), but full text is often there
- **BC gov report:** Search [ACAT](https://a100.gov.bc.ca/pub/acat/), for.gov.bc.ca library, EIRS viewer
- **Paywalled:** Note it, move on. Don't waste time trying to bypass.

### 2. Add to Zotero

**Preferred order:**
1. DOI magic wand in Zotero UI (fastest, most complete metadata)
2. Web API POST with `collections` array (grey literature, local PDFs — targets collection directly, no UI interaction needed)
3. `saveItems` via `/zotero-api` (batch creation from structured data — requires UI collection selection)
4. JS console script for group library (when connector can't target the right collection)

**Collection targeting:** `saveItems` drops items into whatever collection is selected in Zotero's UI. Always confirm with the user before calling it. **Web API bypasses this** — include `"collections": ["KEY"]` in the POST body. Find collection keys with `?q=name` search on the collections endpoint.

### 3. Attach PDFs

`saveItems` attachments silently fail. Don't use them. Instead:

1. **Web API S3 upload (preferred):** Create attachment item → get upload auth → build S3 body (Python: prefix + file bytes + suffix) → POST to S3 → register with uploadKey. Works without Zotero running. See `/zotero-api` skill section 4.
2. **JS console fallback:** Download with `curl`, attach via `item_attach_pdf.js` in Zotero JS console.
3. Verify attachment exists via MCP: `zotero_get_item_children`

### 4. Verify

After manual adds, confirm via MCP:
- `zotero_search_items` — find by title
- `zotero_get_item_metadata` — check fields are complete
- `zotero_get_item_children` — confirm PDF attached

### 5. Clean up

If duplicates were created (common with `saveItems` retries):
- Run `collection_dedup.js` via Zotero JS console
- It keeps the copy with the most attachments, trashes the rest

## In Reports (bookdown)

### Bibliography generation

```yaml
# index.Rmd — dynamic bib from Zotero via Better BibTeX
bibliography: "`r rbbt::bbt_write_bib('references.bib', overwrite = TRUE)`"
```

`rbbt` pulls from BBT, which syncs with Zotero. Edit references in Zotero → rebuild report → bibliography updates.

**Library targeting:** rbbt must know which Zotero library to search. This is set globally in `~/.Rprofile`:

```r
# default library — NewGraphEnvironment group (libraryID 9, group 4733734)
options(rbbt.default.library_id = 9)
```

Without this option, rbbt searches only the personal library (libraryID 1) and won't find group library references. The library IDs map to Zotero's internal numbering — use `/zotero-lookup` with `SELECT DISTINCT libraryID FROM citationkey` against the BBT database to discover available libraries.

### Citation syntax

- `[@key2020]` — parenthetical: (Author 2020)
- `@key2020` — narrative: Author (2020)
- `[@key1; @key2]` — multiple
- `nocite:` in YAML — include uncited references

### Cite primary sources

When a review paper references an older study, trace back to the original and cite it. Don't attribute findings to the review when the original exists. (See LLM Agent Conventions in `newgraph.md`.)

**When the original is unavailable** (paywalled, out of print, can't locate): use secondary citation format in the prose and include bib entries for both sources:

> Smith et al. (2003; as cited in Doctor 2022) found that...

Both `@smith2003` and `@doctor2022` go in the `.bib` file. The reader can then track down the original themselves. Flag incomplete metadata on the primary entry — it's better to have a partial reference than none at all.

## PDF Fallback Chain

When you need a PDF and the obvious URL doesn't work:

1. DOI resolver → publisher site (often has OA link)
2. Europe PMC (`europepmc.org/backend/ptpmcrender.fcgi?accid=PMC{ID}&blobtype=pdf`) — ncbi blocks curl
3. SciELO — needs `User-Agent: Mozilla/5.0` header
4. ResearchGate — flag to user for manual download
5. Semantic Scholar — sometimes has OA links
6. Ask user for institutional access

Always verify downloads: `file paper.pdf` should say "PDF document", not HTML.

## Searching Paper Content (ragnar)

### Setup (per project)
- `scripts/rag_build.R` — maps citation keys to Zotero PDF attachment keys, builds DuckDB
- `data/rag/` gitignored — store is local, not committed
- Dependencies: ragnar, Ollama with nomic-embed-text model
- See `/lit-search` skill for full recipe

### Query
`ragnar_store_connect()` then `ragnar_retrieve()` — returns chunks with source file attribution.

### Anti-patterns
- NEVER write abstracts manually — if CrossRef has no abstract, leave blank
- NEVER cite specific numbers without verifying from the source PDF via ragnar search
- NEVER paraphrase equations — copy exact notation and cite page/section
