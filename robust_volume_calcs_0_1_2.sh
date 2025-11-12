#!/usr/bin/env bash
set -Eeuo pipefail

# --- inputs (hard-coded for now) ---
A="day1.tif"
B="day2.tif"
ZONES="30m_station_buffer.shp"
NODATA="-9999"

# --- sanity checks ---
for cmd in gdalinfo gdalsrsinfo gdalwarp gdal_calc.py gdaltransform jq awk; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[ -f "$A" ] || { echo "Missing $A" >&2; exit 1; }
[ -f "$B" ] || { echo "Missing $B" >&2; exit 1; }
[ -f "$ZONES" ] || { echo "Missing $ZONES" >&2; exit 1; }

# --- choose base SRS (A's), fall back to WKT if no EPSG ---
BASE_SRS=$(gdalsrsinfo -o epsg "$A" | awk '/EPSG/{print $1}')
[ -n "${BASE_SRS:-}" ] || { gdalsrsinfo -o wkt "$A" > base.wkt; BASE_SRS="base.wkt"; }

# --- A's bbox in base SRS ---
read A_ULX A_ULY A_LRX A_LRY <<<"$(gdalinfo -json "$A" | jq -r '.cornerCoordinates | "\(.upperLeft[0]) \(.upperLeft[1]) \(.lowerRight[0]) \(.lowerRight[1])"')"

# --- B's bbox in its native SRS, then reproject ALL FOUR corners into base SRS ---
B_SRS=$(gdalsrsinfo -o epsg "$B" | awk '/EPSG/{print $1}')
[ -n "${B_SRS:-}" ] || { gdalsrsinfo -o wkt "$B" > B.wkt; B_SRS="B.wkt"; }

read B_ULX B_ULY B_URX B_URY B_LRX B_LRY B_LLX B_LLY <<<"$(gdalinfo -json "$B" | jq -r '.cornerCoordinates | "\(.upperLeft[0]) \(.upperLeft[1]) \(.upperRight[0]) \(.upperRight[1]) \(.lowerRight[0]) \(.lowerRight[1]) \(.lowerLeft[0]) \(.lowerLeft[1])"')"

reproj() { gdaltransform -s_srs "$B_SRS" -t_srs "$BASE_SRS" <<<"$1 $2" | awk '{print $1, $2}'; }
read BX_ULX BX_ULY <<<"$(reproj "$B_ULX" "$B_ULY")"
read BX_URX BX_URY <<<"$(reproj "$B_URX" "$B_URY")"
read BX_LRX BX_LRY <<<"$(reproj "$B_LRX" "$B_LRY")"
read BX_LLX BX_LLY <<<"$(reproj "$B_LLX" "$B_LLY")"

# --- min/max for A and B in base SRS ---
min4(){ awk 'BEGIN{m=$1; for(i=2;i<=NF;i++) if($i<m) m=$i; print m}' "$@"; }
max4(){ awk 'BEGIN{M=$1; for(i=2;i<=NF;i++) if($i>M) M=$i; print M}' "$@"; }

A_XMIN=$(min4 "$A_ULX" "$A_LRX") ; A_XMAX=$(max4 "$A_ULX" "$A_LRX")
A_YMIN=$(min4 "$A_LRY" "$A_ULY") ; A_YMAX=$(max4 "$A_LRY" "$A_ULY")

B_XMIN=$(min4 "$BX_ULX" "$BX_URX" "$BX_LRX" "$BX_LLX")
B_XMAX=$(max4 "$BX_ULX" "$BX_URX" "$BX_LRX" "$BX_LLX")
B_YMIN=$(min4 "$BX_LLY" "$BX_LRY" "$BX_ULY" "$BX_URY")
B_YMAX=$(max4 "$BX_LLY" "$BX_LRY" "$BX_ULY" "$BX_URY")

# --- intersection bbox (abort if empty) ---
XMIN=$(awk -v a="$A_XMIN" -v b="$B_XMIN" 'BEGIN{print (a>b)?a:b}')
XMAX=$(awk -v a="$A_XMAX" -v b="$B_XMAX" 'BEGIN{print (a<b)?a:b}')
YMIN=$(awk -v a="$A_YMIN" -v b="$B_YMIN" 'BEGIN{print (a>b)?a:b}')
YMAX=$(awk -v a="$A_YMAX" -v b="$B_YMAX" 'BEGIN{print (a<b)?a:b}')
awk -v xmin="$XMIN" -v xmax="$XMAX" -v ymin="$YMIN" -v ymax="$YMAX" 'BEGIN{if(xmin>=xmax || ymin>=ymax){print "Empty intersection"; exit 2}}'

# --- choose target resolution (coarser of A,B) ---
read AX AY <<<"$(gdalinfo -json "$A" | jq -r '[.geoTransform[1], (.geoTransform[5]|-.)] | @tsv')"
read BX BY <<<"$(gdalinfo -json "$B" | jq -r '[.geoTransform[1], (.geoTransform[5]|-.)] | @tsv')"
TRX=$(awk -v a="$AX" -v b="$BX" 'BEGIN{print (a>b)?a:b}')
TRY=$(awk -v a="$AY" -v b="$BY" 'BEGIN{print (a>b)?a:b}')

# --- warp both to identical grid (snap with -tap) ---
gdalwarp -t_srs "$BASE_SRS" -te "$XMIN" "$YMIN" "$XMAX" "$YMAX" -tr "$TRX" "$TRY" -tap -r bilinear -dstnodata "$NODATA" "$A" day1_int.tif
gdalwarp -t_srs "$BASE_SRS" -te "$XMIN" "$YMIN" "$XMAX" "$YMAX" -tr "$TRX" "$TRY" -tap -r bilinear -dstnodata "$NODATA" "$B" day2_int.tif

# --- positive deltas (deposition: B above A) & negative (scour: A above B) with NoData masking ---
gdal_calc.py --type=Float64 -A day1_int.tif -B day2_int.tif --NoDataValue="$NODATA" \
  --calc="where((A!=$NODATA)&(B!=$NODATA)&(B-A>0), B-A, 0)" \
  --outfile=day2-day1_deposition.tif

gdal_calc.py --type=Float64 -A day1_int.tif -B day2_int.tif --NoDataValue="$NODATA" \
  --calc="where((A!=$NODATA)&(B!=$NODATA)&(B-A<0), A-B, 0)" \
  --outfile=day2-day1_scour.tif

# --- per-pixel volumes (m^3) ---
PX=$(gdalinfo -json day2-day1_deposition.tif | jq -r '.geoTransform[1]')
PY=$(gdalinfo -json day2-day1_deposition.tif | jq -r '(.geoTransform[5]|-.)')
CELLAREA=$(awk -v x="$PX" -v y="$PY" 'BEGIN{printf "%.15f", x*y}')

gdal_calc.py --type=Float64 -A day2-day1_deposition.tif --NoDataValue=0 \
  --calc="$CELLAREA*A" --outfile=day2-day1_deposition_pixel_volume.tif

gdal_calc.py --type=Float64 -A day2-day1_scour.tif --NoDataValue=0 \
  --calc="$CELLAREA*A" --outfile=day2-day1_scour_pixel_volume.tif

# --- zonal volume sums (fractional edge weighting) ---
gdal raster zonal-stats -i day2-day1_deposition_pixel_volume.tif \
  -o day2-day1_deposition_pixel_volume.csv -f CSV \
  --zones "$ZONES" --stat sum --pixels fractional

gdal raster zonal-stats -i day2-day1_scour_pixel_volume.tif \
  -o day2-day1_scour_pixel_volume.csv -f CSV \
  --zones "$ZONES" --stat sum --pixels fractional

echo "Done. CSVs: day2-day1_deposition_pixel_volume.csv, day2-day1_scour_pixel_volume.csv"
