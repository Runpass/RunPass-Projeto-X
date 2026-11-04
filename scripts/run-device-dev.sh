#!/usr/bin/env bash
# Roda o app em um aparelho real apontando para o DEV. Le a URL da API e o client do Cognito
# das saidas das stacks (nada disso vai para o Git). Uso: AWS_PROFILE=runpass-dev-sa scripts/run-device-dev.sh <id-do-aparelho>
set -euo pipefail
: "${AWS_PROFILE:?defina AWS_PROFILE (perfil logado com aws login)}"
device="${1:?informe o id do aparelho (flutter devices)}"
region=sa-east-1
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
output() {
  aws cloudformation describe-stacks --region "$region" --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
api="$(output runpass-dev-app ApiUrl)"
client="$(output runpass-dev-identity RunnerClient)"
[[ "$api" == https://* && -n "$client" && "$client" != None ]] || { echo "Saidas das stacks nao encontradas" >&2; exit 1; }
cd -- "$repo/mobile"
exec "${FLUTTER:-flutter}" run -d "$device" --release \
  --dart-define=RUNPASS_API_URL="$api" \
  --dart-define=RUNPASS_COGNITO_URL="https://cognito-idp.${region}.amazonaws.com/" \
  --dart-define=RUNPASS_COGNITO_CLIENT_ID="$client"
