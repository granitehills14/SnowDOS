#!/usr/bin/env bash
set -euo pipefail

# Inputs / outputs
ALIGNED_DIR="./obstructions/rasters/06_aligned"
OUT_UNION="./obstructions/rasters/07_union/all_union.tif"
OUT_PERSIST="./obstructions/rasters/08_persistant/all_persistent.tif"
OUT_COUNT="./obstructions/rasters/09_persistence_count/all_persistence_count.tif"

# Optional: limit to first N rasters (set to 0 to use all)
MAX_RASTERS=0

# GDAL creation options for small, fast GeoTIFFs
CO_OPTS=(--co "COMPRESS=LZW" --co "TILED=YES" --co "BIGTIFF=IF_SAFER")

mkdir -p "$(dirname "$OUT_UNION")" "$(dirname "$OUT_PERSIST")" "$(dirname "$OUT_COUNT")"

# Collect and sort rasters
mapfile -t RASTERS < <(find "$ALIGNED_DIR" -maxdepth 1 -type f -name '*_obstructions*.tif' -print | sort)
if (( ${#RASTERS[@]} == 0 )); then
  echo "No rasters found in $ALIGNED_DIR" >&2
  exit 1
fi

# Enforce MAX_RASTERS if set
if (( MAX_RASTERS > 0 && ${#RASTERS[@]} > MAX_RASTERS )); then
  RASTERS=("${RASTERS[@]:0:MAX_RASTERS}")
fi

echo "Using ${#RASTERS[@]} rasters:"
printf '  %s\n' "${RASTERS[@]}"

FIRST="${RASTERS[0]}"

# Initialize outputs with the first raster
# Union = (A>0), Persistence = (A>0), Count = (A>0)
gdal_calc.py -A "$FIRST" --calc="(A>0)" --type=Byte   --NoDataValue=0 "${CO_OPTS[@]}" --outfile "$OUT_UNION"  --overwrite
gdal_calc.py -A "$FIRST" --calc="(A>0)" --type=Byte   --NoDataValue=0 "${CO_OPTS[@]}" --outfile "$OUT_PERSIST" --overwrite
gdal_calc.py -A "$FIRST" --calc="(A>0)" --type=UInt16 --NoDataValue=0 "${CO_OPTS[@]}" --outfile "$OUT_COUNT"  --overwrite

# Fold the rest
for ((i=1; i<${#RASTERS[@]}; i++)); do
  R="${RASTERS[$i]}"
  echo "Accumulating: $R"

  # Union: U = (U>0) OR (R>0)
  gdal_calc.py -A "$OUT_UNION" -B "$R" \
    --calc="((A>0)|(B>0))" --type=Byte --NoDataValue=0 "${CO_OPTS[@]}" \
    --outfile "$OUT_UNION" --overwrite

  # Persistence (intersection across all): P = (P>0) AND (R>0)
  gdal_calc.py -A "$OUT_PERSIST" -B "$R" \
    --calc="((A>0)*(B>0))" --type=Byte --NoDataValue=0 "${CO_OPTS[@]}" \
    --outfile "$OUT_PERSIST" --overwrite

  # Additive count: C = C + (R>0)
  gdal_calc.py -A "$OUT_COUNT" -B "$R" \
    --calc="(A + (B>0))" --type=UInt16 --NoDataValue=0 "${CO_OPTS[@]}" \
    --outfile "$OUT_COUNT" --overwrite
done

echo "Done."
echo "Union mask:            $OUT_UNION        (0/1)"
echo "Persistent (ALL dates):$OUT_PERSIST      (0/1)"
echo "Additive count:        $OUT_COUNT        (0..${#RASTERS[@]})"
