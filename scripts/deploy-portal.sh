#!/usr/bin/env bash
# Cria/atualiza a stack do portal (Lambda + API HTTP que serve a pagina e as rotas de operador).
# Rode com um perfil que possa criar Lambda, API Gateway e IAM (o usuario de desenvolvimento nao pode).
# Empacota o codigo (o zip inclui a pasta portal/), envia ao bucket de artefatos e cria/atualiza a stack.
# Uso: AWS_PROFILE=<perfil-admin> scripts/deploy-portal.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export AWS_REGION=${AWS_REGION:-sa-east-1}
STACK=runpass-dev-portal
pv() { aws cloudformation describe-stacks --stack-name runpass-dev-app --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text; }
io() { aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
make -C "$ROOT" lambda-package >/dev/null
ZIP="$ROOT/build/lambda/runpass-lambda.zip"
KEY="lambda/runpass-$(shasum -a 256 "$ZIP" | cut -c1-16).zip"
aws s3 cp "$ZIP" "s3://$(pv ArtifactBucket)/$KEY" --only-show-errors
echo "Pacote enviado: $KEY"
aws cloudformation deploy --stack-name "$STACK" --template-file "$ROOT/infra/portal.template.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    Environment=dev "DataStack=$(pv DataStack)" "ArtifactBucket=$(pv ArtifactBucket)" "ArtifactKey=$KEY" \
    "RunnerUserPoolId=$(pv RunnerUserPoolId)" "RunnerClientId=$(pv RunnerClientId)" \
    "OperatorUserPoolId=$(io OperatorPool)" "OperatorClientId=$(io OperatorClient)" \
    "ErasureHmacParameter=$(pv ErasureHmacParameter)" "CursorKeyParameter=$(pv CursorKeyParameter)" \
    "CatalogFunctionName=runpass-dev-catalogo-semanal" \
    "CatalogReportBucket=runpass-dev-catalogo-relatorios-$(aws sts get-caller-identity --query Account --output text)" \
    "OpenAiAdminKeyParameter=${OPENAI_ADMIN_KEY_PARAM:-}" "OpenAiProjectId=${OPENAI_PROJECT_ID:-}" \
    "OpenAiPriceInPerMTok=${OPENAI_PRICE_IN_PER_MTOK:-}" "OpenAiPriceOutPerMTok=${OPENAI_PRICE_OUT_PER_MTOK:-}" \
    "OpenAiPricePerSearch=${OPENAI_PRICE_PER_SEARCH:-}" \
    "AnthropicAdminKeyParameter=${ANTHROPIC_ADMIN_KEY_PARAM:-}" "ClaudeMonthlyLimitUsd=${CLAUDE_LIMIT_USD:-}"
echo "Portal: $(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='PortalUrl'].OutputValue" --output text)"
