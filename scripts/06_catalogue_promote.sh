#!/usr/bin/env bash
# 06_catalogue_promote.sh — move a validated backfill into data/stac and publish.
#
# Usage:
#   bash scripts/06_catalogue_promote.sh            # validate, promote, validate, sync
#   bash scripts/06_catalogue_promote.sh --no-sync  # stop before touching S3
#
# Order matters here in ways that are not obvious, so the sequence is a script
# rather than a list in a README that a tired person reads out of order.
#
#   1. validate data/stac_patched          the gate
#   2. copy it into data/stac              the promotion
#   3. re-run 05_stac_register.py          see "Why step 3" below
#   4. validate data/stac                  the bytes that actually ship
#   5. aws s3 sync                         publish
#
# Why validate twice
# ------------------
# Step 1 checks the tree the backfill wrote. Step 5 uploads a DIFFERENT tree.
# Everything between them — a copy that half-writes, a regeneration, a stray file
# — lands after the gate and before the wire. So the gate runs again on the thing
# being shipped. `06_catalogue_backfill.py` counts files, not parseable files,
# and `write_text` is not atomic; only a parse closes that, and only a parse of
# the promoted copy closes it for the promoted copy.
#
# Why step 3
# ----------
# Two reasons, and both are about not shipping something nobody derived.
#
# The 235 items with a COG on this machine have two producers now: the generator
# and the backfill. Re-running the generator last makes it the owner of the items
# it can build, so an item is never a hybrid of the two.
#
# More importantly it fixes `collection.json`. `04_s3_upload.R` syncs every
# `*.json` in `data/stac`, and `collection.json` is one of them — so a stale
# local copy would be pushed over the published collection, which
# `stacs register` then reads to register pgstac. `05_stac_register.py`
# FETCHES the published collection and merges into it, refusing to shrink it, so
# running it immediately before the sync makes the local file provably derived
# from the live one. That is a stronger guarantee than excluding the file from
# the sync, and it is why this runs here rather than earlier.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PATCHED="data/stac_patched"
STAC="data/stac"
CONDA_RUN="conda run --no-capture-output -n stac-airphoto-bc"

SYNC=1
[ "${1:-}" = "--no-sync" ] && SYNC=0

# The backfill patched items published before #23. Once the rebuild has written
# items that carry `file:checksum`, promoting the patched tree would copy the old
# geometry back over them and re-register it. Refuse rather than revert.
# find, not a glob: 10k item filenames can exceed ARG_MAX (see step 2).
if [ -d "$STAC" ] && [ -n "$(find "$STAC" -maxdepth 1 -name '*.json' -exec grep -l '"file:checksum"' {} + 2>/dev/null | head -1)" ]; then
  echo "Items in $STAC carry file:checksum: they are from the #23 rebuild, and" >&2
  echo "promoting $PATCHED would overwrite them with pre-rebuild items. Refusing." >&2
  exit 1
fi

if [ ! -d "$PATCHED" ]; then
  echo "No $PATCHED. Run:" >&2
  echo "  Rscript scripts/06_catalogue_fetch.R" >&2
  echo "  $CONDA_RUN python scripts/06_catalogue_backfill.py" >&2
  exit 1
fi

echo "=== 1/5 validate $PATCHED"
$CONDA_RUN python scripts/06_catalogue_validate.py --dir "$PATCHED"

echo
echo "=== 2/5 promote into $STAC"
# find, not `cp "$PATCHED"/*` — 9,976 filenames is comfortably inside ARG_MAX
# today and comfortably outside it once the collection grows, and the failure
# lands after the expensive stage has already succeeded.
mkdir -p "$STAC"
n_before=$(find "$STAC" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
find "$PATCHED" -maxdepth 1 -name '*.json' -exec cp {} "$STAC"/ \;
n_after=$(find "$STAC" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
echo "item JSONs in $STAC: $n_before -> $n_after"

echo
echo "=== 3/5 regenerate local items and collection.json"
$CONDA_RUN python scripts/05_stac_register.py

echo
echo "=== 4/5 validate $STAC — the bytes that ship"
$CONDA_RUN python scripts/06_catalogue_validate.py --dir "$STAC"

if [ "$SYNC" -eq 0 ]; then
  echo
  echo "--no-sync: stopping before S3. To publish:"
  echo "  Rscript scripts/04_s3_upload.R"
  exit 0
fi

echo
echo "=== 5/5 sync to S3"
Rscript scripts/04_s3_upload.R

cat <<'EOF'

Synced. The new properties are on S3 but NOT yet queryable: pgstac still holds
the old items. Register them to make them searchable (upsert; nothing is
deleted). From the repo root; stacs reaches the STAC host over ssh:

  conda run --no-capture-output -n stac-airphoto-bc stacs register --config stacs.toml --mode all
  conda run --no-capture-output -n stac-airphoto-bc stacs verify   --config stacs.toml

--mode all because the backfill rewrote every item it touched. verify compares
every body with what the API serves, so it confirms the new properties landed.
EOF
