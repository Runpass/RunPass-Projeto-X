#!/usr/bin/env bash
# Cria/atualiza a stack do portal (Lambda + API HTTP que serve a pagina e as rotas de operador).
# Rode com um perfil que possa criar Lambda, API Gateway e IAM (o usuario de desenvolvimento nao pode).
# Empacota o codigo (o zip inclui a pasta portal/), envia ao bucket de artefatos e cria/atualiza a stack.
# Uso: AWS_PROFILE=<perfil-admin> scripts/deploy-portal.sh
#      DRY_RUN=1 scripts/deploy-portal.sh   mostra os parametros que seriam enviados; nao empacota nem publica.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export AWS_REGION=${AWS_REGION:-sa-east-1}
STACK=runpass-dev-portal
pv() { aws cloudformation describe-stacks --stack-name runpass-dev-app --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text; }
io() { aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
# Parametros opcionais (OpenAI e agendador): so entram quando a variavel de ambiente foi DEFINIDA. Sem ela, o
# `deploy` mantem o valor que ja esta na stack. Antes iam sempre, vazios por padrao, e uma publicacao comum
# apagava a chave da OpenAI, os precos e o papel do agendador que estavam no ar. Para limpar um valor de
# proposito, defina a variavel vazia (ex.: OPENAI_PROJECT_ID= scripts/deploy-portal.sh).
OPTIONAL=()
optional() { # optional <Parametro> <VARIAVEL_DE_AMBIENTE>
  if [ -n "${!2+definida}" ]; then OPTIONAL+=("$1=${!2}"); fi
}
optional OpenAiAdminKeyParameter OPENAI_ADMIN_KEY_PARAM
optional OpenAiProjectId OPENAI_PROJECT_ID
optional OpenAiPriceInPerMTok OPENAI_PRICE_IN_PER_MTOK
optional OpenAiPriceOutPerMTok OPENAI_PRICE_OUT_PER_MTOK
optional OpenAiPricePerSearch OPENAI_PRICE_PER_SEARCH
optional CatalogSchedulerRoleArn CATALOG_SCHEDULER_ROLE_ARN
# Simulacao: nao empacota, nao envia e nao chama a AWS. Mostra so os NOMES (os valores podem ser sensiveis).
if [ "${DRY_RUN:-}" = 1 ]; then
  echo "Sempre enviados: Environment DataStack ArtifactBucket ArtifactKey RunnerUserPoolId RunnerClientId" \
    "OperatorUserPoolId OperatorClientId ErasureHmacParameter CursorKeyParameter CatalogFunctionName CatalogReportBucket"
  printf 'Opcionais enviados nesta execucao:'
  for o in ${OPTIONAL[@]+"${OPTIONAL[@]}"}; do printf ' %s' "${o%%=*}"; done
  [ ${#OPTIONAL[@]} -gt 0 ] || printf ' (nenhum: os valores da stack sao mantidos)'
  echo
  exit 0
fi
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
    ${OPTIONAL[@]+"${OPTIONAL[@]}"}
echo "Portal: $(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='PortalUrl'].OutputValue" --output text)"
