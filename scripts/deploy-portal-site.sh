#!/usr/bin/env bash
# Publica a pagina do portal (portal/*) no bucket do site e invalida o cache do CloudFront.
# Uso: AWS_PROFILE=... scripts/deploy-portal-site.sh <stack-do-portal> <client-id-do-pool-de-operadores>
# Gera o config.js com a regiao, o client id (publico) e a URL da API; nenhum segredo entra na pagina.
set -euo pipefail
STACK=${1:?stack do portal}
CLIENT_ID=${2:?client id do pool de operadores}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
BUCKET=$(out SiteBucketName); API=$(out ApiUrl); DIST=$(out DistributionId)
REGION=${AWS_REGION:-sa-east-1}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$ROOT"/portal/{index.html,style.css,app.js,lib.js,cognito.js} "$TMP"/
cat > "$TMP/config.js" <<CFG
export default { region: '$REGION', clientId: '$CLIENT_ID', apiUrl: '$API' };
CFG
aws s3 sync "$TMP" "s3://$BUCKET" --delete --cache-control "no-cache" --only-show-errors
aws cloudfront create-invalidation --distribution-id "$DIST" --paths '/*' --query 'Invalidation.Id' --output text
echo "Portal: $(out PortalUrl)"
