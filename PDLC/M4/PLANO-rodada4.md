# Plano de implantacao - Rodada 4 (06/11/2026)

Status em 06/11/2026: **etapas A, B, C, D e E1 implementadas e commitadas no PR #24; nada publicado na AWS nem instalado**. Pendentes de autorizacao: deploy (backend das etapas B e E) e instalacao no iPhone/APK. E2 (dados reais) depende de credenciais. Ver `docs/catalogo-corridas.md`.
Base: PR #24 (rodadas 2 e 3 ja no DEV). Regras fixas: commits e PR para `dev`; deploy so com autorizacao; sem segredos no Git; dados sinteticos nos testes.

## O que foi verificado antes de planejar

| Fato | Evidencia |
| --- | --- |
| iPhone sem avisos tem causa provavel no codigo | `AppDelegate.swift` nao define `UNUserNotificationCenter.current().delegate`; o plugin exige isso para mostrar notificacao com o app aberto. O Android nao precisa disso, por isso funciona. |
| Mesmo corrigido, **app fechado nao recebe aviso em nenhum dos dois** | Os avisos locais dependem de um timer do app (45 s). O iOS suspende o app em segundos; no Android funciona so enquanto o processo vive. Aviso com o app fechado exige push remoto (APNs/FCM). |
| Nao ha biometria | Nao existe `local_auth`; `MainActivity` usa `FlutterActivity` (biometria exige `FlutterFragmentActivity`); falta `NSFaceIDUsageDescription` no iOS. |
| Catalogo ja existe, em DynamoDB | `/editions` filtra por `namePrefix`, `city`, `state`, `dateFrom/dateTo`, `distanceKm`; `/admin/editions` (POST/PATCH/archive); carga por `operator_tool load-catalog`; `country` entrou na rodada 2. |
| O documento `.md` assume outra stack | Pede PostgreSQL/Alembic/FastAPI + SQLAlchemy. O projeto e FastAPI sobre DynamoDB (um unico desenho de tabelas, contratos e SPEC ativos). |

## Decisoes que preciso de voce (recomendacao em primeiro)

1. **Busca de corridas: manter DynamoDB** e adaptar o documento, em vez de criar Postgres. Recomendado: o documento manda reutilizar a stack existente, e PostgreSQL seria custo novo e segundo banco. Exige sua confirmacao por mexer em desenho aprovado.
2. **Avisos com o app fechado (push remoto):** fora desta rodada, porque exige chave APNs (conta Apple Developer paga), projeto Firebase e SNS/Lambda (custo e autorizacao). Nesta rodada corrijo o iPhone para avisos com o app **aberto** e registro a limitacao. Quer abrir uma etapa propria de push depois?
3. **Biometria:** proponho **desbloqueio do app** (Face ID/Touch ID/digital) sobre o "manter conectado", e nao substituir a senha. Pergunta a cada abertura (ligavel em Configuracoes). Confirma?
4. **Filtros novos de busca (situacao da inscricao, raio por localizacao):** como filtro sobre o resultado (sem multiplicar linhas de indice no DynamoDB). Funciona no volume do MVP; medir antes de ampliar. De acordo?

## Etapas, ordem e validacao

### Etapa A - Ajustes de app e interacoes (sem backend novo, exceto B2)
| # | Pedido | Implementacao | Validacao automatica | Validacao humana (iPhone/Android) |
| --- | --- | --- | --- | --- |
| A1 | Pedidos para seguir nos avisos, aprovar ali | **Ja existe** (cartao no topo, Aceitar/Recusar). Verificar por que nao apareceu para voce: pedido so existe se o perfil do alvo for **privado**; hoje perfil publico gera "comecou a seguir". Se quiser, o aviso de novo seguidor ganha tambem "Seguir de volta". Acrescento no aviso os botoes Aceitar/Recusar tambem na lista da tela de Pedidos. | Teste de widget com pedido pendente (ja ha); novo teste do "Seguir de volta". | Conta A privada, conta B pede: A ve o pedido no topo e aceita sem sair dos avisos. |
| A2 | Seguidores e seguindo ao lado da foto; tirar "corridas" | Linha com seguidores e seguindo na mesma linha do avatar (estilo Instagram); remove o contador de corridas. | Teste de widget (chaves `profile-counts`). | Conferir nos dois aparelhos, incluindo texto grande. |
| A3 | Botao "Banner" colado em engrenagem/sino no iPhone | Mover o botao para o canto inferior esquerdo/direito do banner, longe da area segura do topo; respeitar `SafeArea` e notch. | Teste de widget de posicao (nao sobrepoe os icones do topo). | iPhone com Dynamic Island: separacao clara. |
| A4 | Entrar no perfil por comentarios | Avatar e nome em cada comentario abrem o perfil (outra pessoa: Seguir; eu: meu perfil). | Teste de widget (`comment-author-<id>`). | Tocar no avatar de um comentario. |

### Etapa B - Curtir e responder comentarios (backend + app)
| # | Implementacao | Validacao |
| --- | --- | --- |
| B1 | **Curtir comentario**: `PUT/DELETE /comments/{id}/like`, `likeCount` e `likedByMe` em `Comment`. Linha `CLIKE#<sub>` na particao do post, apontada por `CLIKEREF#` com `sharedKeys` (sai na exclusao da conta, como as curtidas de post). Idempotente. | Testes de backend: uma curtida por pessoa, descurtir, post nao visivel -> 404, exclusao da conta remove; contrato OpenAPI; teste de widget do coracao no comentario. |
| B2 | **Responder comentario** (como no Instagram): `parentId` opcional em `POST /posts/{id}/comments`; resposta de nivel unico (responder a resposta vira resposta ao comentario raiz); lista mostra respostas recuadas sob o pai, com "Ver N respostas". Apagar o pai apaga as respostas. | Testes: resposta a pai de outro post -> 422; apagar pai remove filhas e linhas compartilhadas; ordenacao; limite de profundidade. |
| B3 | Aviso para o autor do comentario quando alguem curte ou responde (tipos `comment_like`, `reply`), derivados como os demais. | Teste de `notifications` com os dois tipos; apagar aviso funciona. |
| B4 | Deploy da Etapa B (apenas Lambdas) com seu "pode seguir". | Rotas existem (401/405), registro no S09. |

### Etapa C - Biometria (Face ID, Touch ID, digital)
1. Pacote `local_auth`; Android: `MainActivity` -> `FlutterFragmentActivity`, permissao `USE_BIOMETRIC`; iOS: `NSFaceIDUsageDescription`.
2. Configuracoes: chave "Entrar com biometria" (so aparece se o aparelho tem biometria cadastrada). Ao ligar, pede a biometria uma vez para confirmar.
3. Abertura do app com sessao guardada: se a chave estiver ligada, pede biometria **antes** de renovar o acesso; falhou/cancelou -> tela de senha (nunca deixa preso). Segredo continua so o token de renovacao no Keychain/Keystore; biometria e uma trava local, nao troca a senha do Cognito.
4. Desligar a biometria ou sair da conta apaga a preferencia.
- **Validacao automatica:** teste do fluxo com `local_auth` simulado (sucesso, cancelamento, indisponivel, falha repetida cai na senha; chave oculta sem biometria).
- **Validacao humana (obrigatoria, so no aparelho):** iPhone com Face ID e Android com digital/rosto: ligar, fechar o app, abrir, autenticar; negar de proposito e conferir que cai na senha; sair da conta e conferir que a chave some. **Eu nao consigo provar Face ID sem o aparelho.**

### Etapa D - Avisos no iPhone (app aberto)
1. `AppDelegate.swift`: definir o delegate de notificacoes e `UNNotificationPresentationOptions` (banner, som) para exibir com o app em primeiro plano.
2. Pedir a permissao na primeira abertura apos o login (hoje so no primeiro ciclo de checagem) e mostrar na tela de Configuracoes o estado ("permitido/negado, abrir Ajustes").
3. Registrar claramente a limitacao do app fechado (decisao 2).
- **Validacao automatica:** teste do texto/`announce` ja existente; teste de estado da permissao simulado.
- **Validacao humana:** iPhone com a permissao ligada: a conta B curte/comenta e o banner aparece em ate ~45 s com o app aberto; com o app em segundo plano vale so por poucos segundos (limite do iOS, nao e defeito).

### Etapa E - Busca de corridas (documento `FEATURE_BUSCA_CORRIDAS_IA.md`, adaptado ao DynamoDB)
Mapeamento do documento para o que ja existe e o que falta:

| Documento | Situacao | Plano |
| --- | --- | --- |
| Busca com filtros e paginacao, ordenar por data | **Existe** (`/editions`) | Manter; ampliar ordenacao (`name_asc`, `date_desc`) e busca por nome **contendo** a palavra (hoje e por prefixo), via filtro sobre o resultado |
| Detalhe, `last_verified_at`, `event_status`, `registration_status` | **Falta** | Campos opcionais na edicao (`registrationStatus`, `eventStatus`, `lastVerifiedAt`, `venue`, `latitude/longitude`); `registrationStatus` nunca assume "aberta" quando desconhecido |
| Filtro por situacao da inscricao e por raio (lat/lon/radius) | **Falta** | Filtro pos-consulta (Haversine) com limites; 422 para parametros incompletos |
| Cadastro admin e atualizacao | **Existe** (`/admin/editions`) | Incluir os campos novos e auditoria ja existente |
| Importacao CSV com `dry_run`, idempotente, relatorio por linha | **Parcial** (carga por fixture JSON) | Importador CSV (`operator_tool import-csv --dry-run`) usando o importador real; reimportar nao cria versao se igual (ja garantido); relatorio por linha; limite de tamanho |
| Proveniencia da fonte e execucoes de ingestao | **Falta** | `source`, `externalId`, `firstSeenAt/lastSeenAt` na edicao e registro de execucoes na tabela de operacoes; nao apagar prova ausente numa coleta |
| Deduplicacao entre fontes e `needs_review` | **Falta** | Chave `(source, externalId)` deterministica; candidatas por nome+data+cidade vao para o fluxo de revisao ja existente (`edition-requests`); sem merge automatico |
| Prioridade de edicao manual sobre importacao | **Falta** | Politica explicita: edicao admin > importacao; importacao nao sobrescreve campo editado |
| Adapters ACTIVE e Let's Do This | **Falta** | Interfaces e mappers com **flag desligada por padrao**, testados so com respostas ficticias (timeout, 401, 429, 5xx, paginacao). **Nao conecto a servico real**: sem credenciais, licenca e cobertura confirmadas. |
| App: tela Explorar com debounce, filtros, estados | **Parcial** (Corridas ja tem lupa e filtros) | Debounce de 400 ms, filtro de inscricao e distancia, ordenacao; mantem estados vazio/erro/retry |
| PostgreSQL/Docker Compose/Alembic | **Nao se aplica** | Substituidos por `make check` e o harness local (`api-local`) ja existentes |

- **Validacao automatica:** testes de backend para cada filtro novo (combinados), importacao CSV duas vezes sem duplicar, dry-run sem escrever, edicao manual preservada, adapters desligados sem token, contratos com payload valido/incompleto/401/429/5xx/timeout; contrato OpenAPI e `cfn-lint`; testes de widget da busca.
- **Validacao humana:** carregar o CSV de exemplo (fictício, identificado como tal) no DEV com operador MFA; buscar por nome, UF, datas, distancia e inscricao; abrir detalhe.
- Requer deploy do backend e `load-catalog`/`import-csv` com operador MFA (sua autorizacao e MFA).

## Ordem sugerida e pontos de parada
1. **A + D** (so app e AppDelegate): ajustes de tela e avisos no iPhone. Instalo no iPhone para voce testar.
2. **C** (biometria): app apenas; precisa do seu aparelho para validar.
3. **B** (comentarios): backend + app; deploy com autorizacao.
4. **E** (busca de corridas): maior; dividir em E1 (campos, filtros, CSV) e E2 (adapters desligados).

Em cada ponto: `make check`, `make mobile-check`, build iOS/Android, commit e PR; o deploy e as instalacoes so apos o seu "pode seguir".

## Riscos e limites declarados
- Face ID so e comprovavel no aparelho; automatico cobre a logica, nao o hardware.
- Push com o app fechado continua fora ate haver chaves APNs/FCM e orcamento.
- Busca por raio e inscricao como filtro sobre o resultado nao escala alem do MVP; medir antes de ampliar.
- Adapters ACTIVE/Let's Do This ficam sem uso ate haver credenciais, termos e cobertura brasileira validados.
- Responder comentarios aumenta a leitura por post; limite de 1000 comentarios por publicacao segue valendo.
