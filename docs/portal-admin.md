# Portal de administração

Página web para operadores (pedidos de corrida hoje; banners e acessos nas próximas fatias). **Candidato, não
implantado**: hospedagem em S3 + CloudFront e API própria exigem o aval de custo antes de provisionar
(`AGENTS.md`).

## Como funciona
- **Uma só origem:** uma Lambda atrás de uma API HTTP do API Gateway (HTTPS) serve a página (`/`) **e** as rotas
  de operador (`/admin/*`). Não há S3 nem CloudFront: a conta AWS ainda não foi verificada para criar recursos
  do CloudFront (erro `Your account must be verified before you can add new CloudFront resources`), e essa
  decisão também reduz custo e peças.
- O navegador faz o login **direto no Cognito** (pool de operadores): senha e código do autenticador não passam
  pela nossa API. O token fica só em memória; fechar a aba encerra a sessão.
- As rotas `/admin/*` (`backend/runpass/admin_api.py`) são **separadas** da API dos corredores e só aceitam
  tokens do pool de operadores. Para cada chamada exigem:
  1. pool com **MFA obrigatório** (`ON`) e **sem lembrar dispositivos** (conferido a cada 5 min; se alguém
     afrouxar o pool, o portal recusa);
  2. `auth_time` do token de até **1 hora**;
  3. `OPERATOR#sub/ACCESS` **ativo** com a permissão da rota (`catalog_admin` para pedidos de corrida).
- Ao passar, grava o mesmo registro de sessão MFA que a ferramenta de terminal grava, e os serviços de revisão
  funcionam sem mudança. A decisão de cada pedido fica auditada (`EREQ#<id>/REV#<n>`).
- **Toda resposta** leva CSP restrita (scripts e estilos só do site, sem `unsafe-inline`; conexões só ao Cognito
  e à própria origem), HSTS, `X-Frame-Options: DENY`, `nosniff`, sem referrer e `Cache-Control: no-store`.
  Só uma lista fechada de arquivos é servida (nada de caminho vira nome de arquivo).
- **Mudança consciente de regra:** antes, o login de operador só existia num componente restrito, nunca por
  HTTP. Aqui a prova de MFA vem da configuração do pool + `auth_time`, e não de um login feito pela nossa API.

## Peças
- `portal/` página estática sem build (`index.html`, `app.js`, `lib.js`, `cognito.js`, `style.css`); testes da
  lógica pura: `make portal-test` (Node). O `config.js` é gerado pela API (região e client id públicos).
- `scripts/package-lambda.sh` inclui `portal/` no mesmo zip da API dos corredores.
- `infra/portal.template.yaml` Lambda, API HTTP, log groups e permissões mínimas.
- `scripts/deploy-portal.sh` cria/atualiza a stack e imprime a URL.

## Implantar (somente com autorização)
1. `make lambda-package` e subir o zip ao bucket de artefatos (mesmo fluxo da API dos corredores).
2. `AWS_PROFILE=<admin> scripts/deploy-portal.sh <chave-do-zip>` (o usuário de desenvolvimento não pode criar
   API Gateway e IAM). Se uma criação anterior falhou, a stack fica em `ROLLBACK_COMPLETE` e precisa ser
   apagada antes de repetir.
3. Abrir a URL impressa (`PortalUrl`).

## Limites
- Hoje só pedidos de corrida (listar, vincular, aprovar, recusar) e busca de corridas para vincular.
- Aprovar banners (com crédito e base de autorização) e conceder/revogar acesso ainda são comandos do terminal.
- O cliente do pool de operadores usa `USER_PASSWORD_AUTH` (já era assim); migrar para SRP é melhoria futura.
- Se um dia o CloudFront for liberado, dá para colocar a página nele sem mudar a API.
