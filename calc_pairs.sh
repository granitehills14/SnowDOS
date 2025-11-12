#!/usr/bin/env bash
set -euo pipefail
IFS=$' \n\t'

# Resolve repo root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IN="$ROOT/obstructions/rasters/06_aligned"
OUT_UNION="$ROOT/obstructions/rasters/07_union"
OUT_PERSIST="$ROOT/obstructions/rasters/08_persistant"   # keeping your existing folder name
mkdir -p "$OUT_UNION" "$OUT_PERSIST"

# Define the pairs to compare (A then B)
pairs=(
"20241129_Elevated_Station_5cm_obstructions_aligned.tif 20241203_Elevated_Station_5cm_obstructions_aligned.tif"
"20241203_Elevated_Station_5cm_obstructions_aligned.tif 20250115_Elevated_Station_5cm_obstructions_aligned.tif"
"20250115_Elevated_Station_5cm_obstructions_aligned.tif 20250219_Elevated_Station_5cm_obstructions_aligned.tif"
"20250219_Elevated_Station_5cm_obstructions_aligned.tif 20250307-08_Elevated_Station_5cm_obstructions_aligned.tif"
"20250307-08_Elevated_Station_5cm_obstructions_aligned.tif 20250416-17_Elevated_Station_5cm_obstructions_aligned.tif"
"20250416-17_Elevated_Station_5cm_obstructions_aligned.tif 20250502_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
"20250502_Elevated_Station_5cm_smooth_obstructions_aligned.tif 20250603-05_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
"20250603-05_Elevated_Station_5cm_smooth_obstructions_aligned.tif 20250707-09_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
"20250707-09_Elevated_Station_5cm_smooth_obstructions_aligned.tif 20250820_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
"20250820_Elevated_Station_5cm_smooth_obstructions_aligned.tif 20250904_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
"20250904_Elevated_Station_5cm_smooth_obstructions_aligned.tif 20251001_Elevated_Station_5cm_smooth_obstructions_aligned.tif"
)

run_pair() {
  local A="$1" B="$2"
  local A_PATH="$IN/$A" B_PATH="$IN/$B"
  [[ -f "$A_PATH" && -f "$B_PATH" ]] || { echo "Missing: $A_PATH or $B_PATH" >&2; return 1; }

  # derive label from filename (first underscore-delimited token, e.g., 20250416-17)
  local DA="${A%%_*}" DB="${B%%_*}"
  local BASE="${DB}-${DA}_obstructions"

  local OUT_U="$OUT_UNION/${BASE}_union.tif"
  local OUT_P="$OUT_PERSIST/${BASE}_persistant.tif"

  echo "=> $DB vs $DA"
  gdal_calc.py -A "$A_PATH" -B "$B_PATH" \
    --calc="((A>0)|(B>0))" --type=Byte --NoDataValue=0 \
    --outfile "$OUT_U" --quiet

  gdal_calc.py -A "$A_PATH" -B "$B_PATH" \
    --calc="(A>0)*(B>0)" --type=Byte --NoDataValue=0 \
    --outfile "$OUT_P" --quiet
}

for line in "${pairs[@]}"; do
  # split the two filenames
  set -- $line
  run_pair "$1" "$2"
done

# ---- Optional: parallelize (uncomment to use GNU parallel) ----
# export -f run_pair
# export IN OUT_UNION OUT_PERSIST
# printf '%s\n' "${pairs[@]}" | parallel -j4 --colsep ' ' run_pair {1} {2}
