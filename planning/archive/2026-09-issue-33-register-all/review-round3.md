# Review round 3 — #33 staged diff

Reviewed: `git diff --cached` (CLAUDE.md above the soul marker, scripts/README.md,
scripts/run_pipeline.sh, scripts/06_catalogue_promote.sh) against stac_dem_bc@0e7934a
`scripts/catalogue_register.sh`. Probes were read-only (GETs against the API and S3, jq
on synthetic inputs in the scratchpad, interactive zsh/bash fed a copy of the block).

## Mechanism

The candidate framing ("described from reading rather than run as the operator would
run it") fits R1's two findings, R2's `PYTHON=` directory and R2's export leak. It does
not fit R2's `georef_metadata` check, which *was* run. A framing that covers all five,
and the new ones below:

**Every command and check was exercised in the author's environment and in the state
where the answer is already yes: a reachable, fully registered, in-sync catalogue. None
was exercised in the operator's environment or in the state the step exists to detect,
which is a catalogue that is stale, or unreachable.** In the current world, where
everything is published and registered, "prints true on the live API" and "IN SYNC
10100" are the only results any of these checks can give. So running them shows they
run, but not that they discriminate. The tampered-copy control tests the `==`
comparator. It does not test the two inputs (how the sample is chosen, and what the
fetch returns when it fails), and both findings below sit in those inputs.

Everywhere the mechanism reaches in this diff, checked:

| place | result |
|---|---|
| jq spot-check, fetch failure (README ~251-254, 06 heredoc ~123-126) | **fails toward pass** (finding 1) |
| jq spot-check, choice of sample (same lines) | **cannot see a stale item for most runs** (finding 2) |
| comment-bearing blocks in the operator's shell (CLAUDE.md 76-81, README 228-233) | **break in interactive zsh** (finding 3) |
| `ID=` derivation when `collection.json` fails | loud: S3 answers the resulting `/.json` with XML `AccessDenied`, and jq exits 2 on bad JSON |
| API up and S3 item body fine, API returns 404 JSON | loud: `null == {…}` is false |
| API 5xx HTML | loud: jq exits 2 on bad JSON |
| `--all && --verify` subshell, printed copies (run_pipeline, 06) | fine in bash and zsh (no comments) |
| four copies identical in substance | yes: same three variables and values, same two commands. CLAUDE.md and README additionally carry trailing comments, which is the difference that matters in finding 3 |
| `&&` followed by a `#` comment then a newline | fine in bash (probed interactively, bash 3.2) |
| `--verify` described as ids only | accurate to catalogue_register.sh (the `diff` mode compares id sets) |
| `cd` outside the subshell | leaves the operator in stac_dem_bc. The spot-check that follows is cwd-independent, so there is no defect |

## Findings

- **[bug]** scripts/README.md:250-254, scripts/06_catalogue_promote.sh:122-126. The
  content spot-check prints `true` when nothing can be fetched. All three `curl -s`
  calls lack `-f`, and jq's `--slurpfile` on an empty body gives `[]`, so `$x[0].properties`
  is `null` on both sides, and `null == null` is `true`. Measured end to end with an
  unresolvable host: `ID=` came back empty, and the `jq -n --slurpfile …` line printed
  `true` with rc 0. The same happens when the API returns a 404 JSON (`{"code":"NotFoundError",…}`,
  no `.properties`) and the S3 body is empty. So losing the network (DNS, VPN or proxy
  down, or a laptop offline) reads as "API matches S3", and that is the one line the
  operator is told to trust over `--verify`. Fix: require a real item on the S3 side,
  for example
  `'$s3[0].properties as $p | ($p | type) == "object" and $api[0].properties == $p'`,
  and use `curl -fsS` so a fetch failure is printed rather than swallowed.

- **[fragile]** scripts/README.md:250-254, scripts/06_catalogue_promote.sh:122-126. The
  sampled item is fixed and has no connection to what the run changed. `05_stac_register.py:376`
  writes the links `sorted()`, so `[0]` is always the lexically first id. Today that is
  `1006039`, which appears in `data/select/se_a.csv` and `se_b.csv` and in neither
  `neexdzii_kwa.csv` nor `se_c.csv`. A `run_pipeline.sh neexdzii_kwa` run (97% of the
  collection) never rewrites that item, so the check prints `true` *before* `--all` has
  run, just as it does after. This is the same defect as R2's `georef_metadata` check (a
  sample that already agrees), carried into its replacement. The README frames this as
  the way to see that "a rebuild here rewrites existing items' properties", which it
  cannot show unless the rebuild happened to touch 1006039. Fix: sample from what the
  run wrote. One option is the local item with the newest `nge:produced_datetime`
  (`jq -rs 'max_by(.properties["nge:produced_datetime"]).id' data/stac/[0-9]*.json`, or
  a `find`-based equivalent at 10k files). Another is a handful of random ids from the
  run's AOI window.

- **[fragile]** CLAUDE.md:79-80, scripts/README.md:232-233. The two comment-bearing
  copies do not paste into interactive zsh. Interactive zsh has `interactive_comments`
  off by default, and this machine's zsh has it off too (`zsh -ic setopt` lists only
  `interactive`). Pasting the block gives `zsh: parse error near '#'`, and nothing runs.
  It fails loudly rather than toward pass, and the login shell here is bash
  (`dscl … UserShell: /bin/bash`), so this bites only a zsh terminal or another machine
  (zsh is the macOS default for new accounts). The printed copies in run_pipeline.sh
  and 06 have no comments and paste fine in both shells. Fix: move the two comments to
  their own lines above the subshell, or drop them. The README's trailing
  `# expect true` on the jq line is harmless: jq `-n` ignores the stray words, and it
  still printed `true` in zsh.

## Notes (not findings)

- The 06 heredoc is unreachable in the current tree. The guard at
  06_catalogue_promote.sh:55-59 refuses whenever `data/stac` holds any item with
  `file:checksum`, which every post-#23 item does. So finding 1 and finding 2 bite
  through the README copy in practice, not through 06.
- The spot-check compares `properties` only. `file:checksum`/`file:size` sit on
  `assets.thumbnail`, so a checksum-only difference would not show. In this pipeline a
  byte change also moves `nge:produced_datetime` (a property), so this is not a
  separate gap today.
