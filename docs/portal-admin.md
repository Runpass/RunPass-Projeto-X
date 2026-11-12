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
| Pedidos de corrida | `/admin/edition-requests*`, `/admin/editions` | `catalog_admin` | vincular, aprovar, recusar **Aprovar e criar** (`POST /admin/edition-requests/{id}/approve`): acha a corrida do catálogo (mesma data e nome parecido) e só vincula; se não existir, **cria** a corrida com os dados do pedido (a equipe confere estado e distâncias; a distância vem do usuário e não tem fonte) e vincula na hora; sem o estado, o pedido vira `awaiting_load` e é **vinculado sozinho** quando a corrida entrar no catálogo (verificado ao abrir a aba e por `POST /admin/edition-requests/sweep`). A decisão fica na auditoria (`REV#`). Vincular a uma corrida existente continua em `/decision`. **Banner sugerido no pedido:** o corredor pode enviar a imagem da corrida ao pedir o cadastro (o app envia a imagem pelo fluxo normal de upload e o pedido leva só a referência). Nada publica sozinho: a equipe vê a imagem (`GET /admin/edition-requests/{id}/image`, só a cópia tratada) e, **depois do vínculo a uma corrida**, publica como banner da corrida (`POST .../banner`, exige crédito, base de autorização e confirmação) ou descarta (`POST .../banner/dismiss`). A lista `images` de `GET /admin/edition-requests` traz os aguardando decisão; publicar substitui o banner atual. O corredor vê `bannerState` (`published` ou `dismissed`) em Minhas solicitações. O papel do portal ganha `s3:GetObject` em `derived/*` do bucket de fotos. |
| Divergências | `GET /admin/divergences`, `POST /admin/divergences/{id}/decision`, `GET /admin/divergences/accepted.csv` | `catalog_admin` | lista as provas da coleta de enriquecimento mais recente em que a rotina **não decidiu sozinha**: pista parcial (prova confirmada, sem distância), ambígua (provas parecidas na mesma data) e sugestão de outra edição. Também entram as **"nada encontrado"**: se existe informação útil, aceita-se com os dados e a fonte (conta como o que a rotina deixou de achar); se não existe, descarta-se em um clique. A tela mostra a revocação (das conferidas, quantas tinham informação). **Aceitar** exige distâncias, link `https` da fonte e um trecho de até 160 caracteres (fato sem evidência é anulado); **reprovar** descarta, com motivo opcional. A decisão é imutável, registra quem e quando e vai para a auditoria. **Aceitar não publica nada no catálogo**: o CSV das aceitas sai no formato do importador (com `evidence_url` e `evidence_text` para conferência) e o operador importa com `import-csv`. Só leitura do S3 de relatórios (`semanal/*`) |
| Qualidade da busca | `GET /admin/quality` | `catalog_admin` | mostra, só leitura, a medição de acerto da busca do catálogo (extração do calendário, enriquecimento e conferência por amostra de 10/11/2026). Os números ficam em `backend/runpass/quality_report.py` e mudam por commit, depois de uma nova conferência a mão (documento `MEDICAO-ACERTO.md` do repositório do catálogo). É amostra de um dia e não mede a revocação do enriquecimento |
| Atualizar catálogo | `GET/POST /admin/catalog/run` | `catalog_admin` | dispara a Lambda da rotina (assíncrono) só com modos da lista fechada (`semanal`, `simulacao`, `enriquecer`, `imagens`); 1 disparo a cada 10 min (a rotina gasta a cota da OpenAI); registra quem disparou; nada é publicado. `GET /admin/catalog/runs` lista os disparos e as execuções agendadas (7 dias) com a situação (aguardando, em execução, concluída, erro, tempo esgotado), lida dos registros START/REPORT da Lambda (permissão `logs:FilterLogEvents` só nesse grupo). `POST /admin/catalog/schedules`, `PUT /admin/catalog/schedules/{nome}` e `DELETE /admin/catalog/schedules/{nome}` criam (nome `portal-<nome>`), alteram (dias, horário, pausar/ativar, rodada, máximo de provas, meses) e apagam agendamentos, **só do catálogo** (prefixo `runpass-<env>-catalogo-`). Lista fechada de tipos (`semanal`, `calendario`, `enriquecer`, `imagens`), só dias da semana + horário (no máximo 1 execução por dia, sem `rate()`) **ou uma execução única em uma data** (`at(...)`, futura e a até 1 ano; o agendamento some sozinho depois de rodar), no máximo 25 provas por execução e 20 agendamentos criados pelo portal; o destino é sempre a Lambda do catálogo, sem nova tentativa automática. Toda ação vai para a auditoria. Exige o parâmetro `CatalogSchedulerRoleArn` no portal (papel do agendador, da stack do catálogo); sem ele o portal só lê. **Os agendamentos da stack do catálogo também podem ser editados e apagados, mas isso os deixa diferentes do template do CloudFormation** (um deploy futuro pode recriá-los ou falhar; o parâmetro `ScheduleState` da stack volta a mandar no estado). `GET /admin/catalog/schedules` lista os agendamentos `runpass-<env>-catalogo-*` do EventBridge Scheduler com a próxima execução (calculada aqui no fuso do agendamento; só `cron` simples e `at`, `rate` aparece sem data; permissões `scheduler:GetSchedule` nesse prefixo e `scheduler:ListSchedules`, somente leitura) |
| Cadastros no app | `GET /admin/users/runners` | `user_admin` | quem criou conta (pool dos corredores): id curto, e-mail **mascarado**, situação, data; cada consulta fica auditada (`AUDIT#...`) |
| Banners | `GET /admin/banners/candidates`, `GET /admin/banners/published`, `POST /admin/banners/preview`, `/approve`, `/remove`, `/dismiss` | `catalog_admin` | lista as imagens candidatas da coleta mais recente (CSV `semanal/<data>/imagens/candidatas.csv` do bucket de relatórios do catálogo) já com a corrida provável do catálogo; mostra a prévia (a imagem como será publicada, sem metadados); **aprovar publica**: exige corrida, crédito, base de autorização (mín. 10 caracteres, fica só na tabela de operações) e a confirmação de que ela é verdadeira; permite imagem por endereço manual; retira banner com motivo (registrado). O servidor baixa a imagem: só https, sem usuário/senha, até 3 redirecionamentos revalidados, o IP da conexão precisa ser público (conferido depois de conectar e antes de pedir), até 6 MB, JPEG/PNG/WebP. Ação auditada Uma candidata **sai da lista** quando a mesma imagem já foi publicada, quando qualquer corrida do catálogo com nome e data parecidos já tem banner, ou quando é **excluída** (`/dismiss`: não volta nas próximas coletas e é auditada). Retirar o banner a devolve para a lista. Os banners publicados têm o botão "Excluir banner" (exige motivo) |
| Custos | `GET /admin/costs` | `cost_read` | AWS (Cost Explorer, conta inteira: mês até agora, previsão, por dia, por serviço, 6 meses; cada consulta custa US$ 0,01 e fica 15 min em cache) e OpenAI (soma das linhas `uso_openai` que as Lambdas do catálogo imprimem; **estimativa**, não a fatura). O custo em dinheiro da OpenAI só aparece se os preços forem informados no deploy (`OPENAI_PRICE_IN_PER_MTOK`, `OPENAI_PRICE_OUT_PER_MTOK`, `OPENAI_PRICE_PER_SEARCH`, da página oficial de preços); sem eles o painel mostra só o consumo. Uma fonte fora do ar não esconde a outra |
| Operadores | `GET/POST /admin/operators`, `PUT .../{sub}/permissions`, `POST .../{sub}/revoke`, `.../reactivate`, `.../reset` | `user_admin` | lista quem entra no portal (situação e permissões); cria com convite por e-mail; altera permissões; retira o acesso (na hora: a API confere o acesso a cada chamada; também desativa o login e derruba as sessões); reativa; refaz senha e autenticador (apaga e recria o login com as mesmas permissões, sub novo). Proteções: ninguém altera o próprio acesso e a conta sempre mantém um `user_admin` ativo. Tudo auditado (`AUDIT#...`) |

- Primeiro acesso de um operador novo: o portal conduz a troca da senha temporária e o cadastro do autenticador
  (chave para digitar no app; MFA é obrigatório no pool) e entra com o token resultante.
- `user_admin` é nova: quem já é operador a recebe por `operator_tool.py grant --permission user_admin ...`
  (por outro responsável, como as demais).
- Quem tem `user_admin` pode conceder qualquer permissão: trate como acesso de administrador.

## Custos reais da OpenAI (opcional)
A aba Custos replica a página Usage do console da OpenAI (gasto por dia, limite do mês, tokens, requisições, por
chave de API, por modelo, categorias) quando há uma **chave de administrador** (`sk-admin-...`) configurada;
sem ela, mostra só a estimativa pelos logs. A API de custos e de uso da OpenAI exige esse tipo de chave.
- **Risco a aceitar:** a chave de administrador gerencia a organização inteira (membros, chaves, projetos), não só
  lê custos. Por isso ela só é lida pela Lambda do portal, do SSM (SecureString), nunca é registrada nem enviada
  a outro host que não `api.openai.com`, e a página nunca a vê. Crie-a só se aceitar esse risco; revogue no
  console da OpenAI se houver suspeita.
- **Como habilitar:** (1) no console da OpenAI (Settings > Organization > Admin keys; só o dono da organização),
  crie a chave; (2) com o perfil de administrador da AWS, grave-a no SSM Parameter Store como SecureString
  (pelo console da AWS, para o valor não ficar no histórico do terminal), por exemplo `/runpass/dev/openai-admin-key`;
  (3) rode o deploy do portal com `OPENAI_ADMIN_KEY_PARAM=/runpass/dev/openai-admin-key` e, para filtrar o mesmo
  projeto do console, `OPENAI_PROJECT_ID=proj_...`.
- Dias em UTC; cache de 15 min; só uso de completions/respostas (imagens, embeddings etc. não entram).

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
