#!/usr/bin/env bash
set -euo pipefail

# Inputs / outputs
ALIGNED_DIR="./obstructions/rasters/06_aligned"
OUT_UNION="./obstructions/rasters/07_union/all_union_new.tif"
OUT_PERSIST="./obstructions/rasters/08_persistant/all_persistent_new.tif"
OUT_COUNT="./obstructions/rasters/09_persistence_count/all_persistence_count_new.tif"

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
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
CO_STR=("${CO_OPTS[@]}")

# Make a 0/1, no-NDV version of the first raster
gdal_edit.py -unsetnodata "$FIRST"
FIRST_BIN="$TMPDIR/$(basename "${FIRST%.*}")_bin.tif"

# Guard against NoData -> 255
gdal_calc.py -A "$FIRST" --calc="(A==1)" --type=Byte "${CO_STR[@]}" \
  --outfile "$FIRST_BIN" --overwrite


# Initialize outputs with the first raster
# Union = (A>0), Persistence = (A>0), Count = (A>0)
gdal_calc.py -A "$FIRST_BIN" --calc="A" --type=Byte   "${CO_STR[@]}" --outfile "$OUT_UNION"  --overwrite
gdal_calc.py -A "$FIRST_BIN" --calc="A" --type=Byte   "${CO_STR[@]}" --outfile "$OUT_PERSIST" --overwrite
gdal_calc.py -A "$FIRST_BIN" --calc="A" --type=UInt16 "${CO_STR[@]}" --outfile "$OUT_COUNT"  --overwrite

# Fold the rest
for ((i=1; i<${#RASTERS[@]}; i++)); do
  R="${RASTERS[$i]}"
  echo "Accumulating: $R"

  # 0/1, no-NDV version of this raster
  gdal_edit.py -unsetnodata "$R"
  R_BIN="$TMPDIR/$(basename "${R%.*}")_bin.tif"
  gdal_calc.py -A "$R" --calc="(A==1)" --type=Byte "${CO_STR[@]}" \
    --outfile "$R_BIN" --overwrite

  # U = A OR B   (0/1 inputs -> 0/1 output)
  gdal_calc.py -A "$OUT_UNION" -B "$R_BIN" \
    --calc="(A|B)" --type=Byte "${CO_STR[@]}" \
    --outfile "$OUT_UNION" --overwrite

  # P = A AND B
  gdal_calc.py -A "$OUT_PERSIST" -B "$R_BIN" \
    --calc="(A*B)" --type=Byte "${CO_STR[@]}" \
    --outfile "$OUT_PERSIST" --overwrite

  # C = C + B    (UInt16 + Byte -> UInt16)
  gdal_calc.py -A "$OUT_COUNT" -B "$R_BIN" \
    --calc="(A+B)" --type=UInt16 "${CO_STR[@]}" \
    --outfile "$OUT_COUNT" --overwrite
done

echo "Done."
echo "Union mask:            $OUT_UNION        (0/1)"
echo "Persistent (ALL dates):$OUT_PERSIST      (0/1)"
echo "Additive count:        $OUT_COUNT        (0..${#RASTERS[@]})"
