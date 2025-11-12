#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root relative to this script, so paths are stable
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TPL="$ROOT/obstructions/rasters/template_grid.tif"
IN_DIR="$ROOT/obstructions/rasters/05_obstructions"
OUT_DIR="$ROOT/obstructions/rasters/06_aligned"
mkdir -p "$OUT_DIR"

# Make sure the template advertises the expected SRS
gdal_edit.py -a_srs EPSG:32761 "$TPL"

# Force dot decimals just in case
export LC_ALL=C

# Parse template metadata robustly
read WIDTH HEIGHT <<< "$(gdalinfo "$TPL" | awk '/^Size is/ {gsub(",", "", $3); print $3, $4}')"
read XMIN  YMAX   <<< "$(gdalinfo "$TPL" | sed -n 's/.*Origin = (\([^,]*\), *\([^)]*\)).*/\1 \2/p')"
read RESX  RESY   <<< "$(gdalinfo "$TPL" | sed -n 's/.*Pixel Size = (\([^,]*\), *\([^)]*\)).*/\1 \2/p')"

# Sanity checks (fail fast if any are empty)
: "${WIDTH:?missing width}"; : "${HEIGHT:?missing height}"
: "${XMIN:?missing origin x}"; : "${YMAX:?missing origin y}"
: "${RESX:?missing xres}"; : "${RESY:?missing yres}"

# Compute extent from origin + size (GeoTIFF origin is upper-left)
XMAX=$(awk -v x="$XMIN" -v w="$WIDTH"  -v rx="$RESX" 'BEGIN{printf "%.9f", x + w*rx}')
YMIN=$(awk -v y="$YMAX" -v h="$HEIGHT" -v ry="$RESY" 'BEGIN{printf "%.9f", y + h*ry}')
RESY_POS=$(awk -v y="$RESY" 'BEGIN{printf "%.12f", (y<0)?-y:y}')

echo "Template:"
echo "  SRS  = EPSG:32761"
echo "  Size = ${WIDTH} x ${HEIGHT}"
echo "  Origin (XMIN,YMAX) = $XMIN $YMAX"
echo "  Pixel size = $RESX $RESY  (using $RESY_POS for -tr Y)"
echo "  Extent (XMIN YMIN XMAX YMAX) = $XMIN $YMIN $XMAX $YMAX"

export XMIN YMIN XMAX YMAX RESX RESY_POS OUT_DIR

# Warp every mask onto the template grid; outside gets 0; keep binary values
find "$IN_DIR" -type f -name '*.tif' -print0 |
  parallel -0 -j4 --eta --bar \
  gdalwarp -overwrite -r near -multi \
           -s_srs EPSG:32761 -t_srs EPSG:32761 \
           -tr "$RESX" "$RESY_POS" -tap \
           -te "$XMIN" "$YMIN" "$XMAX" "$YMAX" \
           -wo INIT_DEST=0 \
           {} "$OUT_DIR"/{/.}_aligned.tif
