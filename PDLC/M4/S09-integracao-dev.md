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

