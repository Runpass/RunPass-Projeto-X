# S09 — Integração DEV e aceite da primeira entrega

Data: 02/11/2026. Estado: **preparação local**. Nenhum recurso foi provisionado.

## Gate de entrada

| Pré-condição | Estado | Evidência necessária antes do deploy |
| --- | --- | --- |
| S02–S08 disponíveis | Parcial | S02–S04, S06–S07 em revisão; S05 e S08 ainda têm pendências de dispositivo/objetos/mobile |
| Orçamento completo e teto autorizado | Atendido para DEV em 04/11/2026 | Teto de **R$ 1.000/mês** autorizado pelo usuário em 01/11/2026. Itens antes excluídos incorporados em `ORCAMENTO-RunPass-DEV.md`: DEV em US$ 9,95/mês (US$ 45,44 com reserva e contingência), cerca de 25% do teto, com PTAX de R$ 5,4935 (03/11/2026). Impostos e IOF seguem não verificados (ler na primeira fatura). Rever se o change set ou o custo observado indicar ultrapassagem |
| Conta AWS DEV isolada | Parcial | Conta padrão `<ID da conta DEV>` criada pelo usuário, região `sa-east-1`, perfil `runpass-dev-sa`; usuário IAM `runpass-dev-thiago` (renomeado de `runpass-dev-operator` em 03/11/2026, mesmo `UserId` e MFA) com MFA por app autenticador; o perfil `runpass-dev-sa` usa esse usuário, confirmado por `sts get-caller-identity` em 03/11/2026; responsáveis: dois, nomeados pelo usuário em 02/11/2026, com nomes fora do Git; os dois são responsáveis principais e substitutos um do outro; Rafael tem usuário IAM próprio, criado pelo usuário em 03/11/2026 (substitui a decisão de usuário compartilhado de 02/11/2026, ver seção abaixo); falta confirmar o MFA do raiz |
| GitHub OIDC | Template preparado, não aplicado | `infra/deploy-role.template.yaml` (cfn-lint aprovado). Repositório oficial: `Runpass/RunPass-Projeto-X` (conta de usuário `Runpass`, parâmetro `GitHubOrg=Runpass`), decidido em 03/11/2026. O Environment `dev` já existe (04/11/2026); falta aplicar o papel após autorização; o `aud` e o `sub` do token estão presos ao repositório e ao Environment |
| Orçamento de custo | Aplicado em 04/11/2026 | `runpass-dev-mensal` com limite de US$ 54,61/mês (30% do teto, R$ 300 com a PTAX de R$ 5,4935) e alertas em 50%, 80% (real) e 100% (previsto), cada um com os quatro e-mails definidos (verificado por leitura na AWS). Alteração feita pelo console; `infra/cost.template.yaml` segue como referência, não aplicado. Conferir no console que impostos continuam incluídos (o campo deixou de aparecer na API) |
| GitHub Environment `dev` | Criado em 04/11/2026 (verificado por `gh api`): `dev`, `hom` e `prod` com `required_reviewers` (`thicost` e `Moura7`) e restrição de branch (`dev`→`dev`, `hom`→`hom`, `prod`→`main`); sem variáveis | Bloqueio liberado para o papel OIDC. O deploy continua dependendo da autorização explícita de provisionamento. Registro abaixo |
| Alertas operacionais | Preparado, não aplicado | Quatro destinatários definidos pelo usuário em 04/11/2026; os endereços ficam fora do Git e entram como parâmetros `AlertEmail1` a `AlertEmail4` da stack de dados. O tópico passou a usar chave KMS própria, porque alarmes do CloudWatch não publicam em tópico cifrado com `alias/aws/sns`. Escalonamento definido em 04/11/2026: Thiago primeiro, Rafael segundo (prazo de resposta ainda não definido). Falta provar o recebimento no deploy: cada destinatário confirma a assinatura e um alarme de teste deve chegar |
| Autorização de provisionamento | Concedida em 04/11/2026 (parcial) | O usuário confirmou em conversa que Thiago e Rafael autorizam: bucket de artefatos, chaves no SSM, envio do artefato e criação dos change sets. **A execução de cada change set exige revisão e aprovação antes.** PROD e beta seguem sem autorização. Registro abaixo |

Enquanto qualquer item obrigatório estiver bloqueado, comandos de criação de stack, upload de artefato ou deploy não devem ser executados.

O teto aprovado é limite financeiro para DEV, não estimativa convertida para USD, nem autorização de PROD, beta ou cobrança acima desse valor. Se a previsão do change set, custo observado ou componentes obrigatórios indicarem ultrapassagem, o provisionamento deve parar para nova aprovação.

## Infraestrutura candidata preparada

`infra/identity.template.json` mantém Cognito separado para corredores e operadores, com TOTP obrigatório para operadores. `infra/data.template.yaml` acrescenta:

- seis tabelas DynamoDB on-demand com chaves `PK/SK`, criptografia e proteção de deleção em PROD;
- PITR nos dados ativos e ausência deliberada de PITR no ErasureControl;
- buckets privados/versionados separados para medalhas e auditoria;
- lifecycle complementar para temporários e auditoria, sem substituir remoção ativa;
- duas filas standard e respectivas DLQs, retenção de um dia, visibility de 60 segundos e redrive após cinco recepções;
- tópico de alertas cifrado com chave KMS própria (a chave `alias/aws/sns` impede o CloudWatch de publicar), assinaturas por e-mail opcionais (`AlertEmail1` a `AlertEmail4`) e alarmes para mensagens visíveis nas DLQs.

`make infra-check` valida os três templates em `sa-east-1`. Os templates não contêm nomes globais fixos, destinatários, IDs de conta, credenciais ou dados reais.

`infra/app.template.yaml` acrescenta a composição executável candidata, também não aplicada:

- API HTTP com rota única para a Lambda, limitação de requisições e log de acesso sem caminho nem query string;
- cinco funções arm64 com papéis próprios: API, consumidores `score` e `audit`, publicador acionado por Streams e manutenção agendada;
- manutenção a cada cinco minutos para reconciliação, expiração e exclusão de contas;
- logs com 7 dias em DEV e 30 em PROD, conforme retenção aprovada, e alarmes de erro da API e da manutenção.

Memória, timeouts e agenda são hipóteses a medir em DEV. A regra agendada usa o EventBridge apenas como relógio, sem barramento geral de eventos. O finalize da foto continua síncrono na Lambda da API, por isso ela usa 1 GB; separar em worker só se a medição justificar.

Decisões técnicas desta preparação:

- **Runtime `python3.12`.** Pillow 13 não publica wheel arm64 compatível com o `python3.11` da Lambda (glibc 2.26). A resolução foi testada com `pip download`; a CI testa 3.11 (base local) e 3.12.
- **Segredos em SSM Parameter Store (SecureString).** Sem custo no nível padrão e sem valor em template. Os parâmetros são criados fora do CloudFormation; publicador e consumidores não recebem a chave de cursor.
- **Pacote:** `make lambda-package` gera zip local (14 MB, 46 MB descompactado) sem o harness local nem boto3, que vem do runtime.

## Ainda necessário antes da integração

1. Medir os limites acima e confirmar as permissões IAM em DEV; cfn-lint não comprova que elas bastam.
2. Região `sa-east-1` mantida em 02/11/2026 (ver SPEC), na conta `<ID da conta DEV>`. A conta de projeto `<ID da conta de projeto>` só opera em `us-east-2` e não é usada para o RunPass.
3. Fechar assinatura de artefatos e o papel OIDC de deploy. `.github/workflows/check.yml` só executa verificações e não acessa AWS.
4. Gerar change set somente leitura, estimativa atualizada e revisão humana; aplicar apenas após autorização.
5. Executar jornada em DEV: autenticação → catálogo → rascunho → imagem → conclusão → avaliação/medalha → edição/exclusão.
6. Medir imagem em cinco segundos e RunScore em dez segundos; executar carga, DLQ/replay, alarmes, permissões negativas e exclusões.
7. Ensaiar restore com tráfego fechado, incremento de `dispatchEpoch` e reaplicação dos controles de exclusão antes da promoção.
8. Executar Android e iPhone reais. Simulador e adaptadores locais não contam como evidência dos serviços AWS.

Roteiro da jornada, testes transversais e modelo do relatório: `S09-roteiro-e-relatorio.md` (modelo, nada executado).

## Evidências a capturar

Registrar IDs de execução e timestamps, não tokens ou payloads pessoais: change set revisado, versão do artefato, outputs das stacks, testes por serviço, métricas p50/p95/p99, mensagens DLQ/replay, recebimento de alarme, relatório de restore, limpeza e custo observado. Diferenciar claramente falha, não executado e aprovado.

S09 não autoriza PROD, beta ou lojas. Promoção exige aprovação própria e usa os mesmos artefatos validados em DEV.

## Acesso à conta — 02/11/2026

Conta `<ID da conta DEV>`, `sa-east-1`, perfil local `runpass-dev-sa`. Criados o grupo `runpass-dev-operators`, a política gerenciada `RunPassDevOperator` e o usuário `runpass-dev-operator`, com senha temporária de troca obrigatória. A política libera 12 serviços somente em `sa-east-1`, a gestão de roles `runpass-*` e exige MFA para todo o resto. Simulação (`simulate-principal-policy`): permite CloudFormation, Lambda e DynamoDB em `sa-east-1` com MFA; nega outra região, falta de MFA, roles fora do prefixo e criação de usuários ou políticas. A simulação não comprova que as permissões bastam para o deploy; isso se prova no change set. O prefixo `runpass-` vale para nomes de stack e de roles, e o formato exato das ações `aws-mcp:*` ainda deve ser confirmado no primeiro uso pelo usuário IAM.

A política recebeu também a política gerenciada `SignInLocalDevelopmentAccess` (só `signin:AuthorizeOAuth2Access` e `signin:CreateOAuth2Token`), sem a qual o `aws login` do usuário IAM é negado. O `aws login` autoriza a sessão aberta no navegador padrão; com o raiz aberto, o perfil recebia as credenciais do raiz.

## Validações e preparação — 02/11/2026

- **Templates no CloudFormation real:** `validate-template` em `sa-east-1`, com o usuário `runpass-dev-operator`, aceitou os três templates sem criar recursos. `app.template.yaml` exige apenas `CAPABILITY_IAM` e tem 11 parâmetros. Isso valida sintaxe e capacidades; não prova que as permissões bastam nem que o deploy funciona.
- **Tarifas:** das oito listas de preço, sete têm a mesma data de publicação da coleta de 26/10. A do Lambda foi republicada em 30/10; comparadas as 12 linhas coletadas, nenhuma tarifa mudou. Os preços de São Paulo seguem vigentes. O cálculo usa a tarifa x86 do Lambda e o desenho usa arm64, que é mais barata, então a estimativa não subestima por esse motivo. Os itens excluídos de `ORCAMENTO-RunPass-preliminar.md` continuam sem estimativa.

## Bloqueio: GitHub Environment `dev` com aprovadores (liberado em 04/11/2026)

**O deploy fica bloqueado até o Environment `dev` do repositório existir com aprovadores obrigatórios.** O papel `runpass-dev-gha-deploy` só aceita tokens com `sub` igual a `repo:<org>/<repo>:environment:dev`. Sem o Environment nenhum workflow consegue assumir o papel (falha fechada). Um Environment criado sem aprovadores não pode ser aceito: o repositório é público e qualquer pessoa com escrita poderia disparar um deploy sem revisão. Nenhum workflow de deploy deve ser adicionado antes disso.

Estado verificado em 04/11/2026: `Runpass/RunPass-Projeto-X`, repositório público de conta de usuário, com os branches `dev`, `hom` e `main` e rulesets ativos (a `dev` exige pull request, verificado), sem nenhum Environment. A conta `thicost` tem `push` sem `admin`, que não basta para criar Environments; quem cria é o dono da conta `Runpass` ou um administrador. O repositório anterior (`Moura7/RunPass-Projeto-X`) deixou de ser o destino.

### Passo a passo (feito pelo dono ou administrador do repositório)

1. Abrir `https://github.com/Runpass/RunPass-Projeto-X/settings/environments`.
2. Clicar em **New environment**, nomear exatamente `dev` (minúsculas, igual ao parâmetro `GitHubEnvironment` do template) e confirmar com **Configure environment**. Os Environments `hom` e `prod` seguem o mesmo roteiro, quando houver ambiente correspondente.
3. Marcar **Required reviewers** e adicionar os dois responsáveis (Thiago e Rafael). Deixar **Prevent self-review** desmarcado: com apenas dois aprovadores, marcá-lo exigiria sempre o outro responsável. Se preferir a regra mais estrita, marque e registre aqui.
4. Em **Deployment branches and tags**, escolher **Selected branches and tags** e adicionar a regra do branch correspondente: `dev` para o Environment `dev`, `hom` para `hom` e `main` para `prod`. Isso impede deploy a partir de outros branches.
5. Não definir secrets nem variáveis com credenciais no Environment. O papel é assumido por OIDC; o ARN do papel não é segredo e pode ser variável de repositório.
6. Salvar com **Save protection rules**.
7. Os branches `dev`, `hom` e `main` já têm rulesets ativos que exigem pull request. Conferir em Settings → Rules que a verificação "Verificações locais" também é exigida, para que só código revisado chegue ao Environment.
8. Verificar sem usar o navegador, com uma conta que tenha acesso:

```
gh api repos/Runpass/RunPass-Projeto-X/environments/dev \
  --jq '{name, rules: [.protection_rules[] | {type}], branches: .deployment_branch_policy}'
```

O resultado deve mostrar uma regra `required_reviewers` e uma política de branches personalizada. Se a lista de regras vier vazia, o bloqueio continua valendo.

9. Registrar neste documento a data da criação, quem aprovou o desenho e o resultado do comando acima (sem tokens).

### Critério para liberar o bloqueio

Liberado somente quando o comando do passo 8 mostrar `required_reviewers` e restrição ao branch `dev`, e o resultado estiver registrado aqui. Isso libera apenas a criação do papel OIDC, que ainda exige a autorização explícita de provisionamento descrita no gate de entrada.

### Registro da liberação (passo 9)

- **Data:** 04/11/2026. Environments criados por quem administra a conta `Runpass`; o desenho (aprovadores, restrição de branch, sem segredos) foi aprovado pelo usuário em 03/11/2026.
- **Resultado do passo 8** (`gh api .../environments/dev`, sem tokens): regras `required_reviewers` e `branch_policy`, `custom_branch_policies: true`.
- **Verificação independente** (conta `thicost`, 04/11/2026): `dev`, `hom` e `prod` existem; aprovadores `thicost` e `Moura7` nos três, com `prevent_self_review: false`; restrições de branch `dev`, `hom` e `main`, respectivamente; `dev` sem variáveis.
- **Acesso AWS (04/11/2026):** o usuário informou que o primeiro login e o MFA do Rafael e o segundo MFA do root estão ok; o assistente não verificou.
- **Pendente:** conferir em Settings → Rules que a verificação "Verificações locais" é exigida pelos rulesets (só a exigência de pull request foi verificada).

Isso libera apenas a criação do papel OIDC. Ele ainda exige a autorização explícita de provisionamento descrita no gate de entrada, e os pré-requisitos de AWS (acesso do Rafael, alertas, orçamento, change sets) seguem abertos.

## Sequência de implantação proposta (não executada)

Comandos exatos, parâmetros e a ordem das stacks: `docs/deploy-dev.md` (roteiro preparado em 04/11/2026, nada executado). Pacote da Lambda gerado localmente em 04/11/2026: 14,6 MB (46 MB descompactado), sem o harness local, SHA-256 `4cc03e9d4ca9ce3e999c0b4a589dc708fb144660175d07c00f667b48c202da4f` (artefato local, ainda não enviado).

Nada abaixo foi executado, e criar stack ou enviar artefato continua dependendo de autorização explícita. Nomes de stack começam com `runpass-` para casar com a política do operador.

1. Criar o bucket de artefatos em `sa-east-1`, privado e versionado, fora do CloudFormation.
2. Criar no SSM dois SecureString com valores aleatórios: a chave HMAC de exclusões (32 bytes) e a chave Fernet de cursores (32 bytes em base64url). Os valores não passam por templates, Git nem chat.
3. `make lambda-package`, enviar o zip ao bucket e anotar a versão do objeto.
4. Gerar change set `CREATE` de `runpass-dev-identity` e de `runpass-dev-data` e revisar. Passar os endereços de alerta como parâmetros `AlertEmail1` a `AlertEmail4` na linha de comando, sem gravá-los em arquivo versionado. Criar o change set cria uma stack vazia em `REVIEW_IN_PROGRESS`, sem recursos.
5. Aplicar identidade e dados somente após aprovação; depois gerar e revisar o change set de `runpass-dev-app`, que depende dos exports da stack de dados.
6. Rodar a jornada da seção "Ainda necessário antes da integração", com carga mínima e dados sintéticos.

Ainda bloqueiam o provisionamento: papel OIDC do GitHub (repositório registrado e Environment criado; falta aplicar o papel após autorização), destinatário e teste dos alertas operacionais, MFA do raiz confirmado e a autorização explícita dos dois responsáveis.

## Usuário compartilhado — decisão de 02/11/2026 (substituída em 03/11/2026)

**Substituída:** em 03/11/2026 o usuário `runpass-dev-operator` foi renomeado para `runpass-dev-thiago` e foi criado um usuário IAM próprio para o Rafael, no grupo `runpass-dev-operators`. Cada pessoa tem agora o seu MFA e o seu rastro no CloudTrail, e os riscos abaixo deixam de valer para o acesso diário. Pendente: confirmar o MFA e o primeiro login do Rafael, e o segundo MFA do raiz. O texto abaixo fica como histórico.

Thiago e Rafael usariam o mesmo usuário IAM, `runpass-dev-operator`, por decisão do usuário. Riscos aceitos e mitigações:

- **Sem rastreio por pessoa.** Os registros da AWS (CloudTrail) mostram o usuário, não quem agiu. Para distinguir, o nome da sessão não ajuda no console; combinar horários ou registrar no chamado quem fez a mudança.
- **MFA em um único aparelho.** O dispositivo cadastrado está no celular de uma pessoa. Perdê-lo trancaria os dois, como ocorreu com o raiz. Mitigação: o raiz, que tem o seu MFA, redefine o do operador (`deactivate-mfa-device`), e o app deve ter backup ou sincronização ativa.
- **Troca de pessoa.** Se alguém deixar o projeto, trocar a senha e refazer o MFA do usuário.
- **Segredos.** A senha nunca vai para Git, chat ou issue; só por gerenciador de senhas ou canal fechado.
- **Alternativa recomendada, não adotada.** Um usuário por pessoa, no mesmo grupo, devolve o rastreio individual sem custo. Reavaliar antes de PROD.

## Registro de provisionamento — 04/11/2026

Autorização informada pelo usuário em conversa (Thiago e Rafael), com o roteiro de `docs/deploy-dev.md`. Executado com o usuário `runpass-dev-thiago`, conta `263097734277`, `sa-east-1`.

| Recurso | Resultado |
| --- | --- |
| Bucket de artefatos `runpass-dev-artifacts-263097734277` | Criado. Versionamento ativo, acesso público bloqueado, criptografia `AES256` por padrão e política que nega transporte sem TLS (verificado por leitura) |
| SSM `/runpass/dev/erasure-hmac` e `/runpass/dev/cursor-key` | Criados como `SecureString`, versão 1. Valores gerados e enviados por pipe, sem aparecer em tela, arquivo ou Git. Formato conferido sem exibir o valor: HMAC com 64 caracteres (mínimo de 32 bytes) e chave Fernet válida de 44 caracteres |
| Artefato `lambda/runpass-4cc03e9d4ca9ce3e.zip` | Enviado (14.656.220 bytes). O checksum SHA-256 do objeto no S3 coincide com o do pacote local (`4cc03e9d4ca9ce3e999c0b4a589dc708fb144660175d07c00f667b48c202da4f`) |
| Change set `inicial` de `runpass-dev-identity` | Criado, `CREATE_COMPLETE`, **não executado**. 4 recursos novos: 2 pools Cognito (corredores e operadores) e 2 clientes. Sem capacidades extras |
| Change set `inicial` de `runpass-dev-data` | Criado, `CREATE_COMPLETE`, **não executado**. 23 recursos novos: 6 tabelas DynamoDB, 2 buckets S3 e 2 políticas, 4 filas SQS (2 DLQs), 1 tópico SNS com 4 assinaturas, 1 chave KMS e seu alias, 2 alarmes. Sem capacidades extras |

As duas stacks de revisão estão em `REVIEW_IN_PROGRESS`, sem recursos. Os e-mails de alerta foram passados como parâmetros e não estão no Git.

**Pendente:** revisão dos change sets por Thiago e Rafael e aprovação para executar; depois, change set da stack `runpass-dev-app`, que depende dos exports da stack de dados e das saídas da identidade. Nada além disso foi criado.

### Execução dos change sets — 04/11/2026

Thiago e Rafael revisaram os change sets e autorizaram a execução de identidade e dados.

| Stack | Resultado |
| --- | --- |
| `runpass-dev-identity` | Executada, `CREATE_COMPLETE`. 2 pools Cognito e 2 clientes |
| `runpass-dev-data` | **Falhou e reverteu** (`ROLLBACK_COMPLETE`). Evento do CloudFormation: `AlertsKey` com `UnauthorizedTaggingOperation`. A política IAM de operador não tinha nenhuma ação `kms:*`. Verificado por leitura que não restou tabela, fila ou bucket de dados na conta; o bucket de artefatos permanece |

Correção: acrescentar o bloco KMS de `docs/operadores.md` à política dos operadores. Depois disso, excluir a stack vazia, criar novo change set e pedir nova confirmação antes de executar.

### Segunda tentativa e aplicação — 04/11/2026

Política dos operadores corrigida com o bloco KMS (`docs/operadores.md`). A stack de dados vazia foi excluída, um novo change set `inicial` foi criado (23 recursos, todos `Add`) e, com nova confirmação de Thiago e Rafael, executado. O change set da aplicação (28 recursos `Add`, capacidade `CAPABILITY_IAM`) foi revisado por Thiago e Rafael e executado.

| Stack | Resultado |
| --- | --- |
| `runpass-dev-data` | `CREATE_COMPLETE`, sem eventos de falha. 14 exports |
| `runpass-dev-app` | `CREATE_COMPLETE`, sem eventos de falha. A `ApiUrl` está nas saídas da stack (não registrada no Git) |

Verificação feita: chamadas sem credencial a `/me/participations` e `/editions` responderam 401 `INVALID_TOKEN`; rota inexistente responde 404. **Isso não prova a jornada**: carga do catálogo sintético, usuário sintético, smoke test, medição de tempo de imagem e demais testes reais da S09 seguem **não executados**. A confirmação das assinaturas SNS pelos quatro destinatários também está pendente.

### Catálogo, ensaio de operador e jornada em DEV — 04/11/2026

**Operador e carga do catálogo.** Pelo caminho exigido em PROD (`scripts/operator_tool.py`): operador criado no pool exclusivo com TOTP, acesso `catalog_admin` ativado por **outro usuário IAM** e carga das 5 edições sintéticas pelo `CatalogImporter` com sessão MFA, origem `https://runpass.invalid/fixture-sintetica`. A carga é repetível.

**Limitação deste ensaio.** Os dois usuários IAM (`runpass-dev-operator` e `runpass-dev-thiago`, este recriado depois do renome) pertencem à **mesma pessoa**. O ensaio prova o funcionamento técnico, não a separação de responsabilidades entre duas pessoas; o ensaio com Thiago e Rafael continua pendente antes de PROD. Não foram ensaiados refresh, token alheio, revogação nem recuperação.

**Smoke test contra a API real** (`scripts/smoke_journey.py`, dados sintéticos): **12 aprovados, 0 falhas, 1 não executado** (exclusão de conta). Em uma rodada separada com `--delete-account`: 13 aprovados. Imagem validada em cerca de 1 s (meta de 5 s). O passo 08 foi apertado: o segundo usuário precisa ter perfil e admissão, e só 404 conta como negado (uma rodada anterior aceitou um 403 causado por admissão ausente, que não provava separação entre donos).

**Exclusão de conta.** A API respondeu 202; o usuário sumiu do Cognito pouco depois (processada pela manutenção, a cada 5 minutos). Por leitura, não restaram linhas de `USER#` nem objetos no S3 do usuário apagado; restou o registro de controle de exclusão, esperado. Amostra de um caso sintético, sem teste de volume, de falha no meio da exclusão ou de reprocessamento.

**Ainda não provado:** HEIC e fotos reais em aparelhos, carga, restore com RPO/RTO, permissões negativas além do rascunho, DLQ e replay, alarmes (com e-mail recebido pelos quatro destinatários), limites de Lambda, privacidade em outras rotas. Há 4 itens `WORK#event#pending#...` na OperationsTable com mais de 3 horas na leitura; não foi verificado se são fila normal ou eventos parados.

### Primeiro teste em iPhone real contra o DEV — 05/11/2026

iPhone 17 (iOS 27.0.1), build release com `scripts/run-device-dev.sh`, conta de corredor criada no app com e-mail real e código de confirmação. **Resultado: a jornada não fechou na primeira tentativa.** Passaram: cadastro, login, catálogo (5 edições sintéticas) e criação do rascunho. Falharam e foram corrigidos no app (PR #14), **ainda sem novo teste em aparelho**:

| Achado | Causa (verificada) | Correção |
| --- | --- | --- |
| Foto não enviada | O app enviava ao S3 sem `Content-Length` (Dart usa `Transfer-Encoding: chunked`) e o S3 respondia 501; 6 uploads JPEG de 1,1 a 1,7 MB ficaram `pending` sem objeto no S3. Reproduzido com o código do app; com o tamanho informado, 200 e o servidor validou o JPEG. O smoke não pegou porque o cliente Python informa o tamanho | `putBytes` com `contentLength`, teste de regressão |
| Teclado não fechava | Teclado numérico do iOS sem tecla de fim e nenhum fechamento por toque ou rolagem | Toque fora fecha; arrastar a lista fecha |
| "Você já possui um registro" em toda corrida | Um registro por edição por pessoa; os 4 rascunhos do primeiro teste existiam e o app só listava participações concluídas | Criar rascunho reabre o existente; Início lista "Rascunhos em andamento" |
| Tela do rascunho confundia | Não dizia que o rascunho já estava criado; edição arquivada bloqueia a distância sem explicar | Texto explicativo nas duas telas |

**HEIC:** o seletor do iOS entregou JPEG (os uploads do aparelho foram `image/jpeg`); o backend continua aceitando só JPEG, MPO e PNG. **Foto de câmera:** não testável, o app só abre a galeria. Os uploads `pending` do teste permanecem no DEV.

**Segunda rodada em iPhone (05/11/2026), correções feitas e ainda sem novo teste em aparelho:**

| Achado | Causa | Correção |
| --- | --- | --- |
| "Esta corrida ainda não pode ser concluída" sem explicação | Regra do servidor correta: a data da prova (08/11/2026 na edição de SP 2026) é futura; o app oferecia o botão e mostrava a mensagem no fim da tela | Aviso com a data, botão desabilitado e mensagem clara; rascunho continua salvo |
| Avaliação em lista suspensa | Pedido de usar ícones e até 5 estrelas, como no mockup | Estrelas por critério, também na edição da avaliação |
| Perda da foto e das notas ao voltar | Estado só em memória da tela | Foto validada e avaliação preservadas ao reabrir o mesmo rascunho (em memória do app; não sobrevive a fechar o app) |
| Sem opção de excluir rascunho | Só havia exclusão de participação concluída | "Excluir rascunho" na tela do rascunho e no cartão do Início, com confirmação |
| Rascunhos só apareciam ao rolar | Início não recarregava ao voltar de outra tela (causa provável, não confirmada em aparelho) | Recarrega ao voltar e ao reabrir o app |
| Mensagens de erro fora da tela | Ficavam no fim da lista | Mensagem logo abaixo do título |

**Não corrigido (lacuna do produto):** a foto enviada **não aparece** em Início nem em Medalhas. O contrato da API só expõe `medalImageReference` (um identificador) e não tem rota para ler a imagem; o app mostra uma arte desenhada. É o item "imagem da medalha exibível" do S12 e exige rota nova com URL assinada de leitura, só para o dono, mais a decisão de privacidade correspondente. "Salvar visibilidade" funciona: a tela permanece e mostra a mensagem de confirmação.

**Marca "já está na sua lista" (05/11/2026).** Na busca e na tela da edição, a corrida em que a pessoa já tem rascunho ou participação concluída ganha um ícone de confirmação e o texto "Já está na sua lista"; a tela da edição troca "Criar rascunho" por "Continuar rascunho" ou "Ver minha participação". A "Prova Sintética Arquivada" continua marcada como arquivada: é uma edição da fixture (`synthetic-archived`, `archived: true`) criada para provar a regra de histórico preservado sem novos registros, e **não** está na lista de ninguém. Sem verificação em aparelho.

**Concluir e arquivada (05/11/2026).** Ao concluir a participação, o app mostra a confirmação e leva a pessoa para a tela Medalhas (a decisão pode ser trocada por Início). A edição arquivada aparece em cinza na busca e na tela da corrida, com o seletor de distância desabilitado. Sem verificação em aparelho.

**Corrida já cadastrada (05/11/2026).** Ao tocar, na busca, numa corrida que já está na lista da pessoa, o app não abre a página da edição: pergunta "Corrida já cadastrada: <nome> já está na sua timeline. Deseja editar?". "Sim" abre o registro existente (rascunho para editar, ou a participação concluída com a edição da avaliação); "Não" volta para a lista. Sem verificação em aparelho.

**Navegação nas telas internas (05/11/2026).** Nas telas de rascunho, detalhe da edição e avaliação, a barra de baixo destacava a aba "Corridas" e tocar nela não fazia nada (havia um retorno antecipado quando a aba já estava ativa), então a pessoa ficava sem caminho de volta à lista pela barra. Agora, nessas telas internas, tocar na aba leva à tela principal dela. O teste em iPhone enviou prints de uma versão **anterior** do app (mensagem curta de corrida futura e cartão do Início sem a lixeira), então as correções posteriores precisam ser reinstaladas no aparelho para serem verificadas.

**Motivo da edição arquivada e mensagens (05/11/2026).** O catálogo ganha `archivedReason` (`cancelled`, `unavailable`, `duplicate`, `ended`), validado no importador (só com `archived`), no contrato OpenAPI, no modelo de dados e na fixture (`synthetic-archived` marcada como `cancelled`). O app mostra o motivo na busca e na tela da corrida. O carregador do catálogo (`scripts/operator_tool.py load-catalog`) agora publica uma **nova versão** quando o conteúdo de uma edição muda e continua sem criar versão quando é igual. As mensagens de erro do app foram reescritas para dizer o motivo e o que fazer. **No DEV, o motivo só aparece depois de rodar `load-catalog` de novo** (precisa de operador com MFA) e é uma versão nova do catálogo; não verifiquei se a API atual já devolve o campo novo sem redeploy da Lambda (ela devolve o corpo guardado, o que indica que sim, mas não foi testado).

**Editar meus dados e corridas futuras (05/11/2026).**
- Na participação (rascunho ou concluída) dá para editar a **distância** (entre as da edição), o **tempo** (aceita `1:30:00`, `45:10` ou segundos), a **colocação** e o **número de peito**, por `PATCH /participations/{id}` com a versão esperada; no servidor, trocar a distância de uma concluída revalida a edição e recompõe avaliação e medalha. Não foi testado em DEV contra a API real.
- **Corrida futura** (data da prova depois de hoje): o rascunho continua editável (tempo, colocação, número, distância), mas o app **não oferece foto, avaliação nem conclusão** e explica que depois da data será possível concluir. No Início, essas corridas ficam em **"Minhas corridas futuras"**; os rascunhos de corridas que já aconteceram ficam em "Rascunhos em andamento". O servidor continua recusando a conclusão antes da data (`EDITION_NOT_COMPLETABLE`).
- **Não feito:** "Minhas corridas desejadas". O contrato tem `/me/wishlist`, mas o backend real ainda não implementa essas rotas (a demo as simula); é o slice S14 e precisa de decisão de produto sobre como a lista de desejadas se relaciona com as corridas futuras.

**Corridas como lugar de pesquisa e consulta (05/11/2026).** Tocar em qualquer corrida da busca, inclusive as que já estão na lista da pessoa, abre a **página da corrida** (abas Sobre, Avaliações, Fotos e Participantes). Na lista a corrida marcada mostra o ícone "Já está na sua lista"; na página aparece "Esta corrida está na sua lista" no cabeçalho e o botão "Editar meu rascunho" ou "Editar minha participação". Substitui a pergunta "Deseja editar?" do commit anterior. **Limite real:** no backend o detalhe da corrida existe, mas a lista pública de avaliações (`/editions/{id}/reviews`), as fotos e a lista de participantes **não estão implementadas**; a aba Avaliações mostra "As avaliações detalhadas ainda não estão disponíveis" e Participantes mostra "em breve". Isso é o slice S12 (avaliações públicas) e S11 (participantes).

**Minha avaliação na aba Avaliações (05/11/2026).** Na página da corrida, a aba Avaliações mostra, acima da nota geral, a **avaliação que a própria pessoa já cadastrou** (oito critérios com estrelas e o comentário) e o botão "Editar avaliação". Vem de `GET /participations/{id}/review`, rota que existe no backend real; a leitura não foi testada contra o DEV. A lista pública de avaliações de outros corredores continua indisponível (S12).

**Ver a avaliação já salva (05/11/2026).** Depois do teste em iPhone, a pessoa não conseguia ver as avaliações que tinha salvo. Verificado por leitura no DEV: a conta de teste tinha 3 participações concluídas, cada uma com a avaliação válida gravada (o servidor guardava tudo). A tela da participação concluída (a que se abre pela aba Medalhas) mostrava só os botões de editar e excluir, sem o conteúdo da avaliação. Agora ela mostra o cartão "Minha avaliação" (oito critérios com estrelas e o comentário), que também aparece na aba Avaliações da página da corrida. Sem verificação em aparelho.

**Sair e excluir a conta pelo app (05/11/2026).** Ao montar o roteiro de testes viu-se que "Sair" e "Excluir minha conta" só existiam na tela "Olá, <nome>!", anterior ao Início, e depois de entrar não havia como sair nem excluir a conta (requisito de privacidade). Agora ficam no fim do Perfil, com confirmação na exclusão; ambos voltam à tela de entrada, e a exclusão mostra "Exclusão aceita". O texto do Perfil "dados locais de demonstração não são enviados à AWS" era falso no modo real e foi trocado. Testado só em widget com servidor falso; a exclusão real já tinha sido provada pela API em DEV, o fluxo pela tela não.


## Deploy de amigos, fotos e comentarios no DEV - 06/11/2026

- Autorizado pelo usuario ("Pode realizar o deploy"). Change set `amigos-fotos-061425` da stack `runpass-dev-app` (UPDATE), pacote `lambda/runpass-bd7ed408252e0dfe.zip` (commit `76b089a`, PR #23). Anterior: `lambda/runpass-4cc03e9d4ca9ce3e.zip` (volta por troca da chave `ArtifactKey`).
- Mudancas: apenas codigo das Lambdas (Api, Publisher, ScoreConsumer, AuditConsumer, Maintenance) e re-vinculo da integracao/regra/permissao; sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: rotas novas (`/profiles`, `/feed`, `/me/follow-requests`) respondem 401 sem token e rota inexistente responde 404, ou seja, as rotas existem no deploy. **Nao** verificado ainda com usuarios reais: busca, seguir, aprovacao de perfil privado, comentarios, foto de perfil e troca de foto da medalha. Isso depende do teste humano com duas contas.
- Limites: ver `PDLC/M4/S10-amigos.md`.


## Deploy da rodada 2 de amigos no DEV - 06/11/2026

- Autorizado pelo usuario ("Pode realizar o deploy"). Change set `rodada2-061652` da stack `runpass-dev-app` (UPDATE), pacote `lambda/runpass-29c579665fbcbcbe.zip` (commit `6ce5621`, PR #24). Anterior: `lambda/runpass-bd7ed408252e0dfe.zip` (volta por troca da chave `ArtifactKey`).
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao; sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `/me/notifications` e `/feed` respondem 401 sem token, `/posts/{id}/like` responde 405 a GET (so aceita PUT/DELETE) e rota inexistente responde 404. **Nao** verificado com usuarios reais: curtidas, avisos, ultimo comentario, indexacao da busca no login, foto de perfil com recorte/camera/remocao, compartilhar.
- Limites: ver `PDLC/M4/S10-amigos.md` (Rodada 2).


## Deploy da rodada 3 de amigos no DEV - 06/11/2026

- Autorizado pelo usuario ("Pode realizar o Deploy"). Change set `rodada3-061811` da stack `runpass-dev-app` (UPDATE), pacote `lambda/runpass-10344cc2a91de517.zip` (commit `17383cf`, PR #24). Anterior: `lambda/runpass-29c579665fbcbcbe.zip` (volta por troca da chave `ArtifactKey`).
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao; sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `/profiles/{id}/banner` e `/me/notifications` respondem 401 sem token; `GET /me/notifications/{id}` responde 405 e `DELETE` 401 (a rota existe); rota inexistente 404. **Nao** verificado com usuarios reais: banner, apagar aviso, pedidos no topo, manter conectado, compartilhar, modo escuro.
- Limites: ver `PDLC/M4/S10-amigos.md` (Rodada 3).


## Deploy da rodada 4 no DEV - 06/11/2026

- Autorizado pelo usuario ("Faca o deploy em dev"). Change set `rodada4-061909` da stack `runpass-dev-app` (UPDATE), pacote `lambda/runpass-bfd97498ae44c795.zip` (commit `39271ea`, PR #24). Anterior: `lambda/runpass-10344cc2a91de517.zip` (volta por troca da chave `ArtifactKey`).
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao; sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `PUT /comments/{id}/like` responde 401 sem token e `GET` na mesma rota 405 (a rota existe); `/editions` com os filtros novos responde 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: curtir e responder comentarios, avisos de curtida e resposta, filtros novos do catalogo.
- Catalogo real de Sao Paulo **nao carregado** (sem CSV autorizado nem credenciais das APIs). Ver `docs/catalogo-corridas.md`.


## Deploy da rodada 5 no DEV (identidade + Lambdas) - 07/11/2026

- Autorizado pelo usuario ("Sim decisao nossa, pode seguir com o deploy e atualizacao"): a politica de senha de 6 caracteres sem composicao do pool de corredores e **decisao de produto dos dois responsaveis** (PR #25 do Rafael).
- **Stack `runpass-dev-identity`** (UPDATE), change set `senha-070109`: uma unica mudanca, `Modify` em `RunnerPool` com `Replacement: False` (nenhum usuario afetado). Antes: minimo 12 com maiuscula, minuscula, numero e simbolo. Agora: minimo 6, sem composicao (conferido por `describe-user-pool`). Pool do operador inalterado (12 caracteres, MFA ligado). Resultado: `UPDATE_COMPLETE`.
- **Stack `runpass-dev-app`** (UPDATE), change set `rodada5-070110`, pacote `lambda/runpass-df5a24695b6be5c0.zip` (inclui o merge de `dev` com o PR #25: `GET /me` devolve `birthDate` so ao titular). Anterior: `lambda/runpass-bfd97498ae44c795.zip`. Somente codigo das Lambdas e re-vinculos; sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao: `/me` e `/feed` respondem 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: cadastro novo com senha depois do e-mail confirmado, troca de senha de 6 caracteres, data de nascimento.
- Observacao: nesta sessao o `aws` do PATH era a versao 1.32 (nao le credenciais do `aws login`); a 2.39 fica em `~/.local/bin`.


## Deploy da rodada 6 no DEV (idade 13, amigos/feed, exclusao imediata) - 07/11/2026

- Autorizado pelo usuario ("Faça o deploy do backend no DEV"). Stack `runpass-dev-app` (UPDATE), change set `idade13-cognito-imediato-070200`, pacote `lambda/runpass-3202b40526608af1.zip`. Anterior: `lambda/runpass-df5a24695b6be5c0.zip` (volta por troca da chave `ArtifactKey`). Ainda sem commit/PR nesta sessao (arvore de trabalho local).
- Mudancas: codigo das Lambdas (Api, Publisher, ScoreConsumer, AuditConsumer, Maintenance) **e** IAM — unica rodada ate agora que muda o template, nao so o `ArtifactKey`: `ApiFunctionRole` ganhou `cognito-idp:AdminDeleteUser` no pool do runner e `ApiFunction` ganhou a variavel `RUNPASS_RUNNER_USER_POOL_ID` (ver S02, "Exclusao de conta libera o e-mail na hora"). 9 mudancas no change set (`Modify` em `ApiFunctionRole`, `ApiFunction`, `AuditConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`, `Maintenance`, `Publisher`, `ScoreConsumer`); sem recursos novos, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Conteudo: idade minima de admissao 18->13 anos (backend + app), seguir sem aprovacao / amizade com aprovacao, feed publico "Todos" via ponteiro global, exclusao de conta libera o Cognito na mesma requisicao.
- Verificacao feita (sem credenciais, so HTTP): `GET /me` e `GET /feed` respondem 401 sem token; `PUT /profiles/{id}/friend` responde 401 (rota nova existe, nao 404); rota inexistente responde 404. **Nao** verificado com usuarios reais: cadastro a partir de 13 anos, seguir/amizade, feed "Todos"/"Amigos"/"Minha rede", exclusao de conta liberando o email na hora. Isso depende do teste humano com o `.apk`.

## Backfill do ponteiro publico do feed "Todos" no DEV - 08/11/2026

- Teste humano com o `.apk` (rodada 6) achou o feed "Todos" vazio para publicacoes de outros usuarios. Causa confirmada por leitura direta da `HistoryTable` do DEV (`runpass-dev-data-HistoryTable-*`, so leitura): 0 linhas em `PK=FEED#PUBLIC` contra 5 participacoes ja concluidas e publicadas (3 usuarios, `completedAt` entre 05 e 06/11) — todas anteriores ao deploy da rodada 6, que so passou a gravar esse ponteiro a partir dali. Nao era bug de logica; era falta de backfill para o que ja existia antes do recurso entrar no ar.
- Autorizado pelo usuario ("pode seguir com esse ajuste"). Script novo `backend/scripts/backfill_public_feed.py`: varre participacoes `state=completed` e `publishToFeed=true` e grava o ponteiro `FEED#PUBLIC` que falta (mais a referencia `FEEDREF#` para a exclusao de conta continuar limpando tudo), condicionado a nao existir ainda (`attribute_not_exists(PK)`) — idempotente, repetir nao duplica.
- Executado uma vez contra o DEV: 11 participacoes publicadas varridas, 5 ponteiros novos criados, 0 ja existentes. Sem mudanca de codigo nem deploy (so dados); o mecanismo de gravar o ponteiro em cada nova conclusao ja estava correto e no ar desde a rodada 6.
- **Nao** verificado ainda pelo teste humano que o feed "Todos" agora mostra as 5 publicacoes para quem nao segue nem e amigo dos 3 autores.


## Deploy da rodada 7 no DEV (perfil privado restringe so o resumo de corridas) - 08/11/2026

- Autorizado pelo usuario ("sim"). Stack `runpass-dev-app` (UPDATE), change set `privacidade-publicacoes-080000`, pacote `lambda/runpass-c1b69e289bfe8945.zip`. Anterior: `lambda/runpass-3202b40526608af1.zip`. Ainda sem commit/PR nesta sessao.
- Mudancas: so codigo das Lambdas e re-vinculos (8 mudancas no change set); sem IAM, sem recursos novos — ao contrario da rodada 6, esta nao mexeu no template.
- Conteudo: publicacoes, curtidas, comentarios, fotos de post, avatar, banner e contagem de seguidores/seguindo sempre publicos, perfil privado ou nao; perfil privado restringe so o resumo de corridas (contagem + lista) a amigo aceito. Ver `S10-amigos.md`, "Perfil privado passa a restringir so o resumo de corridas".
- Verificacao feita (sem credenciais, so HTTP): `GET /me` e `GET /feed` respondem 401 sem token; rota inexistente responde 404. **Nao** verificado com usuarios reais: publicacao de perfil privado visivel para nao-amigo, resumo de corridas continuando bloqueado. Depende do teste humano com o `.apk`.


## Filtros do Início corrigidos e estado/cidade do perfil (08/11/2026) — pendente de deploy

- Teste humano achou "Amigos" quebrado (so mostrava as proprias publicacoes, por falta de amigo aceito de teste). Causa: `_authors_feed` sempre incluia o proprio autor nos escopos "friends"/"network", e o mobile tambem injetava as proprias corridas independente do filtro. Corrigido nos dois lados: `social.py` tira o autor da lista (`_authors_feed`), `home_screen.dart` so injeta as proprias corridas no filtro "Todos".
- Filtros renomeados/trocados: "Minha rede" -> "Seguindo" (so quem eu sigo, nao mais as minhas); "São Paulo" -> "Minha Cidade" (recorta "Todos" pela cidade/estado do proprio perfil, nao mais fixo em Sao Paulo); "Trilhas" removido (nunca mostrava nada, decisao: nao oferecer nesta fase).
- **Novo campo `state`** no perfil (`PatchProfile`/`PATCH /me`, validado como UF de 2 letras maiusculas) ao lado do `city` que ja existia. `GET /me`/`GET /profiles/{id}` devolvem os dois. Contrato (`API-RunPass-v1.openapi.json`) atualizado em `PublicProfile`, `OwnProfile` e `PatchOwnProfile`.
- **Lista de UF/municipios do Brasil**: buscada da API publica do IBGE (`servicodados.ibge.gov.br`, 27 UFs, 5.571 municipios) e gerada em `mobile/lib/br_locations.dart` (dados estaticos, sem chamada de rede no app). Seletor novo `mobile/lib/location_picker.dart`: dois seletores de rolagem (Estado, Cidade), mesmo padrao visual da data de nascimento, sem digitacao; trocar o estado reinicia a lista de cidades.
- **Cadastro de novo usuario**: novo passo `Step.location` em `main.dart`, entre o perfil (nome/usuario) e a data de nascimento.
- **Usuario ja cadastrado**: ao tocar em "Minha Cidade" sem estado/cidade salvos, `home_screen.dart` pede o preenchimento uma vez (`ensureLocation`) antes de aplicar o filtro; depois disso nunca mais pergunta.
- **Tela de Perfil**: cartao "Editar perfil" logo abaixo da data de nascimento, mostrando "UF - Cidade" (ex.: "SP - Taboão da Serra") ou um convite para preencher; abre o mesmo seletor.
- Testes: backend (`test_identity.py`, formato do campo `state`) e mobile (`test_social.py` ja cobria a exclusao de autor nos escopos; `home_feed_filters_test.dart`, `location_edit_test.dart` e o teste novo em `home_feed_test.dart` cobrem o filtro "Minha Cidade", o cartao "Editar perfil" e o passo novo do cadastro) — 192 testes no backend, 115 no mobile, `flutter analyze` sem avisos.
- Autorizado pelo usuario ("pode realizar o deploy e gerar o arquivo.apk"). Stack `runpass-dev-app` (UPDATE), change set `filtros-localizacao-080300`, pacote `lambda/runpass-7cc127687293ff45.zip`. Anterior: `lambda/runpass-c1b69e289bfe8945.zip`. So codigo das Lambdas e re-vinculos (8 mudancas); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais, so HTTP): `GET /me` e `GET /feed?scope=all` respondem 401 sem token; rota inexistente responde 404. **Nao** verificado com usuarios reais: passo de localizacao no cadastro, prompt do filtro "Minha Cidade", filtros "Amigos"/"Seguindo" sem as proprias publicacoes, "Editar perfil". Depende do teste humano com o `.apk` (`runpass_app_android_teste_v3.apk`).


## "Amigos"/"Seguindo" vazios convidam a encontrar pessoas; "Minha Cidade" com raio de 50 km (08/11/2026) — pendente de deploy

- Teste humano da rodada anterior aprovado; pedido de 3 ajustes novos.
- **"Amigos" e "Seguindo" vazios**: antes mostravam so o aviso generico "Nenhuma publicacao nesta selecao ainda." mesmo sem nenhum amigo/seguido. Agora, quando o usuario nao tem nenhum vinculo (nao so falta de posts recentes), mostram um convite especifico ("Você ainda não tem amigos confirmados..." / "Você ainda não está seguindo ninguém...") com botao "Encontrar amigos" (abre `FriendSearchScreen`, ja existente). Para distinguir "sem vinculo" de "com vinculo mas sem posts", `profile_view()` ganhou o campo `friendsCount` (como `followersCount`/`followingCount`, sempre publico); o mobile busca `/profiles/{meuId}` so quando o filtro e Amigos/Seguindo.
- **"Minha Cidade" com raio de proximidade**: decisao de produto — prioriza publicacoes da mesma cidade; sem nenhuma, cai para cidades vizinhas num raio de **50 km** (valor comum de "perto de voce" em redes sociais). Perfil ganhou `latitude`/`longitude` (`PatchProfile`/`PATCH /me`, validados como coordenadas validas) gravados junto com `state`/`city` quando a cidade escolhida tem coordenada conhecida. Coordenadas (centroide por municipio) vieram do dataset publico `kelvins/municipios-brasileiros` (derivado do IBGE): 5.540 das 5.571 cidades da lista bateram pelo nome (31 ficaram sem coordenada por pequenas diferencas de acentuacao entre as duas fontes; essas cidades continuam funcionando so por correspondencia exata de nome, sem o raio), gravadas em `mobile/lib/br_locations.dart` (`brCityCoordinates`). Distancia calculada com formula de haversine (`_haversineKm`, `cityScopedEntries` em `home_screen.dart`).
- Nota de viabilidade (ja registrada antes do pedido): o catalogo sintetico do DEV ainda nao tem `latitude`/`longitude` preenchidas nas edicoes, entao o efeito pratico do raio (cidades vizinhas aparecendo) so fica visivel quando o catalogo real tiver essas coordenadas — o codigo ja fica pronto para isso.
- Testes: backend (`test_social.py`, `friendsCount`) e mobile (`home_feed_test.dart` para os convites vazios; `home_feed_filters_test.dart` para `cityScopedEntries`, incluindo caso real São Paulo/Guarulhos/Rio de Janeiro) — 194 testes no backend, 120 no mobile, `flutter analyze` sem avisos.
- Ainda **sem deploy** nem `.apk` desta rodada.


## Destaque do filtro dinâmico; publicações concentradas no Perfil; pedidos de amizade em Avisos (08/11/2026) — pendente de deploy

- **Destaque laranja dos filtros do Início dinâmico**: antes fixo em "Todos" (so a borda reagia a selecao); agora o preenchimento laranja e a cor do icone seguem o filtro selecionado, qualquer um dos quatro. Borda extra removida por ficar redundante com o proprio preenchimento.
- **"Minhas publicações" concentradas no Perfil** (como em outras redes sociais): nova seção em `RunnerProfileScreen` (`my_races.dart`) com as corridas do próprio usuário publicadas no feed (`publishToFeed=true`), mais recente primeiro. Testada primeiro como grade 3 colunas; a pedido do usuário, trocada para usar o mesmo `PostCard` do Feed (`post_card.dart`), uma publicação abaixo da outra — não em grade. `loadMyPosts` busca `GET /posts/{id}` de cada corrida publicada para montar o `FeedEntry` completo (curtidas/comentários reais, não zerados). Sem nenhuma publicada, mostra aviso para preencher.
- **Botões "Buscar amigos" e "Pedidos de amizade" removidos do Perfil**: buscar pessoas já existe no ícone do AppBar do Início; pedidos de amizade passam a ficar só em Avisos.
- **Pedidos de amizade movidos para dentro de Avisos**: antes apareciam soltos na lista principal, com Aceitar/Recusar inline, sem expirar. Agora viram um resumo único "Pedidos de amizade (N)" (contagem dinâmica) acima da lista; toque abre `FriendRequestsScreen` (já existente, mesma tela que respondia pelo antigo botão do Perfil) para aceitar/recusar. Pedido de amizade nunca mais aparece como item solto/deslizável na lista principal.
- Testes: `home_feed_test.dart` (destaque dinâmico); `races_test.dart` (publicações como cartão do Feed, filtra as não publicadas); `notifications_test.dart` (resumo com contagem, navegação, atualização ao voltar). Removido `request_buttons_theme_test.dart` (testava os botões inline que saíram de Avisos; o layout do Aceitar/Recusar que ele protegia não existe mais nesse lugar — `FriendRequestsScreen` usa outro padrão de botão, já coberto em `friends_test.dart`). 194 testes no backend (sem mudança), 120 no mobile, `flutter analyze` sem avisos.
- Autorizado pelo usuario ("Pode realizar o Deploy"). Stack `runpass-dev-app` (UPDATE), change set `perfil-avisos-raiocatalogo-080600`, pacote `lambda/runpass-e4d45487c2f6b69f.zip`. Anterior: `lambda/runpass-7cc127687293ff45.zip`. So codigo das Lambdas e re-vinculos (8 mudancas); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- **Backfill de coordenadas no catalogo sintetico do DEV** (mesma rodada, autorizado junto): as 5 edicoes sinteticas (`synthetic-sp-2024/2025/2026`, `synthetic-rj-2026`, `synthetic-archived`) ganharam `latitude`/`longitude` (mesmos centroides de `mobile/lib/br_locations.dart`), via `UpdateItem` so no atributo `edition.latitude`/`edition.longitude` da linha `V#{versao}` (fonte de leitura de `_edition()`), sem tocar version/digest/index rows — seguro porque `_edition()` nunca confere digest na leitura, so o `put()` de uma nova versao confere. Rota de escrita "oficial" (`CatalogImporter.put` com `synthetic=True`) e bloqueada fora de `MemoryStore` de proposito ("Synthetic loader is local-memory only"), entao o backfill direto na tabela foi a opcao segura, nao a geracao de uma nova versao sintetica. Com isso, o raio de 50 km de "Minha Cidade" ja tem o que comparar no DEV.
- Verificacao feita (sem credenciais, so HTTP): `GET /me` e `GET /feed` respondem 401 sem token; rota inexistente responde 404. **Nao** verificado com usuarios reais: resumo de publicacoes no Perfil, pedidos de amizade em Avisos, destaque dinamico dos filtros, "Minha Cidade" trazendo provas vizinhas de verdade. Depende do teste humano com o `.apk`.

## Separacao Seguir/Amizade; contagem de amigos no Perfil; fix de encoding do filtro de cidade (08/11/2026)

- **Seguir deixa de precisar de aprovacao**: antes, seguir um perfil privado ficava "pending" ate aprovacao. Agora seguir e sempre unidirecional e imediato (`add_follow` em `social.py` nao checa mais `isPrivate`); so a amizade (nova, bidirecional) continua exigindo pedido e aceite.
- **Amizade nova, separada de seguir**: `add_friend`/`remove_friend`/`friend_requests`/`decide_friend` em `social.py`, com estados `none/pending_out/pending_in/friends`. E a unica coisa que desbloqueia o resumo de corridas (contagem + lista) em perfil privado — seguir sozinho nunca desbloqueia. Rotas novas: `PUT`/`DELETE /profiles/{id}/friend`, `GET /me/friend-requests`, `PUT`/`DELETE /me/friend-requests/{id}`. Rotas antigas `/me/follow-requests` saem (seguir nao pede mais aprovacao). Erro novo `CANNOT_FRIEND_SELF`.
- **Publicacoes sempre publicas**: posts, curtidas, comentarios, fotos de post, avatar e banner passam a depender so de conta ativa (`_author_active`), nunca mais de `isPrivate`/`can_view`. Contadores de seguidores/seguindo/amigos (`followersCount`/`followingCount`/`friendsCount`) tambem sempre publicos, fora do bloco `canView`.
- **Mobile**: `friends.dart` ganha um segundo botao ("Adicionar amigo"/"Solicitado amizade (toque para cancelar)"/"Responder pedido"/"Remover amigo") ao lado do botao de seguir ("Seguir"/"Seguindo"); `FollowRequestsScreen` renomeada para `FriendRequestsScreen`; banner do perfil visivel mesmo sem `canView`. `notifications.dart` troca `follow_request`→`friend_request` e adiciona o tipo `friend` (aviso de amizade aceita).
- **Contagem de amigos no Perfil**: cartao `profile-counts` (ao lado da foto, abaixo do banner) ganha "amigos" como primeiro item, na ordem amigos → seguidores → seguindo (`my_races.dart`, lendo `friendsCount` de `GET /profiles/{meuId}`), a pedido do usuario.
- **Fix de bug pre-existente**: `seed_synthetic()` em `catalog.py` lia o fixture do catalogo sem `encoding="utf-8"` explicito; no Windows (encoding padrao `cp1252`), isso corrompia acentos (`São Paulo` virava `sa£o paulo` no indice), quebrando o filtro `city` do catalogo. Confirmado por `git stash` que o bug ja existia no `HEAD` do `dev` (commit `8b8d2d3`, PR #26), nao introduzido nesta sessao; so afeta execucao local no Windows (Lambda roda em Linux, UTF-8 por padrao). Corrigido com `encoding="utf-8"` explicito.
- Testes: backend (`test_social.py`, 30 testes de amizade/seguir, incluindo `friendsCount`), `make check` completo (lint, contrato, 194 testes, infra-check) verde apos o fix de encoding — so restou a falha de permissao `0o600` em `test_local_api.py`, tambem pre-existente e especifica do Windows/NTFS (nao bloqueante). Mobile: `flutter analyze` sem avisos, 120 testes verdes, `dart format` corrigido (11 arquivos que estavam fora do padrao desde a sessao anterior).
- Autorizado pelo usuario ("Faça o Deploy"). Sessao AWS obtida via `aws sts get-session-token` com MFA do authenticator (perfil `runpass-dev-rafael-mfa`), apos `aws login` (browser OAuth) falhar repetidamente com "refresh token expirado" nesta maquina — ver memoria `aws_mfa_session_procedure`. Stack `runpass-dev-app` (UPDATE), change set `amizade-seguir-encoding-081900`, pacote `lambda/runpass-89bca7c26ca498ae.zip`. Anterior: `lambda/runpass-e4d45487c2f6b69f.zip`. So codigo das Lambdas e re-vinculos (8 mudancas: `ApiFunction`, `AuditConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`, `Maintenance`, `Publisher`, `ScoreConsumer`); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais, so HTTP): `GET /me`, `GET /feed` e `GET /me/friend-requests` respondem 401 sem token; `PUT /profiles/{id}/friend` responde 401 (rota nova existe, nao 404); rota inexistente responde 404. **Nao** verificado com usuarios reais: fluxo completo de pedido/aceite de amizade, seguir sem aprovacao em perfil privado, contagem de amigos no Perfil, publicacoes de perfil privado visiveis a nao-amigos. Depende do teste humano com o `.apk` (ainda nao gerado para esta rodada).

## Fix critico: PATCH /me quebrava ao salvar estado/cidade com coordenadas (08/11/2026)

- Teste humano (rodada anterior, `v6.apk`) achou "Escolha da cidade" sempre falhando, tanto em "Editar perfil" quanto no filtro "Minha Cidade" — sempre dava "Nao foi possivel salvar. Tente de novo.".
- Causa confirmada direto nos logs da Lambda em producao (`runpass-dev-app-ApiFunctionLogs-qPGPGnKHbn9B`, filtro por `Traceback`, varias ocorrencias desde 08/11 20:34): erro 500, `TypeError: Float types are not supported. Use Decimal types instead.`, em `service.py:patch_profile` -> `store.py:commit` -> `encode` -> `boto3 TypeSerializer.serialize`. `PatchProfile.latitude`/`longitude` em `models.py` estavam tipados como `float` puro, diferente do `ImportEdition` (catalogo), que ja usava `Decimal` corretamente. Como a maioria das cidades da lista do IBGE tem coordenada conhecida (5540 de 5571), quase toda tentativa de salvar UF/Cidade incluia lat/lon e quebrava.
- **Por que os testes locais nunca pegaram isso**: a suite roda contra `MemoryStore` (objetos Python em memoria), que nunca serializa para o formato do DynamoDB; so o Lambda real contra o DynamoDB de verdade expoe esse erro. Bug pre-existente desde que os campos `latitude`/`longitude` foram adicionados ao `PatchProfile` (sessao anterior, nunca commitado nem testado contra o backend real ate agora).
- Corrigido: `latitude`/`longitude` em `PatchProfile` passam a ser `Decimal` com o mesmo `field_validator` de conversao usado em `ImportEdition`. Efeito colateral encontrado e corrigido na mesma rodada: o fingerprint de idempotencia em `service.py:transact` fazia `json.dumps(body, ...)` sem `default=str`, e `Decimal` nao e serializavel em JSON puro — adicionado `default=str` (so para o hash de idempotencia, nao afeta o valor gravado).
- Teste de regressao novo (`test_identity.py::DynamoAdapterTests::test_patch_profile_coordinates_encode_for_real_dynamodb_not_only_memorystore`): monta o `PatchProfile` de verdade e chama `DynamoStore.encode()` (sem rede, so a serializacao) — falha exatamente com o erro real sem o fix (confirmado revertendo e rodando), passa com o fix. `make check` completo verde: 195 testes (so a falha de permissao `0o600`, pre-existente do Windows), lint, contrato, infra-check.
- Autorizado pelo usuario ("sim", apos bloqueio do classificador de permissoes do Claude Code em "Production Deploy"). Stack `runpass-dev-app` (UPDATE), change set `fix-decimal-latlon-082000`, pacote `lambda/runpass-f12e9f63cf5bca34.zip`. Anterior: `lambda/runpass-89bca7c26ca498ae.zip`. So codigo das Lambdas e re-vinculos (8 mudancas); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais, so HTTP): `GET /me` responde 401 sem token; rota inexistente responde 404. **Nao** verificado ainda com usuario real salvando UF/Cidade de verdade (com coordenada) nem o raio de 50km de "Minha Cidade" com dados reais persistidos. Depende de novo `.apk` e teste humano.
- Teste humano confirmou (`v6.apk`): escolha de UF/Cidade agora salva normalmente, tanto em "Editar perfil" quanto no filtro "Minha Cidade".

## Listas de amigos/seguidores/seguindo ao tocar nos numeros do Perfil (08/11/2026)

- Pedido do usuario: tocar em amigos/seguidores/seguindo no Perfil (proprio ou de terceiros) abre a lista de pessoas, estilo Instagram, com opcao de seguir ou solicitar amizade. Decisoes do usuario: vale para o proprio perfil e para o de terceiros; sempre publico (mesma regra dos contadores); botao contextual por lista (amizade na lista de amigos, seguir nas outras duas).
- Backend: 3 rotas novas `GET /profiles/{id}/followers`, `/following`, `/friends`, paginadas (cursor simples, nao cifrado — dado sempre publico, mesmo padrao de `comments()`), devolvendo cartoes de perfil (`_card()`, com `followState`/`friendState` do ponto de vista de quem pediu). Contrato atualizado reusando o schema `ProfilePage` (68 paths, 0 erros). Testes novos em `test_social.py` (contexto correto do `followState` por item, paginacao, 404 para perfil inexistente).
- Mobile: tela nova `RelationListScreen` (`friends.dart`), com botao por linha dependendo da lista — "Adicionar amigo"/"Solicitado"/"Responder"/"Amigo" na lista de amigos; "Seguir"/"Seguindo" nas outras, com rotulo "Seguir de volta" so na propria lista de seguidores quando ainda nao segue de volta. Perfil publico de terceiros ganhou a contagem de "Amigos" que nao existia. 5 testes novos (`relation_list_test.dart`) — um deles pegou um bug real (chamada de rede durante o layout da lista quebrava o scroll), corrigido com `addPostFrameCallback`.
- Verificacao de nao-regressao: diff isolado contra o commit anterior confirma que `social.py`/`api.py` so tiveram adicoes (0 linhas removidas), e que `main.dart` nao foi tocado nesta rodada; `statBlock`/`_count` ganharam um parametro opcional (`onTap`) sem alterar nenhum dos outros 7 usos existentes. `make check` (197 testes) e `flutter test` (126 testes) verdes.
- Autorizado pelo usuario ("perfeito, pode avancar com o commit, implantacao e geracao .apk"). Stack `runpass-dev-app` (UPDATE), change set `listas-amigos-seguidores-082100`, pacote `lambda/runpass-50646dc262914a2a.zip`. Anterior: `lambda/runpass-f12e9f63cf5bca34.zip`. So codigo das Lambdas e re-vinculos (8 mudancas); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais, so HTTP): `GET /profiles/{id}/followers`, `/following` e `/friends` respondem 401 sem token (rotas existem, nao 404); rota inexistente responde 404. **Nao** verificado com usuario real: abrir as listas, tocar em seguir/amizade por linha, "Seguir de volta" nos seguidores. Depende do `.apk` (`runpass_app_android_teste_v8.apk`) e teste humano.
