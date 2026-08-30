#!/bin/bash
# run_pipeline.sh — end-to-end: fetch → georef → COG → tag → STAC → S3
#
# Usage:
#   bash scripts/run_pipeline.sh                 # every registered AOI
#   bash scripts/run_pipeline.sh se_a se_b       # named AOIs only
#
# Requires: R with fly (>= 0.5.0)/terra/arrow, conda env stac-airphoto-bc,
# AWS credentials with write access to s3://stac-airphoto-bc.
#
# Registration runs BEFORE the S3 sync. It used to run after, which meant the
# item JSONs and collection.json a run produced were never uploaded by that run
# — the ones on S3 were always the previous cycle's.

# pipefail matters here: several steps pipe through conda run, and without it a
# failing script is masked by the exit status of the last command in the pipe.
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
Rscript scripts/03_cog.R

echo ""
echo "=== 04: STAC REGISTER ==="
conda run --no-capture-output -n stac-airphoto-bc python scripts/05_stac_register.py

echo ""
echo "=== 05: S3 UPLOAD ==="
Rscript scripts/04_s3_upload.R

echo ""
echo "=== DONE ==="
echo "Run pypgstac on geopro to load into the catalog:"
echo "  ssh root@\${GEOPRO_IP:?set GEOPRO_IP} \\"
echo "    'bash /tmp/stac_register-pypgstac.sh stac-airphoto-bc \\"
echo "     https://stac-airphoto-bc.s3.us-west-2.amazonaws.com'"
