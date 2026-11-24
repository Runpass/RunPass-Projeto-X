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

## Tela "Medalhas" renovada: visual da prateleira e customizacao por medalha (10/11/2026)

- Pedido do usuario: aplicar o visual do template "Template-Prateleira-Medalhas" na tela de Medalhas, em sub-etapas: (1) foto de perfil + BigNumbers (3 blocos) + visual de prateleira; (2) customizacao por medalha (forma, cor do cordao, legenda); (3) reposicionar a foto da medalha (recorte circular, como a foto de perfil).
- Mobile (`my_races.dart`, escopo isolado a `MedalCollectionScreen`): AppBar com foto de perfil (borda laranja, abre o Perfil) e titulo "Minhas Medalhas" centralizado; BigNumbers reduzidos a "provas concluidas"/"medalhas na colecao"/"cidades visitadas"; prateleira com fita em formato de bandeirola (recorte em V), medalha grande (recorte sempre quadrado via `AspectRatio`, formas redonda/escudo/estrela/hexagono) e prancha de madeira; icone de lapis abre bottom sheet de edicao (forma, paleta fixa de cor do cordao ou cor dominante extraida da foto, descricao/cidade/UF/ano); botao "Reposicionar foto" reaproveita o editor de recorte circular da foto de perfil, upload via funcoes injetaveis (testaveis sem rede real).
- Backend (`participation.py`/`models.py`/`upload.py`/`api.py`): campos opcionais novos em `Participation` (`medalShape`, `medalCordColor`, `medalDescription`, `medalCity`, `medalState`, `medalYear`, `medalDisplayImageReference`), persistidos via `PATCH /participations/{id}`; novo endpoint `GET /participations/{id}/display-image` (prefere o recorte reposicionado, senao cai para a foto oficial de sempre — que nunca e alterada). Contrato atualizado e validado (74 paths, 0 erros).
- Bug real encontrado por teste (nao so a suite existente): `setState(() => races = loadMyRaces(...))` retornava a `Future` da atribuicao para o callback do `setState` (erro "setState() callback argument returned a Future"); corrigido usando bloco `{ }`.
- Correcao de regressao visual relatada pelo usuario apos o primeiro `.apk` (v9/v10): a medalha "redonda" aparecia achatada em elipse porque o recorte usava a area retangular (nao quadrada) sobrando no `Expanded`; corrigido com `Center(child: AspectRatio(aspectRatio: 1, ...))`. Segunda rodada de ajuste (apos v11/v12): a medalha ficava pequena com espaco vazio ao redor porque o `AspectRatio` ficava limitado pela altura (menor que a largura) sobrando no card; corrigido recalculando o `childAspectRatio` da grade. Terceira rodada (apos comparacao direta com o template): removido o card/borda/sombra ao redor de cada medalha (o template nao tem), fita redesenhada em formato de bandeirola com `CustomPaint` (antes eram dois retangulos girados) e prancha de madeira alargada para acompanhar a largura da medalha.
- `make check` (247 testes, so a falha de permissao `0o600` pre-existente do Windows) e `flutter test` (163 testes) verdes; `flutter analyze` sem apontamentos.
- **Causa raiz encontrada para "a edicao de forma/cor nao salva" relatado pelo usuario**: nao era bug de logica — o backend com os campos novos nunca tinha sido implantado no DEV. Confirmado por HTTP sem credenciais: `/participations/{id}/display-image` respondia 404 (rota inexistente) antes do deploy desta rodada.
- Autorizado pelo usuario ("sim"). Stack `runpass-dev-app` (UPDATE), change set `medalhas-customizacao-213445`, pacote `lambda/runpass-1ed102e824baf9e4.zip`. Anterior: `lambda/runpass-5049eb98a6159220.zip`. So codigo das Lambdas e re-vinculos (8 mudancas: `ApiFunction`, `AuditConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`, `Maintenance`, `Publisher`, `ScoreConsumer`); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`. Commit local `5ae0751` (branch `feat/amizade-decimal-listas-relacao`, ainda sem PR aberto para esta rodada).
- Verificacao feita (sem credenciais, so HTTP): `/participations/{id}/display-image` passou de 404 para 401 apos o deploy (rota ativa, exige token). **Nao** verificado ainda com usuario real: visual da prateleira no device, edicao de forma/cor/legenda persistindo de verdade, reposicionamento de foto ponta a ponta. Depende de novo `.apk` e teste humano.

## Reformulacao do cadastro: genero obrigatorio, codigo de inscricao nao sequencial, foto opcional (20/11/2026)

- Decisoes de produto do usuario: (1) genero obrigatorio na admissao; (2) idade minima de admissao confirmada em 13 anos (o codigo/SPEC ja usavam 13; `implementation-slices.md` estava desalinhado, corrigido); (3) numero de inscricao sorteado e reservado por claim atomico, nunca sequencial, para nao revelar quantas contas existem; (4) foto de perfil deixa de ser obrigatoria no cadastro.
- Contrato (`API-RunPass-v1.openapi.json`): `gender` (enum `female`/`male`/`undisclosed`) e `registrationCode` adicionados a `OwnProfile`/`PatchOwnProfile`/`BetaAdmissionInput`, owner-only, mesmo tratamento de privacidade do `birthDate`. Modelo DynamoDB (`MODELO-DYNAMODB-RunPass-v1.md`) documenta `REGCODE#codigo / CLAIM`, mesmo padrao do `USERNAME#.../CLAIM`.
- Backend (`service.py`/`models.py`): admissao exige `gender` no mesmo corpo do `birthDate`/`declaresAdult` (nao em PATCH separado); sorteio do codigo de 5 digitos com retentativa em colisao (ate 20 tentativas); corrigido bug introduzido nesta mesma rodada onde a escrita em `PRIVATE` na admissao sobrescrevia o item inteiro em vez de mesclar.
- Mobile (`main.dart`, `registration_card.dart` novo): cadastro reordenado (perfil -> genero+nascimento -> cidade -> foto opcional -> celebracao), com uma "ficha de inscricao" que se preenche a cada passo; tela final com edicao por toque (tocar em qualquer bloco da ficha volta ao passo correspondente).
- `make check` (440 testes, so a falha de permissao `0o600` pre-existente do Windows) e `flutter test` (413 testes) verdes; `flutter analyze` sem apontamentos. Precisou atualizar a fixture de admissao (`ADULT`) e ~20 chamadas inline em 10+ arquivos de teste, o seed do `local_api.py` e um fixture do Bruno, todos sem o campo `gender` antes desta rodada.
- **Causa raiz encontrada para "a tela de genero/nascimento nao avanca" relatado pelo usuario no `.apk`**: nao era bug de logica — o backend com `gender` nunca tinha sido implantado no DEV; o modelo Pydantic la (`extra="forbid"`) rejeitava o campo novo com 422.
- Autorizado pelo usuario ("sim"). Stack `runpass-dev-app` (UPDATE), change set `cadastro-genero-codigo-095849`, pacote `lambda/runpass-a19e2672bac890d3.zip`. Anterior: `lambda/runpass-f12e9f63cf5bca34.zip` (ver change set mais recente antes desta rodada). So codigo das Lambdas e re-vinculos (8 mudancas: `ApiFunction`, `AuditConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`, `Maintenance`, `Publisher`, `ScoreConsumer`); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais, so HTTP): `GET /me` e `GET /beta/status` respondem 401 sem token (rotas no ar); rota inexistente responde 404. **Nao** verificado ainda com usuario real: fluxo completo de cadastro no device (genero obrigatorio salvando, codigo de inscricao aparecendo na ficha, foto realmente opcional). Depende do novo `.apk` (`runpass_app_android_teste_v45.apk`) e teste humano.

## Ajustes de UX do cadastro apos teste humano no `.apk` (20/11/2026)

- Usuario testou o `.apk` da rodada anterior e relatou 10+ problemas visuais: splash nativa escura ao abrir, texto da tela inicial quebrando linha, botao de ver senha compartilhado entre telas, rotulo de nome desatualizado, botoes de genero grandes/desiguais, faixa etaria aparecendo na ficha (produto decidiu remover, mesmo contrariando o prototipo visual de referencia), texto da cidade quebrando linha, ficha de inscricao "toda desconfigurada" na celebracao final sem a foto do usuario.
- **Causa raiz investigada com teste automatizado em largura estreita** (360px, simulando aparelho Android real; os testes existentes rodam a 800px, por isso nao pegavam isso): reproduzido `RenderFlex overflowed by 123 pixels` no cabecalho do seletor de data de nascimento (`Row` com titulo + botao "Concluido" sem nenhum dos dois ser flexivel) — isso desconfigurava a ficha a partir dali, inclusive na celebracao (mesmo widget `RegistrationCard`). Mesmo padrao corrigido em `location_picker.dart` (seletor de cidade).
- Corrigido: `android/.../values-night/styles.xml` (splash e janela nativa sempre no tema claro, independente do Modo Escuro do sistema, coerente com o app que abre claro por padrao); texto "Mais que corridas / Sao historias para sempre" com `FittedBox` por linha; botoes de genero menores e uniformes (pilula, mesma altura); texto da declaracao de idade menor; faixa etaria removida de `registration_card.dart` (campo `ageBucket` excluido, ficha mostra so a letra do genero); numero de inscricao mostra `00000` como placeholder ate o backend devolver o numero real (decisao do usuario, em vez de deixar em branco) — evita teria que mudar o backend para reservar o numero mais cedo.
- Validado com teste automatizado reproduzindo o fluxo completo (cadastro -> confirmacao -> senha -> perfil -> genero/nascimento -> cidade -> foto -> celebracao) numa tela de 360x740: sem overflow em nenhuma etapa, selo "INSCRICAO CONFIRMADA" e foto aparecem certo na celebracao.
- **Decisao do usuario sobre acesso incompleto**: confirmado por leitura do codigo (sem mudanca necessaria) que `resume()`/`status()` ja impedem chegar no Inicio sem perfil+admissao+decisao de foto completos, e que interromper sempre retoma na etapa certa, nunca exige outro e-mail. Perguntado sobre apagar do Cognito quem nunca termina o cadastro: Cognito nao tem recurso nativo para isso (confirmado via documentacao AWS), exigiria Lambda agendado proprio. **Adiado pelo usuario** ("isso fica para depois") — item de infraestrutura separado, fora do escopo desta rodada.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes apos os ajustes. Gerado `.apk` (`runpass_app_android_teste_v47.apk`) e testado pelo usuario em aparelho real.

## Correcoes apos 2a rodada de teste humano no `.apk` v47 (20/11/2026)

- **Numero de inscricao preso em "00000" durante todo o cadastro**: causa raiz no mobile, nao no backend — `registrationCode` so e devolvido por `GET /me` (o `PUT`/`PATCH` nunca o incluem, confirmado lendo `service.py`: so `profile()` mescla o campo de `PRIVATE`; `create_profile`/`patch_profile` devolvem so `public_profile()`). O app assumia (errado) que viria na resposta do `PUT /me` da tela de perfil, antes mesmo da admissao existir (o codigo so e sorteado dentro de `admit()`, so na admissao direta, nunca na lista de espera). Corrigido: busca `GET /me` logo depois do `POST /beta/admissions` ter sucesso.
- **Cidade sumia da ficha nas telas de foto e celebracao**: `status()` zerava `selectedUf`/`selectedCity` logo depois do PATCH de localizacao (para nao reenviar), mas a ficha usa essas mesmas variaveis pra mostrar a cidade nas telas seguintes. Trocado por uma flag separada (`locationSynced`) que so controla o reenvio, sem apagar o que a ficha mostra.
- **Editar um bloco da ficha na celebracao final dava "Não foi possível concluir agora"**: a edicao reusava a mesma logica de avanco do cadastro original — editar nascimento/genero tentava chamar `POST /beta/admissions` de novo (conta ja admitida, backend recusa) e editar nome tentava recriar o perfil (`PUT`), em vez de so corrigir o campo. Adicionado um modo de edicao (`editingFromCelebration`) que usa `PATCH /me` (a mesma rota que a edicao de perfil normal ja usa em outras telas do app) e volta direto pra celebracao, sem repetir nenhuma acao de admissao.
- **Nome de usuario nao sugeria a partir do nome**: adicionada sugestao automatica (sem acento, minusculo, palavras com "_") enquanto a pessoa nao mexer no campo de usuario por conta propria; editar o nome depois de ja ter mexido no usuario nao sobrescreve mais a escolha dela.
- **Rotulo "Nome e Sobrenome" sumia ao tocar no campo**: `floatingLabelBehavior` nao estava fixado, entao o rotulo flutuava so com foco/conteudo; trocado para sempre visivel (`FloatingLabelBehavior.always`) em todo o app, pra nao voltar a sumir em nenhum campo.
- **Imagem da medalha (escolher foto) sobrepondo o texto acima**: o `MedalAvatar` pinta a fita do cordao acima do proprio circulo de proposito (pra nao ser cortada), mas o espaco antes dele era curto demais pra essa fita. Aumentado o espaco.
- Exclamacao adicionada em "Bem-vindo [nome]" na celebracao.
- Validado com teste automatizado dedicado (sugestao de usuario, codigo real aparecendo, cidade na ficha em foto/celebracao, edicao de genero/nascimento/cidade/nome a partir da celebracao sem re-chamar admissao nem mostrar erro) — removido do repositorio apos confirmar, por ser so de verificacao pontual.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v48.apk`) e testado pelo usuario em aparelho real.

## Correcoes apos 3a rodada de teste humano no `.apk` v48 (20/11/2026)

- **Bug critico: travava apos informar a data de nascimento, impedindo testar o resto do cadastro**. Causa raiz: a busca do codigo de inscricao (`GET /me`) adicionada na rodada anterior, logo depois do `POST /beta/admissions`, nao tinha protecao contra falha; qualquer instabilidade ali (rede, cold start) deixava a admissao ja concluida no servidor mas o app preso na mesma tela, e toda nova tentativa de "Continuar" reenviava `POST /beta/admissions`, que o backend recusa corretamente (`ALREADY_ADMITTED`) por a conta ja estar admitida — um beco sem saida permanente. Corrigido: a busca do codigo agora e so uma conveniencia, nunca bloqueia o avanco se falhar (o codigo chega na proxima vez, via `resume()`); e `ALREADY_ADMITTED` na admissao passa a ser tratado como sucesso (idempotente), nunca mais como erro.
- `floatingLabelBehavior` sempre visivel (ligado na rodada anterior) jogou luz num efeito colateral: "Gênero" (texto simples) e "Data de nascimento" (rotulo flutuante do campo) nao estavam alinhados horizontalmente; alinhados com o mesmo recuo.
- "Nome e Sobrenome" -> "Nome e sobrenome"; limite de caracteres reduzido (nome 30, usuario 20, refletido no contador "0/N"); campo de usuario ganhou o prefixo fixo "@", igual ao que a ficha mostra.
- Sugestao automatica do usuario agora se autocorrige sozinha se o nome sugerido ja estiver em uso (tenta de novo com um sufixo numerico, sem incomodar quem nunca mexeu no campo); quem edita o usuario na mao continua sem nenhuma interferencia. Nao existe (e nao foi criada) uma rota de "checar disponibilidade" em tempo real no contrato; a garantia de unicidade continua sendo o proprio servidor, na hora de salvar.
- "Selecionar data de nascimento" trocado por um "DD/MM/AAAA" discreto (formato, nao instrucao) antes de escolher; espaco entre os botoes de genero e "Prefiro não me identificar" reduzido; campos da tela "Como você quer ser chamado?" descidos (ficavam colados na ficha).
- Validado com dois testes automatizados dedicados: um reproduzindo a falha simulada na busca do codigo (confirma que o cadastro segue em frente mesmo assim, sem re-chamar a admissao) e outro reproduzindo um nome de usuario ja em uso (confirma a autocorrecao, sem mostrar erro) — ambos removidos do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v49.apk`) e testado pelo usuario em aparelho real.

## Correcoes apos 4a rodada de teste humano no `.apk` v49 (20/11/2026)

- **Dois sintomas, uma unica causa raiz, de novo travando o cadastro logo na 1a tela**: "nome de usuario nao preenche sozinho" e "nao deixa avancar" eram o mesmo bug. `TextField.onChanged` do Flutter dispara sempre que o *controller* muda de valor — inclusive quando e o proprio codigo da sugestao automatica escrevendo nele, nao so quando a pessoa digita. Resultado: na primeira letra do nome, a sugestao automatica escrevia no campo de usuario, isso por si so disparava o `onChanged` do campo (como se a pessoa tivesse mexido nele), marcando "usuario editado por conta propria" e desligando a sugestao para sempre — presa com um valor de uma letra so, curto demais para passar na validacao (minimo de 3 caracteres), travando o avanco sem mensagem clara (erro so visivel no proprio campo).
- Corrigido com um `FocusNode` dedicado no campo de usuario: so conta como "a pessoa mexeu" quando o `onChanged` dispara com o campo em foco (ou seja, ela esta digitando ali de verdade); a escrita programatica da sugestao automatica, que acontece enquanto o foco esta no campo de nome, nao conta mais.
- **Licao para proximas automacoes neste campo**: os testes anteriores usavam `tester.enterText()` com o nome inteiro de uma vez so, o que mascarava esse bug (o controller muda uma unica vez, igual a sugestao programatica interna, sem o efeito cascata). Só reproduziu digitando letra por letra (`enterText` incremental, uma chamada por letra) — mais fiel a uma pessoa de verdade no teclado. Teste assim removido do repositorio apos confirmar o conserto.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v50.apk`) e testado pelo usuario em aparelho real.

## Correcoes apos 5a rodada de teste humano no `.apk` v50 (20/11/2026)

- **Decisao de produto corrigida**: a faixa etaria **nao** deveria ter sido retirada da ficha — o pedido de 19-20/11 foi mal interpretado nesta instancia; o usuario confirmou agora que ela deve continuar, junto com o genero, no formato do protótipo aprovado ("M 35-39", so espaco, sem traço). Revertido: `ageBucket()` restaurado em `registration_card.dart`, categoria volta a combinar letra+faixa.
- **Bug de "nao avanca" na tela de genero/nascimento, 3a vez reportado, causa raiz ainda nao confirmada**: as duas hipoteses investigadas e corrigidas nas rodadas anteriores (busca do codigo sem protecao, onChanged disparando na sugestao automatica) eram bugs reais, mas o usuario confirmou que o bloqueio continua, com a mensagem generica de erro ("Não foi possível concluir agora...") — ou seja, algum `IdentityIssue` com codigo ainda nao mapeado continua sendo lancado nesse passo, e **nao sabemos qual ainda**, so a mensagem generica. Para nao continuar adivinhando as cegas: a mensagem generica agora expõe o codigo do erro (`'Não foi possível concluir agora (código ${error.code})...'`), e mapeadas mensagens especificas para `BETA_CLOSED`, `EMAIL_NOT_VERIFIED`, `ADMISSION_INTEGRITY_FAILURE`, `CAPACITY_AVAILABLE`, `CONCURRENT_RETRY_REQUIRED` (nenhuma delas confirmada como a causa real ainda, so cobertura defensiva). **Proximo teste deve reportar o codigo exato que aparecer entre parenteses**, para eu confirmar e corrigir a causa raiz de verdade, em vez de corrigir sintomas.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v51.apk`) e testado pelo usuario em aparelho real.

## Causa raiz confirmada: "PROFILE_EXISTS" (20/11/2026)

- O codigo exposto na mensagem de erro (ver rodada anterior) deu a resposta: `PROFILE_EXISTS` (409 do `create_profile()`). Cenario relatado: usuario fechou e reabriu o app no meio do cadastro (perfil ja criado, antes da admissao); ao reabrir, **o campo de usuario aparecia vazio na ficha**; ele voltava pra tela de perfil, reescrevia o nome (preenchendo o usuario de novo so localmente) e tocava Continuar, que tentava **criar** o perfil de novo (`PUT /me`) — o backend recusa corretamente, pois o perfil ja existe.
- **Causa raiz real**: `resume()` nunca repopulava `name.text`/`username.text` a partir do perfil buscado no servidor (so a variavel `displayName`, usada em outro lugar da ficha). Corrigido: `resume()` agora preenche os dois campos a partir do `GET /me`, e marca `usernameTouched = true` (ja tem usuario definido, a sugestao automatica nao deve mais mexer nele).
- Defesa adicional, caso aconteca de novo por qualquer outro caminho: `Step.profile` agora trata `PROFILE_EXISTS` sem travar — busca o perfil existente via `GET /me` e segue em frente com o que ja esta salvo, em vez de mostrar erro. (PATCH /me **nao** serve aqui: exige conta admitida, o que ainda nao aconteceu nesse ponto do cadastro — so leitura e seguir em frente, sem tentar corrigir nome/usuario nesse momento.)
- Validado com teste automatizado que simula um fechar/reabrir de verdade (desmonta a arvore de widgets entre as duas "sessoes", nao so troca a instancia do gateway — um `pumpWidget` com o mesmo tipo de widget na raiz preserva o `State` em memoria, o que mascarava exatamente esse tipo de bug de "esqueceu de repopular um campo"). Confirma usuario aparecendo na ficha apos reabrir, e reenvio do mesmo nome sem erro visivel. Removido do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v52.apk`) e testado pelo usuario em aparelho real.

## Investigacao do "INVALID_INPUT" na admissao (20-21/11/2026)

- Usuario reportou o codigo real pela 1a vez: `INVALID_INPUT`, com todos os campos visivelmente preenchidos (genero Masculino, nascimento 23/10/1953, declaracao marcada) — ver `Cadastro_Erro.jpeg`. Esse codigo vem de `RequestValidationError` do FastAPI (`api.py`), um erro de validacao do Pydantic no corpo ou nos parametros da requisicao, generico de proposito (o handler nao registra o corpo, pode conter data de nascimento).
- Investigacao feita sem conseguir reproduzir ao vivo (criar uma conta Cognito real para testar foi bloqueado pelo classificador de seguranca do Claude Code, corretamente — acao potencialmente destrutiva/indesejada sem autorizacao explicita do usuario):
  - Validado localmente o payload exato do print (`birthDate: "1953-10-23", declaresAdult: true, gender: "male"`) direto contra o modelo `Eligibility` real do backend (`PYTHONPATH=backend python -c "from runpass.models import Eligibility; Eligibility(**payload)"`): **aceita sem erro**. O corpo em si nao e o problema.
  - Conferido o `Idempotency-Key` gerado pelo app (32 caracteres hex) contra o padrao exigido (`^[A-Za-z0-9._:-]+$`, 1-128 caracteres): **valido**.
  - Conferido ao vivo (so leitura) o contador de vagas do DEV (`BETA#v1/CONTROL` na `IdentityTable`): `count=17`, bem abaixo do limite de 1000, sem `endsAt` — `admissionsOpen` deve estar `true`, app deveria ir para `/beta/admissions` (nao `/beta/waitlist`), afastando essa hipotese tambem.
  - `curl` direto no endpoint real confirmou que a autenticacao e checada antes da validacao do corpo (401 sem token, mesmo com corpo valido) — nao da pra isolar so a validacao sem um token real, e criar um para testar foi a acao bloqueada acima.
- **Causa raiz ainda nao confirmada.** Como nao da pra investigar mais fundo sem reproduzir contra o servidor real (e isso exige autorizacao explicita do usuario para criar uma conta de teste), a mensagem de erro agora mostra tambem **a rota e o corpo exato enviados** quando `INVALID_INPUT` acontecer na admissao, para a proxima rodada trazer o dado que falta em vez de mais suposicao.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v53.apk`) e testado pelo usuario em aparelho real.

## Causa raiz confirmada e corrigida: deploy do backend desatualizado (21/11/2026)

- **Autorizado pelo usuario** ("autorizo o teste") a criar uma conta de teste real para reproduzir o `INVALID_INPUT` contra o servidor de verdade, ja que nao foi possivel isolar so a validacao sem um token real (autenticacao e checada antes do corpo). Conta criada via `aws cognito-idp sign-up`, codigo de confirmacao lido no Gmail do proprio usuario (`runpasslife+debug...@gmail.com`), confirmada e autenticada via `initiate-auth` (USER_PASSWORD_AUTH).
- Reproduzido o erro exato (`POST /beta/admissions` com `birthDate`/`declaresAdult`/`gender` do print do usuario -> 422 INVALID_INPUT) contra o endpoint real. **Causa raiz: nao era bug de codigo em lugar nenhum (nem mobile, nem backend) — era deploy desatualizado.** Baixado o pacote realmente publicado no Lambda (`aws lambda get-function` + download do `Code.Location`) e confirmado que o modelo `Eligibility` de la **nao tem o campo `gender`**; como o modelo usa `extra="forbid"`, mandar esse campo e recusado. O `ArtifactKey` publicado (`lambda/runpass-d36ee4d5c6cb4730.zip`) nao bate com nenhum dos hashes registrados nas rodadas anteriores desta mesma reformulacao (`...1ed102e8...`, `...a19e2672...`, `...f12e9f63...`) — alguma rodada anterior, por engano, atualizou a stack com um pacote mais antigo que o que tinha sido revisado, desfazendo o deploy do gender/codigo de inscricao sem ninguem perceber.
- **Corrigido**: `make check` (ruff, contrato, 440 testes backend so a falha `0o600` pre-existente do Windows) e `cfn-lint` verdes no commit `95e6dee` (o mesmo ja usado no `.apk` v53). Empacotado com `scripts/package-lambda.sh`, conferido que `gender` esta no zip antes de subir. Pacote `lambda/runpass-3f9ffc036fcfe0eb.zip`, enviado ao bucket de artefatos. Change set `corrige-gender-deploy-003623` em `runpass-dev-app`: 8 mudancas (`ApiFunction`, `AuditConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`, `Maintenance`, `Publisher`, `ScoreConsumer`), sem IAM, sem substituicao — revisado e executado, `UPDATE_COMPLETE`.
- **Verificado de ponta a ponta com uma 2a conta de teste real** (criada, confirmada, apagada ao final): `POST /beta/admissions` com os mesmos dados do print agora responde `201 {"admitted": true}`, e `GET /me` devolve `gender`, `birthDate` e `registrationCode` corretamente. As duas contas de teste criadas nesta investigacao foram apagadas (`DELETE /me`, que tambem remove do Cognito) ao final de cada verificacao.
- **Licao para proximas rodadas**: quando um relato de bug persiste apos varias correcoes de codigo plausiveis mas nao confirmadas, verificar se o codigo *implantado* realmente corresponde ao codigo local (`aws lambda get-function` + baixar e comparar), antes de continuar ajustando o codigo-fonte — nesse caso, nenhuma das correcoes anteriores nesta sessao (retomada de cadastro, PROFILE_EXISTS, username, etc.) estava errada, so nao resolvia porque o problema real era outro, mais a montante.

## Ajustes de UX apos cadastro completo pela 1a vez (21/11/2026)

- **Editar nome/usuario apos avancar nao efetivava a mudanca**: causa raiz no fix de `PROFILE_EXISTS` da rodada anterior — ele buscava o perfil ja salvo e seguia em frente, mas sem avisar que a mudanca pedida nao tinha entrado (PATCH /me exige conta admitida, o que so acontece depois; nao ha hoje como editar nome/usuario antes da admissao). Corrigido para nao ser silencioso: se o valor pedido for diferente do salvo, mostra aviso explicito ("ja confirmados, da pra ajustar depois no perfil") e restaura os campos para o valor real, em vez de fingir sucesso. **Isso continua sendo uma limitacao de contrato, nao so de UI** — se o produto quiser permitir editar nome/usuario antes da admissao, precisa de decisao e, provavelmente, afrouxar o `admitted=True` do `patch_profile` so pra esses dois campos.
- **Pre-selecao de localizacao por GPS "parou de funcionar"**: codigo conferido, continua exatamente como antes (nada regrediu) — mas e so uma tentativa automatica e silenciosa, dependente de permissao do aparelho que pode ter mudado (ex. "permitir so desta vez" expira). Adicionado um botao manual ("usar minha localizacao", icone ao lado do campo) pra repetir a tentativa sob demanda, com mensagem clara se nao der certo (sem permissao, GPS desligado, ou qualquer outra falha) — antes era 100% silencioso.
- **Foto da medalha sobrepondo o texto, de novo**: o espaco antes da `const SizedBox` so dava 6px de folga (44 menos o quanto a fita do MedalAvatar realmente precisa); aumentado para uma distancia confortavel (72).
- **Reposicionar a foto ja escolhida**: tocar na foto quando ja tem uma escolhida agora abre direto o recorte nela (`ProfilePhotoCropScreen`), sem pedir pra escolher de novo da galeria/camera; o botao "Trocar foto" continua disponivel pra quem quiser mesmo assim escolher outra do zero.
- **Tela de confirmacao com espaco morto embaixo**: o conteudo ficava alinhado no topo mesmo em telas altas. Trocado por um `LayoutBuilder` + `ConstrainedBox(minHeight)` + `Center`, padrao Flutter pra centralizar conteudo dentro de uma area que ainda pode rolar se precisar (telas baixas); tambem ganhou o mesmo limite de largura (480) das outras telas do cadastro.
- **Regressao pega durante a verificacao**: restaurar a faixa etaria (pedido do usuario na rodada anterior) reintroduziu o mesmo tipo de overflow ja corrigido antes, porque o texto da categoria ("F 35-39" etc) nao estava dentro de um `Expanded`/`Flexible` na ficha — corrigido com `Expanded(flex:3)`/`Expanded(flex:2)` dividindo o espaco entre nascimento e categoria, com elipse como ultimo recurso. So foi pega por testar com texto de categoria mais longo que "Menor de 18" nao tinha sido testado desde a restauracao.
- Validado com testes automatizados dedicados (edicao recusada com aviso e valor restaurado; fluxo completo ate a celebracao em tela estreita de 360px, sem nenhum overflow, com o botao de localizacao presente e o reposicionamento de foto abrindo o recorte) — removidos do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (`runpass_app_android_teste_v54.apk`).

## Decisao de produto: editar nome/usuario antes da admissao (21/11/2026)

- Usuario pediu pra reverter a restricao da rodada anterior: "nao faz sentido ja bloquear, visto que esta realizando o cadastro e nao finalizou ainda". Decisao aceita; muda o contrato (nao so a tela).
- **Backend** (`service.py`, `patch_profile`): `PATCH /me` agora permite corrigir **so** `displayName`/`username` antes da admissao (conta com perfil criado, ainda nao admitida); qualquer outro campo no mesmo payload (foto, genero, nascimento, localizacao, bio etc) continua exigindo `admitted=True`, sem mudanca nenhuma af. Contrato (`API-RunPass-v1.openapi.json`) atualizado com essa excecao na descricao de `patchOwnProfile`; aproveitado pra corrigir tambem uma frase desatualizada ali ("no birth date changes"), que ja nao era verdade havia tempo (a propria patch_profile trata `birthDate` desde a decisao de genero/codigo de inscricao).
- **Mobile** (`main.dart`): o que antes so avisava "não pode mudar ainda" e restaurava o valor salvo agora de fato chama `PATCH /me` com o novo valor e segue em frente — a edicao entra de verdade.
- Teste novo no backend (`test_identity.py`): confirma que nome/usuario sozinhos passam sem admissao, e que qualquer outro campo (`bio` no teste) continua recusado com `BETA_ADMISSION_REQUIRED`. `make check` equivalente rodado manualmente (`ruff`, contrato, 441 testes backend so a falha `0o600` do Windows, sem `make` disponivel neste shell) e `flutter analyze`/`flutter test` (413 testes) verdes.
- Validado com teste automatizado dedicado reproduzindo o cenario completo (cria perfil, volta, edita o nome de verdade, confirma que foi salvo via PATCH e que a tela avanca sem nenhum aviso de bloqueio) — removido do repositorio apos confirmar.
- **Autorizado pelo usuario** ("sim") e implantado. Pacote `lambda/runpass-743b577fe7063042.zip`, commit `95e6dee` + os ajustes desta sessao. Change set `patch-preadmissao-012706` em `runpass-dev-app`: as mesmas 8 mudancas de sempre (so codigo das Lambdas e re-vinculos, sem IAM, sem substituicao). `UPDATE_COMPLETE`.
- **Verificado contra o servidor real** com uma conta de teste (criada, confirmada, apagada ao final): `PUT /me` cria o perfil (201); `PATCH /me` so com `displayName`/`username`, sem admissao, responde `200` e salva de verdade; `PATCH /me` com `bio` (ou qualquer outro campo), sem admissao, continua respondendo `403 BETA_ADMISSION_REQUIRED` como antes. Comportamento confirmado em producao de teste, nao so em testes automatizados.
- **Falha do proprio processo**: depois do deploy do backend, relatado ao usuario como pronto para testar sem gerar um novo `.apk` — o `.apk` entregue (`v54`) tinha sido empacotado **antes** da mudanca no mobile (so o texto de aviso antigo, nunca o `PATCH`), entao o teste do usuario reproduziu exatamente o comportamento antigo. Corrigido: `.apk` novo (`runpass_app_android_teste_v55.apk`) gerado com o codigo certo. Licao: depois de qualquer mudanca em `mobile/lib/`, gerar o `.apk` de novo antes de pedir pro usuario testar, mesmo quando a mudanca em questao parecia ser "so do backend".

## Deploy concorrente em DEV derrubou o gender de novo (21/11/2026)

- Apos testar o `.apk` v55, o usuario relatou `INVALID_INPUT` em `/beta/admissions` de novo — o mesmo sintoma da rodada em que o `gender` faltava no Lambda implantado. Investigado: o `ArtifactKey` publicado na stack (`lambda/runpass-7504960b0c51788d.zip`) **nao correspondia a nenhum dos dois deploys feitos nesta sessao** (`...3f9ffc0...` do fix do gender, `...743b577...` do fix do PATCH pre-admissao). O historico de eventos da stack mostrou **4 atualizacoes** `UPDATE_COMPLETE` nas ultimas ~3 horas, mas so 2 foram feitas por este agente — outras 2 vieram de fora desta sessao. `CloudTrail` nao acessivel com o perfil atual para confirmar o autor exato.
- **Usuario confirmou**: ha outra pessoa/sessao implantando no mesmo `runpass-dev-app` ao mesmo tempo, com codigo mais antigo (sem `gender`), sobrescrevendo os deploys feitos aqui. Pediu pra reimplantar mesmo assim e avisar essa pessoa depois (em vez de esperar coordenacao antes de seguir).
- **Reimplantado** o pacote correto (`lambda/runpass-743b577fe7063042.zip`, ja validado antes, so reapontado) via change set `redeploy-apos-sobrescrita-014559`, mesmo padrao de sempre (so Lambdas, sem IAM). `UPDATE_COMPLETE`. Verificado de novo com conta de teste real: `gender` aceito na admissao (201) e o `PATCH` pre-admissao de nome/usuario continuam funcionando.
- **Risco real e nao resolvido**: como ha deploys concorrentes de fora desta sessao nesse mesmo ambiente DEV compartilhado, **o proximo deploy de outra pessoa pode sobrescrever isto de novo**, sem aviso. Antes de qualquer proximo deploy nesta sessao, vale conferir se o codigo publicado ainda bate com o esperado (`aws lambda get-function` + baixar e comparar), e o time precisa combinar quem implanta e quando nesse ambiente, pra parar de desfazer o trabalho um do outro.

## Decisao de produto: usuario sempre acompanha o nome (21/11/2026)

- Usuario testou a edicao de nome/usuario (aprovou) e notou que editar "Nome e sobrenome" de novo nao atualizava mais o "Nome de usuário" sugerido. Confirmado: por desenho, a sugestao automatica so agia enquanto a pessoa nunca tivesse editado o usuario na mao (pra nao apagar uma escolha deliberada); perguntado ao usuario se queria manter assim ou sempre sincronizar, mesmo apagando uma personalizacao anterior — escolheu sempre sincronizar.
- **Mobile** (`main.dart`): removida a trava `usernameTouched`; agora toda edicao de nome recalcula e reescreve o usuario sugerido, mesmo que a pessoa tenha personalizado o usuario antes. `usernameTouched` continua existindo (controla a autocorrecao de usuario-ja-em-uso, ver rodada anterior) mas volta a `false` toda vez que o nome e editado de novo, porque o campo fica "sugerido" outra vez.
- **Cuidado ja coberto**: `resume()` e a edicao vinda da celebracao preenchem `name.text` programaticamente (sem a pessoa digitar nada); sem protecao, isso tambem dispararia o listener do nome e reescreveria um usuario ja salvo so por reabrir a tela. Adicionado `FocusNode` no campo de nome (mesma tecnica ja usada no campo de usuario): o recalculo so acontece quando o campo de nome esta com foco de verdade (a pessoa digitando ali), nunca por um preenchimento programatico.
- Validado com teste automatizado dedicado cobrindo os tres casos: editar o nome sem nunca ter tocado no usuario (sincroniza); personalizar o usuario na mao e depois editar o nome de novo (reescreve, decisao do usuario); fechar/reabrir o app sem editar nada (usuario salvo no servidor NAO muda sozinho) — removido do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. Gerado `.apk` (nao numerado nesta nota, substituido pela correcao abaixo antes de qualquer teste humano).

## Regressao: tela da foto pulada apos editar nome antes da admissao (21/11/2026)

- Usuario testou (gostou da edicao de nome/usuario) e reportou, no meio do teste, que a tela "Sua foto de perfil" estava sendo pulada. Causa raiz: `needsPhoto` usava `profile['version'] == 1` como sinal de "cadastro ainda nao concluido, foto ainda nao decidida" — um sinal que so funcionava porque, antes da decisao desta sessao, nada conseguia alterar o perfil antes da foto. Agora que `PATCH /me` pre-admissao e permitido (rodada anterior), corrigir nome/usuario sobe a versao do perfil (de 1 para 2+) **antes** da pessoa chegar na tela de foto, fazendo o app achar que o cadastro ja tinha passado da fase de foto.
- **Corrigido em dois lugares**: (1) no fluxo da mesma sessao (`Step.profile`), so recalcula `needsPhoto` a partir da versao quando o `PUT` realmente **criou** o perfil agora (`justCreated`); corrigir nome/usuario de um perfil que ja existia (`PROFILE_EXISTS` -> `PATCH`) nunca mexe em foto, entao mantem o que ja estava certo, em vez de reavaliar com uma versao que so subiu por causa da correcao. (2) em `resume()` (reabrir o app no meio do cadastro), trocado `version == 1` por `version <= 4`: tolera as poucas edicoes possiveis nessa fase (correcao de nome/usuario, patch de localizacao), continuando bem mais baixo do que a quantidade de edicoes que alguem acumula so de usar o app por um tempo (decisao: nenhum numero exato de edicoes de fato concluidas e guardado hoje, entao e um numero generoso, nao uma garantia).
- Pega durante a correcao: a versao generosa (`<= 4`) quebra com `null` quando o campo `version` esta ausente da resposta (um teste existente simula isso) — `null <= 4` lanca excecao em Dart, nao so avalia falso. Corrigido tratando versao ausente como "nao fresco" (`?? 999`), igual ao comportamento anterior pra essa situacao.
- Validado com teste automatizado dedicado reproduzindo o cenario exato (editar nome pre-admissao, versao sobe pra 2, segue para admissao/localizacao e confirma que a tela da foto ainda aparece, sem pular pra celebracao) — removido do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. **Limitacao conhecida, nao resolvida**: o sinal `version <= 4` e um numero heuristico, nao uma garantia — alguem que edite nome/usuario mais de 3 vezes antes de decidir a foto ainda cairia nesse caso ao reabrir o app nesse meio-tempo. Resolver de verdade exigiria um sinal proprio no backend (ex.: marcar quando a foto foi de fato decidida), fora do escopo desta correcao pontual.

## Ajuste visual: ficha de inscricao maior (21/11/2026)

- Usuario aprovou o fluxo completo ("ficou muito bom, tudo funcionando") e pediu a ficha de inscricao maior, com mais destaque, sem gerar rolagem em nenhuma tela, com o mesmo tamanho novo em todas elas.
- `RegistrationCard` (`registration_card.dart`) ja e um unico widget compartilhado entre as 4 telas do cadastro e a celebracao — aumentar ali automaticamente aplica o novo padrao em todo lugar, sem risco de inconsistencia entre telas (coerente com a regra de padrao unico por funcao do `AGENTS.md`). Aumentado: faixa lateral 128->150px, avatar raio 30->36, numero de inscricao 23->26, nome 21->24, demais textos/espacamentos proporcionalmente.
- Pega durante o aumento: a linha do topo (logo + data/cidade) passou a estourar a largura em telas estreitas (`Row` sem nenhum filho flexivel) — corrigido com `Expanded`/`Flexible` e elipse, mesma categoria de bug ja visto antes nesta sessao (texto sem `Expanded` numa `Row` estreita).
- **Para caber sem rolagem com a ficha maior** (a tela de genero/nascimento, a mais cheia de conteudo, precisou de mais ajuste): tema global `contentPadding` dos campos reduzido (todo campo de texto do app fica um pouco mais compacto, nao so o cadastro); botoes de genero perderam a area de toque minima de 48dp do Material (`tapTargetSize: shrinkWrap`, que antes reservava espaco mesmo com a altura visivel menor — o mesmo valia pros botoes de genero, so nao tinha sido notado antes); aviso "não é pública" sobre a data de nascimento virou um icone com tooltip em vez de uma linha de texto a parte; espacamentos do cabecalho (progresso/titulo/ficha) comprimidos; avatar da tela de foto reduzido de raio 56 para 48 (a fita do MedalAvatar, que pinta acima do proprio circulo, precisa de menos folga num avatar menor).
- Validado com teste automatizado medindo o espaco de rolagem restante (`maxScrollExtent`) nas 4 telas do cadastro, em duas alturas de aparelho: **360x740 (o tamanho usado em toda esta sessao, confirmado pelo usuario) fica em zero rolagem em todas as 4 telas**; um aparelho extremo de 360x660 (tipo iPhone SE) ainda precisa de uma rolagem pequena (9px na tela de genero/nascimento, 59px na tela de foto) — aceito como limite conhecido, nao perseguido mais a fundo por falta de ganho proporcional ao esforco. Teste removido do repositorio apos confirmar.
- `flutter analyze` sem apontamentos e `flutter test` (413 testes) verdes. **Nao** verificado ainda com usuario real nesta rodada; depende de novo `.apk`.

## Deploy de várias fotos no post e do km de corrida sem distância no DEV - 20/11/2026

- Autorizado pelo usuario ("publique o backend do DEV"). Change set `fotos-km-155342` da stack `runpass-dev-app` (UPDATE), pacote `lambda/runpass-5606d792cb647e2c.zip` (commit `84698c7`, PRs #118 e #119). Anterior: `lambda/runpass-a19e2672bac890d3.zip` (volta por troca da chave `ArtifactKey`).
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- O que entrou: `POST /editions/{id}/distances` aceita o km como numero ou texto (antes recusava todo pedido com 422); publicacao com ate 5 fotos (`morePostImageReferences`, `postImageCount`, `?index=N` em `/participations/{id}/post-image` e `/posts/{id}/image`).
- Verificacao feita: `GET /me`, `POST /editions/x/distances` e `GET /participations/x/post-image?index=1` respondem 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: informar o km de corrida sem distancia, publicar e editar com varias fotos, carrossel no feed.


## Deploys do conserto do km e da foto de quem avaliou no DEV - 20/11/2026

- **`km-versao-200029`** (UPDATE, `runpass-dev-app`): autorizado pelo usuario ("publique o backend do DEV"). Pacote `lambda/runpass-6ca226f887615fbd.zip` (commit `341a9a2`, PRs #126 a #128). Anterior: `lambda/runpass-5606d792cb647e2c.zip`. Entrou: informar o km de corrida sem distancia deixa de dar 422 `INVALID_VERSION` (a versao vinda do DynamoDB como Decimal e convertida para inteiro; o mesmo na atualizacao de descobertas do portal).
- **`avaliacao-autor-200654`** (UPDATE, `runpass-dev-app`): publicado apos o merge do PR #129, com o pedido do usuario de fazer o merge e instalar. Pacote `lambda/runpass-f35ec59d14a479cf.zip` (commit `6123376`). Anterior: `lambda/runpass-6ca226f887615fbd.zip`. Entrou: a lista de avaliacoes da corrida traz o cartao publico de quem avaliou (o app mostra a foto do perfil).
- Mudancas nos dois: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem recursos novos, sem IAM, sem tabelas. Resultado: `UPDATE_COMPLETE` nos dois.
- Verificacao feita: `POST /editions/x/distances` e `GET /editions/x/reviews` respondem 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: informar o km e a foto de quem avaliou.

## Deploy da permissao do km e da busca de amigos no DEV - 20/11/2026

- **`km-amigos-205055`** (UPDATE, `runpass-dev-app`): autorizado pelo usuario ("publique o backend do DEV"). Pacote `lambda/runpass-9b89311641fad6e4.zip` (commit `e2c39e1`, PRs #131 e #132). Anterior: `lambda/runpass-f35ec59d14a479cf.zip`. **Template novo** (nao `--use-previous-template`): o diff contra o template no ar era so a declaracao `RunnerInformedDistance`.
- Causa do erro: informar o km pelo "Ja corri" grava uma nova versao da edicao no catalogo, mas o papel da Lambda da API so lia a tabela do catalogo; o DynamoDB negava e o app recebia 503 `DEPENDENCY_UNAVAILABLE`.
- Entrou: `dynamodb:PutItem` na tabela do catalogo para `ApiFunctionRole` (sem `DeleteItem`); busca de pessoas e sugestoes ordenadas por amigos, amigos de amigos (com `mutualFriends`), seguidos dos seguidos e proximidade (`nearby`), com leituras em paralelo.
- Mudancas: `ApiFunctionRole` (politica inline, sem substituicao) e codigo das Lambdas com re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem recursos novos e sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `GET /me` responde 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: informar o km na corrida sem distancia e a busca de amigos nova.

## Deploy das correcoes da busca geral de bugs no DEV - 20/11/2026

- **`bugs-geral-223712`** (UPDATE, `runpass-dev-app`): autorizado pelo usuario ("ok pode seguir", apos o pedido de merge do PR #135, instalacao e publicacao do backend do DEV). Pacote `lambda/runpass-d36ee4d5c6cb4730.zip` (commit `c04a9ec`, PR #135). Anterior: `lambda/runpass-9b89311641fad6e4.zip`. `--use-previous-template`: o template no ar so difere do repositorio por uma linha em branco no fim.
- Entrou: trocar a distancia de participacao concluida sem avaliacao deixa de dar 503 `PARTICIPATION_INTEGRITY_FAILURE`; sugestao de banner em corrida sem distancia deixa de dar 500; a varredura de pedidos do portal converte a versao (Decimal do DynamoDB) para inteiro; o reparo do indice de inscritos roda em lotes de 20.
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem IAM, sem recursos novos, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `GET /me` responde 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: nenhuma das correcoes acima nem as do app do PR #135.

## Deploy do feedback do app no DEV - 21/11/2026

- **`feedback-013341`** (UPDATE, `runpass-dev-app`): autorizado pelo usuario ("publique o backend do DEV"). Pacote `lambda/runpass-7504960b0c51788d.zip` (commit `b87b4f8`, PR #143). Anterior: `lambda/runpass-d36ee4d5c6cb4730.zip`. `--use-previous-template`: o template no ar so difere do repositorio por uma linha em branco no fim.
- Entrou: `POST /feedback` (Configuracoes > Enviar feedback no app): grava em `history / FEEDBACK#ALL`, ate 10 por dia por pessoa, com a linha em `sharedKeys` para o apagamento da conta.
- Mudancas: apenas codigo das Lambdas e re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem IAM, sem recursos novos, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita: `GET /me` e `POST /feedback` respondem 401 sem token; rota inexistente 404. **Nao** verificado com usuarios reais: o envio de um feedback pelo app.
- Pendente: `GET /admin/feedback` (leitura pela equipe) so vale depois de publicar a Lambda do portal, e ainda nao ha tela no portal para ler os feedbacks.

## Nota de fechamento: a sobrescrita do deploy do gender foi o deploy do feedback

- Ao mesclar com `dev` para este PR, ficou claro o que tinha sobrescrito o deploy do `gender`/codigo de inscricao sem ninguem perceber (ver "Deploy concorrente em DEV derrubou o gender de novo", acima): nao foi um agente ou processo misterioso, foi o **deploy legitimo do feedback do app** (`feedback-013341`, pacote `lambda/runpass-7504960b0c51788d.zip`, commit `b87b4f8`, PR #143 — ver secao acima), feito a partir da `dev` por quem estava cuidando daquela entrega, enquanto o trabalho do cadastro ainda vivia so nesta branch, sem PR aberto. Nao e culpa de ninguem: so o resultado normal de duas pessoas implantarem o mesmo Lambda compartilhado a partir de branches diferentes, sem avisar uma a outra. Mesclar este PR evita que isso se repita, ja que o proximo deploy a partir da `dev` vai incluir as duas mudancas.

## Deploy de sincronizacao do DEV apos o merge do PR #146 (21/11/2026)

- Apos o merge do PR #146, o usuario perguntou se o projeto estava atualizado com tudo implantado no DEV. Verificacao (baixando o codigo da `ApiFunction` em produção via `aws lambda get-function`): o ultimo deploy real (04:27 UTC, pacote `lambda/runpass-743b577fe7063042.zip`) tinha sido feito a partir desta branch **antes** do merge do `dev`, entao tinha o `gender`/PATCH pre-admissao mas **nao** tinha o feedback, o carrossel de fotos, a busca/recomendacao de amigos nem as demais entregas que vieram do `dev` nesse meio tempo — o mesmo padrao de sobrescrita ja visto antes, só que ao contrário (desta vez a branch de cadastro sobrescreveu o `dev`).
- Autorizado pelo usuario ("sim"). Checkout do `dev` já com o merge do PR #146 (`6af67a2`), pacote novo `lambda/runpass-eea1069bddae6c15.zip`, change set `dev-sync-025823` da stack `runpass-dev-app` (UPDATE, `--use-previous-template`). Anterior: `lambda/runpass-743b577fe7063042.zip`. So codigo das Lambdas e re-vinculo da integracao/regra/permissao (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem IAM, sem recursos novos, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Verificacao feita (sem credenciais): baixado o codigo publicado da `ApiFunction` e confirmado que tem `GENDER_REQUIRED`, `only_profile_identity`, o endpoint de feedback, o carrossel de fotos (`morePostImageReferences`), a busca de amigos (`mutualFriends`) e os modulos novos do `dev` (`web_lookup.py`, `admin_discoveries.py`). HTTP sem token: `GET /me` e `POST /feedback` respondem 401, rota inexistente 404. **Nao** verificado com usuarios reais nesta rodada (nenhuma mudanca de codigo, so sincronizar o que já estava testado em cada entrega anterior).

## Deploy do portal com a aba de feedbacks no DEV - 21/11/2026

- **`portal-feedback-020721`** (UPDATE, `runpass-dev-portal`): autorizado pelo usuario ("ok para os 3": merge do PR #145, instalacao e publicacao do portal). Pacote `lambda/runpass-9e7a4eff039aaace.zip` (commit `630afd1`, PR #145). Anterior: `lambda/runpass-31e4c1424aa52b44.zip`.
- Como foi feito: change set com `--use-previous-template` e todos os parametros em `UsePreviousValue`, menos `ArtifactKey`. **Nao** foi usado `scripts/deploy-portal.sh`: ele enviava os parametros opcionais (chave e precos da OpenAI, projeto, papel do agendador) vazios por padrao e teria apagado os valores no ar. O script foi corrigido neste mesmo PR.
- Entrou: aba "Feedbacks do app" no portal e a rota `GET /admin/feedback` (leitura dos feedbacks enviados pelo app).
- Mudancas: `AdminFunction` (codigo), `HttpApiIntegration`, `AutoImportRule` e `AutoImportPermission` (re-vinculo); sem IAM, sem recursos novos. Resultado: `UPDATE_COMPLETE`. O template no ar so diferia do repositorio por uma linha em branco no fim.
- Verificacao feita: a pagina publicada traz a aba (`aba-feedbacks`) e o `app.js` novo; `GET /admin/feedback` responde 401 sem login. **Nao** verificado: entrar com um operador e ver a lista carregar.

## Deploy do backend com denunciar, bloquear e conta excluida anonima no DEV - 24/11/2026

- **`bloqueio-015819`** (UPDATE, `runpass-dev-app`): autorizado pelo usuario ("publique o backend do DEV"), depois do merge do PR #156 (`eab700c`). Pacote `lambda/runpass-15d202eecf3c6604.zip`. Anterior: `lambda/runpass-fd3cae96eac70281.zip`.
- Como foi feito: `make lambda-package` de um worktree limpo do `dev`, upload ao bucket de artefatos, change set `cs-bloqueio-015819` com `--use-previous-template` e todos os parametros em `UsePreviousValue`, menos `ArtifactKey`. Mudancas: so codigo das Lambdas e re-vinculo (`ApiFunction`, `AuditConsumer`, `Maintenance`, `Publisher`, `ScoreConsumer`, `HttpApiIntegration`, `MaintenanceRule`, `MaintenanceSchedulePermission`); sem IAM, sem recursos novos, sem tabelas. Resultado: `UPDATE_COMPLETE`.
- Entrou: `POST /reports`, `PUT/DELETE /profiles/{id}/block`, `GET /me/blocks`; bloqueio nos dois sentidos (feed, busca, sugestoes, comentarios, avisos, perfil, curtir, seguir, amizade); registro de auditoria `DELETEDUSER#` ao excluir a conta; rotulo de distancia corrigido (10 -> "10K"). As rotas `GET /admin/reports` e `GET /admin/deleted-accounts` e as abas do portal **nao** foram publicadas: dependem do deploy da stack `runpass-dev-portal`.
- Verificacao feita (HTTP sem token): as quatro rotas novas e `POST /feedback` respondem 401; rota inexistente 404. Verificacao com conta real de teste (`[FICTICIA]`, cadastro real no Cognito, apagada no fim): denunciar pessoa 201; motivo invalido 422; seguir, bloquear, listar bloqueios; perfil e seguir de quem bloqueei respondem 404; feed sem o bloqueado; desbloquear volta ao normal; bloquear a si mesmo 422; `DELETE /me` 202 e a linha de auditoria (`TOMBSTONE`) gravada so com id, usuario, nome, data e operacao. Na rodada anterior (codigo antigo), a limpeza dos dados da conta excluida terminou em ~6 min.
- Observacoes: a 1a chamada de `GET /profiles/suggestions` de uma conta sem amigos levou ~5 s (varredura do indice de busca, depois guardada por 1 h). Uma denuncia de teste ficou na fila (texto `[FICTICIA]`). **Nao** verificado: telas do app (denunciar e bloquear no aparelho).
