#!/usr/bin/env bash
# pipeline_sha.sh — the commit of this pipeline's code, and what is uncommitted on top.
#
# Prints `<12-char HEAD>` for a clean tree, or `<HEAD>-dirty-<8-char hash>` where the
# hash covers the uncommitted diff of scripts/ and data-raw/ plus every untracked file
# there. Two different uncommitted states therefore never share a label, which a bare
# `-dirty` did: an edited fly_georef() call reused GeoTIFFs written before the edit
# and 03 tagged them with the same string (#23, code-check round 4).
#
# The single definition: aoi_provenance() (R) and 03_cog.py (Python) both run this,
# so the two cannot disagree on the scope or the digest. Scoped to the code because
# data/reports/*.md is tracked and rewritten by every run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
head=$(git rev-parse HEAD | cut -c1-12)
untracked=$(git ls-files --others --exclude-standard -- scripts data-raw)
if git diff --quiet HEAD -- scripts data-raw && [ -z "$untracked" ]; then
  echo "$head"
  exit 0
fi
digest=$( { git diff HEAD -- scripts data-raw
            if [ -n "$untracked" ]; then
              while IFS= read -r f; do printf '%s %s\n' "$f" "$(git hash-object "$f")"; done <<< "$untracked"
            fi
          } | git hash-object --stdin | cut -c1-8)
echo "${head}-dirty-${digest}"
