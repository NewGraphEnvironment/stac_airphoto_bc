#!/bin/bash
# run_pipeline.sh — end-to-end: fetch → georef → COG → tag → S3 → STAC
#
# Usage: bash scripts/run_pipeline.sh
#
# Requires: R with fly/terra/arrow, conda env stac-airphoto-bc, AWS credentials

set -e

echo "=== 01: FETCH ==="
Rscript scripts/01_fetch.R

echo ""
echo "=== 02: GEOREF ==="
Rscript scripts/02_georef.R

echo ""
echo "=== 03: COG ==="
Rscript scripts/03_cog.R

echo ""
echo "=== 04: S3 UPLOAD ==="
Rscript scripts/04_s3_upload.R

echo ""
echo "=== 05: STAC REGISTER ==="
conda run -n stac-airphoto-bc python scripts/05_stac_register.py

echo ""
echo "=== DONE ==="
echo "Run pypgstac on geopro to load into catalog:"
echo "  ssh root@146.190.12.8 'bash /tmp/stac_register-pypgstac.sh stac-airphoto-bc https://stac-airphoto-bc.s3.us-west-2.amazonaws.com'"
