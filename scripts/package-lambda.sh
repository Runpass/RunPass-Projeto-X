#!/bin/sh
# Builds the Lambda zip locally for python3.12/arm64. It uploads nothing.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PYTHON=${PYTHON:-"$ROOT/.venv/bin/python"}
OUT=${OUT:-"$ROOT/build/lambda"}
MAX_UNZIPPED_MB=250

rm -rf "$OUT/package" "$OUT/runpass-lambda.zip"
mkdir -p "$OUT/package"

# boto3 comes from the Lambda runtime. Python 3.12 runs on glibc 2.34, which the Pillow wheels need.
"$PYTHON" -m pip install --quiet --no-compile --target "$OUT/package" \
  --implementation cp --python-version 3.12 --only-binary=:all: \
  --platform manylinux2014_aarch64 --platform manylinux_2_17_aarch64 \
  --platform manylinux_2_28_aarch64 --platform manylinux_2_34_aarch64 \
  -c "$ROOT/requirements-dev.lock" -r "$ROOT/backend/requirements-lambda.in"

mkdir "$OUT/package/runpass"
cp "$ROOT"/backend/runpass/*.py "$OUT/package/runpass/"
# The loopback harness must never ship: it mints its own tokens.
rm "$OUT/package/runpass/local_api.py" "$OUT/package/runpass/seed_catalog.py"
# A pagina do portal e servida pela API de operadores: so os arquivos publicos, sem testes nem exemplos.
mkdir "$OUT/package/portal"
cp "$ROOT"/portal/index.html "$ROOT"/portal/style.css "$ROOT"/portal/app.js "$ROOT"/portal/lib.js "$ROOT"/portal/cognito.js "$OUT/package/portal/"

"$PYTHON" -c "import shutil, sys; shutil.make_archive(sys.argv[1], 'zip', sys.argv[2])" \
  "$OUT/runpass-lambda" "$OUT/package"

UNZIPPED_MB=$(du -sm "$OUT/package" | cut -f1)
if [ "$UNZIPPED_MB" -ge "$MAX_UNZIPPED_MB" ]; then
  echo "Pacote de ${UNZIPPED_MB} MB excede o limite de ${MAX_UNZIPPED_MB} MB da Lambda" >&2
  exit 1
fi
echo "$OUT/runpass-lambda.zip (${UNZIPPED_MB} MB descompactado)"
