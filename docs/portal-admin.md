# Portal de administração

Página web para operadores (pedidos de corrida hoje; banners e acessos nas próximas fatias). **Candidato, não
implantado**: hospedagem em S3 + CloudFront e API própria exigem o aval de custo antes de provisionar
(`AGENTS.md`).

## Como a segurança funciona
- O navegador faz o login **direto no Cognito** (pool de operadores): senha e código do autenticador não passam
  pela nossa API. O token fica só em memória; fechar a aba encerra a sessão.
- A API do portal (`backend/runpass/admin_api.py`, Lambda `runpass.admin_entry.handler`) é **separada** da API
  dos corredores e só aceita tokens do pool de operadores. Para cada chamada ela exige:
  1. pool com **MFA obrigatório** (`ON`) e **sem lembrar dispositivos** (conferido a cada 5 min; se alguém
     afrouxar o pool, o portal recusa);
  2. `auth_time` do token de até **1 hora**;
  3. `OPERATOR#sub/ACCESS` **ativo** com a permissão da rota (`catalog_admin` para pedidos de corrida).
- Ao passar, grava o mesmo registro de sessão MFA que a ferramenta de terminal grava, e os serviços de revisão
  funcionam sem mudança. A decisão de cada pedido fica auditada (`EREQ#<id>/REV#<n>`).
- CORS só para a origem do próprio portal; CSP restrita (scripts e estilos só do site; conexões só ao Cognito e à
  API); HSTS, `X-Frame-Options: DENY`, sem referrer.
- **Mudança consciente de regra:** antes, o login de operador só existia num componente restrito, nunca por
  HTTP. Aqui a prova de MFA vem da configuração do pool + `auth_time`, e não de um login feito pela nossa API.

## Peças
- `portal/` página estática sem build (`index.html`, `app.js`, `lib.js`, `cognito.js`); testes da lógica pura:
  `make portal-test` (Node).
- `infra/portal.template.yaml` bucket privado + CloudFront (OAC), API HTTP, Lambda e permissões mínimas.
- `scripts/deploy-portal-site.sh` publica a página e gera o `config.js` (região, client id público, URL da API).

## Implantar (somente com autorização)
1. `make lambda-package` e subir o zip (mesmo fluxo da API dos corredores).
2. Criar a stack com `infra/portal.template.yaml` por change set, revisando antes de executar.
3. `AWS_PROFILE=... scripts/deploy-portal-site.sh <stack> <client-id-operador>`.
4. Operador entra pela URL do CloudFront (`PortalUrl`).

## Limites
- Hoje só pedidos de corrida (listar, vincular, aprovar, recusar) e busca de corridas para vincular.
- Aprovar banners (com crédito e base de autorização) e conceder/revogar acesso ainda são comandos do terminal.
- O cliente do pool de operadores usa `USER_PASSWORD_AUTH` (já era assim); migrar para SRP é melhoria futura.
