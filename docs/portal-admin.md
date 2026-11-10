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

## Abas e permissões
| Aba | Rota | Permissão | Notas |
|---|---|---|---|
| Pedidos de corrida | `/admin/edition-requests*`, `/admin/editions` | `catalog_admin` | vincular, aprovar, recusar |
| Atualizar catálogo | `GET/POST /admin/catalog/run` | `catalog_admin` | dispara a Lambda da rotina (assíncrono) só com modos da lista fechada (`semanal`, `simulacao`, `enriquecer`, `imagens`); 1 disparo a cada 10 min (a rotina gasta a cota da OpenAI); registra quem disparou; nada é publicado. `GET /admin/catalog/runs` lista os disparos e as execuções agendadas (7 dias) com a situação (aguardando, em execução, concluída, erro, tempo esgotado), lida dos registros START/REPORT da Lambda (permissão `logs:FilterLogEvents` só nesse grupo). `GET /admin/catalog/schedules` lista os agendamentos `runpass-<env>-catalogo-*` do EventBridge Scheduler com a próxima execução (calculada aqui no fuso do agendamento; só `cron` simples e `at`, `rate` aparece sem data; permissões `scheduler:GetSchedule` nesse prefixo e `scheduler:ListSchedules`, somente leitura) |
| Cadastros no app | `GET /admin/users/runners` | `user_admin` | quem criou conta (pool dos corredores): id curto, e-mail **mascarado**, situação, data; cada consulta fica auditada (`AUDIT#...`) |
| Banners | `GET /admin/banners/candidates`, `GET /admin/banners/published`, `POST /admin/banners/preview`, `/approve`, `/remove` | `catalog_admin` | lista as imagens candidatas da coleta mais recente (CSV `semanal/<data>/imagens/candidatas.csv` do bucket de relatórios do catálogo) já com a corrida provável do catálogo; mostra a prévia (a imagem como será publicada, sem metadados); **aprovar publica**: exige corrida, crédito, base de autorização (mín. 10 caracteres, fica só na tabela de operações) e a confirmação de que ela é verdadeira; permite imagem por endereço manual; retira banner com motivo (registrado). O servidor baixa a imagem: só https, sem usuário/senha, até 3 redirecionamentos revalidados, o IP da conexão precisa ser público (conferido depois de conectar e antes de pedir), até 6 MB, JPEG/PNG/WebP. Ação auditada |
| Custos | `GET /admin/costs` | `cost_read` | AWS (Cost Explorer, conta inteira: mês até agora, previsão, por dia, por serviço, 6 meses; cada consulta custa US$ 0,01 e fica 15 min em cache) e OpenAI (soma das linhas `uso_openai` que as Lambdas do catálogo imprimem; **estimativa**, não a fatura). O custo em dinheiro da OpenAI só aparece se os preços forem informados no deploy (`OPENAI_PRICE_IN_PER_MTOK`, `OPENAI_PRICE_OUT_PER_MTOK`, `OPENAI_PRICE_PER_SEARCH`, da página oficial de preços); sem eles o painel mostra só o consumo. Uma fonte fora do ar não esconde a outra |
| Operadores | `GET/POST /admin/operators`, `PUT .../{sub}/permissions`, `POST .../{sub}/revoke`, `.../reactivate`, `.../reset` | `user_admin` | lista quem entra no portal (situação e permissões); cria com convite por e-mail; altera permissões; retira o acesso (na hora: a API confere o acesso a cada chamada; também desativa o login e derruba as sessões); reativa; refaz senha e autenticador (apaga e recria o login com as mesmas permissões, sub novo). Proteções: ninguém altera o próprio acesso e a conta sempre mantém um `user_admin` ativo. Tudo auditado (`AUDIT#...`) |

- Primeiro acesso de um operador novo: o portal conduz a troca da senha temporária e o cadastro do autenticador
  (chave para digitar no app; MFA é obrigatório no pool) e entra com o token resultante.
- `user_admin` é nova: quem já é operador a recebe por `operator_tool.py grant --permission user_admin ...`
  (por outro responsável, como as demais).
- Quem tem `user_admin` pode conceder qualquer permissão: trate como acesso de administrador.

## Peças
- `portal/` página estática sem build (`index.html`, `app.js`, `lib.js`, `cognito.js`, `style.css`); testes da
  lógica pura: `make portal-test` (Node). O `config.js` é gerado pela API (região e client id públicos).
- `scripts/package-lambda.sh` inclui `portal/` no mesmo zip da API dos corredores.
- `infra/portal.template.yaml` Lambda, API HTTP, log groups e permissões mínimas.
- `scripts/deploy-portal.sh` cria/atualiza a stack e imprime a URL.

## Implantar (somente com autorização)
1. `make lambda-package` e subir o zip ao bucket de artefatos (mesmo fluxo da API dos corredores).
2. `AWS_PROFILE=<admin> scripts/deploy-portal.sh` (o usuário de desenvolvimento não pode criar
   API Gateway e IAM). Se uma criação anterior falhou, a stack fica em `ROLLBACK_COMPLETE` e precisa ser
   apagada antes de repetir.
3. Abrir a URL impressa (`PortalUrl`).

## Limites
- Contas de corredores só são lidas (não há suspensão pelo portal).
- A situação das execuções vem só dos registros de início e fim da Lambda: mostra se rodou, quanto durou e se deu erro ou tempo esgotado, mas não o conteúdo do relatório (ver os arquivos no S3 do catálogo).
- A lista de cadastros mostra até 1200 contas por consulta (o resumo avisa quando é parcial).
- O cliente do pool de operadores usa `USER_PASSWORD_AUTH` (já era assim); migrar para SRP é melhoria futura.
- Se um dia o CloudFront for liberado, dá para colocar a página nele sem mudar a API.
