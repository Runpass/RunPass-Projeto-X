#!/usr/bin/env bash
# Cria/atualiza a stack do portal e publica a pagina. Rode com um perfil que possa criar CloudFront,
# API Gateway, Lambda e IAM (o usuario de desenvolvimento nao pode). O plano foi revisado antes
# (change set da stack nova: 14 recursos novos, nenhum alterado ou removido).
# Uso: AWS_PROFILE=<perfil-admin> scripts/deploy-portal.sh <chave-do-zip-no-bucket-de-artefatos>
set -euo pipefail
KEY=${1:?chave do zip, ex.: lambda/runpass-cd7d6463177c1473.zip}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export AWS_REGION=${AWS_REGION:-sa-east-1}
STACK=runpass-dev-portal
pv() { aws cloudformation describe-stacks --stack-name runpass-dev-app --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text; }
io() { aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
OP_CLIENT=$(io OperatorClient)
aws cloudformation deploy --stack-name "$STACK" --template-file "$ROOT/infra/portal.template.yaml" \
  --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    Environment=dev "DataStack=$(pv DataStack)" "ArtifactBucket=$(pv ArtifactBucket)" "ArtifactKey=$KEY" \
    "RunnerUserPoolId=$(pv RunnerUserPoolId)" "RunnerClientId=$(pv RunnerClientId)" \
    "OperatorUserPoolId=$(io OperatorPool)" "OperatorClientId=$OP_CLIENT" \
    "ErasureHmacParameter=$(pv ErasureHmacParameter)" "CursorKeyParameter=$(pv CursorKeyParameter)"
"$ROOT/scripts/deploy-portal-site.sh" "$STACK" "$OP_CLIENT"
