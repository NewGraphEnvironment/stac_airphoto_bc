#!/bin/bash
# run_pipeline.sh — end-to-end: fetch → georef → place + tag + COG → STAC → S3
#
# Usage:
#   bash scripts/run_pipeline.sh                 # every registered AOI
#   bash scripts/run_pipeline.sh se_a se_b       # named AOIs only
#
# Requires: R with fly/terra/arrow/flooded, uv (the Python env is pyproject.toml +
# uv.lock), AWS
# credentials with write access to s3://stac-airphoto-bc.
#
# No fly version is named here on purpose. 01_fetch.R and 02_georef.R call
# aoi_require_fly(), which asserts the capability the pipeline needs — that
# `dem` reaches fly_filter(), fly_footprint() and fly_georef() — rather than a
# number that goes stale every time fly releases. See scripts/aoi.R.
#
# Item generation (05_stac_register.py) runs BEFORE the S3 sync. It used to run
# after, which meant the item JSONs and collection.json a run produced were never
# uploaded by that run — the ones on S3 were always the previous cycle's.

# pipefail, so that piping any step later (through tee, say) cannot mask its failure
# behind the exit status of the last command in the pipe.
#
# `uv run --locked`: syncs .venv to uv.lock but refuses to re-resolve, so a hand edit
# to pyproject.toml cannot quietly install a new rasterio (and its GDAL) mid-run,
# between steps that write published bytes (#44).
set -euo pipefail

AOI_IDS=("$@")

# Empty array expansion is an unbound-variable error under `set -u` on the
# bash 3.2 that macOS still ships, so guard before expanding.
if [ ${#AOI_IDS[@]} -gt 0 ]; then
  echo "AOIs: ${AOI_IDS[*]}"
else
  echo "AOIs: all registered"
fi

run_r() {
  local script="$1"; shift
  if [ ${#AOI_IDS[@]} -gt 0 ]; then
    Rscript "$script" "${AOI_IDS[@]}"
  else
    Rscript "$script"
  fi
}

echo "=== 01: FETCH ==="
run_r scripts/01_fetch.R

echo ""
echo "=== 02: GEOREF ==="
run_r scripts/02_georef.R

echo ""
echo "=== 03: COG ==="
uv run --locked python scripts/03_cog.py

echo ""
echo "=== 04: STAC REGISTER ==="
uv run --locked python scripts/05_stac_register.py

echo ""
echo "=== 05: S3 UPLOAD ==="
Rscript scripts/04_s3_upload.R

echo ""
echo "=== DONE ==="
cat <<'EOF'
Register into pgstac to make it searchable. From the repo root; stacs reaches the
STAC host (root@geopro) over ssh, upserts only, and deletes nothing:

  uv run stacs register --config stacs.toml --mode all
  uv run stacs verify   --config stacs.toml

--mode drift also works: it compares bodies, so it sends the collection and only
the items the API lacks or serves differently, which includes every item this run
rebuilt. verify follows register because only verify fails on orphans (ids
registered but no longer published).
EOF
