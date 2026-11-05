# Serviços criados e onde cada informação fica

Referência para a equipe (Thiago e Rafael). Cobre o que existe hoje no ambiente **DEV** (conta `263097734277`, região `sa-east-1`) e o que roda localmente. Data-base: 05/11/2026.

**Como ler a confiança dos fatos.** Tudo o que está em "template" vem dos arquivos de `infra/` que criaram os recursos. O que está marcado **(lido no DEV)** foi conferido por leitura na AWS em 04 e 05/11/2026 (formato das chaves, nomes e conteúdo dos buckets). Detalhes de modelagem (por que cada chave existe) estão em `PDLC/M4/MODELO-DYNAMODB-RunPass-v1.md`; o contrato das rotas está em `PDLC/M4/API-RunPass-v1.openapi.json`.

## 1. Visão geral

```
iPhone/Android ──HTTPS──> API HTTP (API Gateway) ──> Lambda "Api" ──> DynamoDB (5 tabelas + controle de exclusão)
      │                                                    │──> S3 "Medal" (fotos)
      │                                                    └──> SSM (2 chaves secretas)
      └──login──> Cognito (pool de corredores)

DynamoDB "Operations" ──stream──> Lambda "Publisher" ──> SQS Event ──> Lambda "ScoreConsumer" ──> DynamoDB "Projections"
                                                       └> SQS Audit ──> Lambda "AuditConsumer" ──> S3 "Audit" (JSON)
EventBridge (a cada 5 min) ──> Lambda "Maintenance" (eventos pendentes, exclusões, expirações)
CloudWatch: logs (7 dias), 4 alarmes ──> SNS "CriticalAlerts" (chave KMS própria) ──> 4 e-mails
```

Três stacks do CloudFormation, criadas nesta ordem: `runpass-dev-identity`, `runpass-dev-data`, `runpass-dev-app`. Os templates são `infra/identity.template.json`, `infra/data.template.yaml` e `infra/app.template.yaml`.

## 2. Inventário

### Fora do CloudFormation (criado à mão, registrado em `PDLC/M4/S09-integracao-dev.md`)
| Item | Para que serve | Como achar |
| --- | --- | --- |
| Bucket `runpass-dev-artifacts-263097734277` | Guarda o pacote da Lambda (`lambda/runpass-<hash>.zip`). Versionado, acesso público bloqueado, só TLS | `aws s3 ls s3://runpass-dev-artifacts-263097734277/lambda/` |
| SSM `/runpass/dev/erasure-hmac` (SecureString) | Chave do pseudônimo usado no controle de exclusão | `aws ssm describe-parameters` (nunca `--with-decryption` em conversa ou log) |
| SSM `/runpass/dev/cursor-key` (SecureString) | Chave que cifra os cursores de paginação | idem |
| Orçamento `runpass-dev-mensal` (AWS Budgets) | Alerta de custo: limite US$ 54,61/mês, avisos em 50% e 80% do gasto e 100% da previsão, para os 4 e-mails | Console → Billing → Budgets |
| Usuários IAM `runpass-dev-operator`, `runpass-dev-thiago` (e o do Rafael) e a política de operador | Acesso humano à conta, com MFA obrigatório | Console → IAM; política em `docs/operadores.md` |
| Papel OIDC de deploy (`infra/deploy-role.template.yaml`) | **Não aplicado**. Exige autorização explícita | — |

### Stack `runpass-dev-identity` (Cognito)
| Recurso | Função |
| --- | --- |
| `RunnerPool` + `RunnerClient` | Contas dos corredores. Login por e-mail, senha de 12+ caracteres com maiúscula, minúscula, número e símbolo, cadastro aberto com código por e-mail, **sem MFA**. Token de acesso 60 min, refresh 30 dias |
| `OperatorPool` + `OperatorClient` | Operadores do app (admin do catálogo). **Só o administrador cria usuário, MFA TOTP obrigatório**. Refresh de 1 dia |

IDs e client ids são saídas da stack: `aws cloudformation describe-stacks --stack-name runpass-dev-identity --query "Stacks[0].Outputs"`.

### Stack `runpass-dev-data`
| Recurso | Tipo | Resumo |
| --- | --- | --- |
| `IdentityTable` | DynamoDB | Contas, perfis, admissão ao beta, acesso de operador |
| `CatalogTable` | DynamoDB | Corridas (edições), versões e índices de busca |
| `HistoryTable` | DynamoDB | Participações, avaliações, medalhas |
| `OperationsTable` | DynamoDB | Comandos idempotentes, uploads, imagens, eventos, filas de trabalho, sessões de operador |
| `ProjectionsTable` | DynamoDB | Notas agregadas por edição (RunScore) |
| `ErasureControlTable` | DynamoDB | Controle de exclusão de conta, só com pseudônimo |
| `MedalBucket` | S3 | Fotos enviadas e validadas |
| `AuditBucket` | S3 | Eventos de auditoria em JSON |
| `EventQueue`, `AuditQueue` (+ DLQs) | SQS | Entrega dos eventos aos consumidores |
| `CriticalAlerts` + 4 assinaturas | SNS | Avisos críticos por e-mail |
| `AlertsKey` / `alias/runpass-dev-alerts` | KMS | Cifra o tópico de alertas |
| `EventDlqAlarm`, `AuditDlqAlarm` | CloudWatch | Disparam com qualquer mensagem na DLQ |

Os nomes finais têm sufixo gerado. O jeito confiável de achá-los é pelos **exports** da stack:
```sh
export AWS_PROFILE=runpass-dev-sa AWS_REGION=sa-east-1
aws cloudformation list-exports --query "Exports[?starts_with(Name,'runpass-dev-data')].[Name,Value]" --output text
```
Exports: `IdentityTable`, `CatalogTable`, `HistoryTable`, `OperationsTable`, `OperationsStreamArn`, `ProjectionsTable`, `ErasureControlTable`, `MedalBucket`, `AuditBucket`, `EventQueueUrl`, `EventQueueArn`, `AuditQueueUrl`, `AuditQueueArn`, `CriticalAlertsTopic`, todos com o prefixo `runpass-dev-data-`.

### Stack `runpass-dev-app`
| Recurso | Função |
| --- | --- |
| `HttpApi` + stage | API HTTP pública. Limite de 20 req/s com pico de 40. Autenticação (token do Cognito) é verificada **dentro** da Lambda |
| `ApiFunction` | `runpass.lambda_entry.api_handler`, Python 3.12, arm64, 1024 MB, 29 s. Atende todas as rotas |
| `Publisher` | Lê o stream da `OperationsTable` e publica nas filas SQS |
| `ScoreConsumer` | Lê a fila de eventos e atualiza a `ProjectionsTable` |
| `AuditConsumer` | Lê a fila de auditoria e grava JSON no `AuditBucket` |
| `Maintenance` | Roda a cada 5 minutos (EventBridge): reprocessa eventos pendentes, executa exclusões e expirações. 240 s |
| 5 grupos de logs | Um por função mais o log de acesso da API, **retenção de 7 dias** em DEV |
| `ApiServerErrorsAlarm`, `MaintenanceErrorsAlarm` | Alarmes de 5xx (mais de 5) e de erros da manutenção |

A URL da API é a saída `ApiUrl` da stack: `aws cloudformation describe-stacks --stack-name runpass-dev-app --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text`. Ela não é gravada no Git.

## 3. Onde cada informação fica

| Informação | Onde | Chave / local | Retenção | Sensível |
| --- | --- | --- | --- | --- |
| E-mail e senha do corredor | **Cognito** `RunnerPool` | usuário por e-mail; id estável = `sub` | até a exclusão da conta | **Sim** (a senha nunca é legível) |
| Nome de exibição e `@usuário` | `IdentityTable` | `USER#<sub>` / `PROFILE`; unicidade em `USERNAME#<normalizado>` / `CLAIM` | até a exclusão | Pessoal |
| Data de nascimento e declaração de maioridade | `IdentityTable` | `USER#<sub>` / `PRIVATE` | até a exclusão | **Sim**, acesso restrito; nunca entra em perfil nem índice |
| Estado da conta e admissão ao beta | `IdentityTable` | `USER#<sub>` / `ACCOUNT`, `ADMISSION`; contador em `BETA#v1` / `CONTROL` | conta; o contador sobrevive à exclusão | Não |
| Acesso de operador (permissões) | `IdentityTable` | `OPERATOR#<sub>` / `ACCESS` | até revogar | Controle de acesso |
| Sessão de operador (com MFA) | `OperationsTable` | `OPERATOR#<sub>` / `SESSION#<digest do token>` | expira em até 1 h (TTL `expiresAt`) | Controle de acesso |
| Corridas, distâncias, versões | `CatalogTable` | `EDITION#<id>` / `HEAD` e `V#<n>`; índices de busca em linhas `CAT#...` | histórico imutável por versão | Não (dados públicos de prova) |
| Participação (rascunho ou concluída): distância, tempo, colocação, número de peito, visibilidade | `HistoryTable` | `USER#<sub>` / `P#<id>#PART`; dono em `PARTICIPATION#<id>` / `OWNER` | até excluir a participação ou a conta | **Pessoal** |
| Uma participação por pessoa e edição | `HistoryTable` | `USER#<sub>` / `EDITION#<edição>#CLAIM` | junto da participação | Não |
| Avaliação (oito notas e comentário) | `HistoryTable` | `USER#<sub>` / `P#<id>#REVIEW` | até excluir | Pessoal |
| Medalha | `HistoryTable` | `USER#<sub>` / `P#<id>#MEDAL` | até excluir | Pessoal |
| **Foto enviada** (antes de concluir) | `MedalBucket` | `temporary/<sub>/<uploadId>` | **apagada após 2 dias** se não for usada | **Sim** |
| **Foto validada** | `MedalBucket` | `derived/<sub>/img_<sha256>` | mantida enquanto referenciada | **Sim** |
| Estado de cada envio de foto | `OperationsTable` | `USER#<sub>` / `UPLOAD#<id>` e `IMAGE#<id>` | com TTL | Não |
| Comandos repetidos (idempotência) | `OperationsTable` | `USER#<sub>` / `CMD#<operação>#<chave>` | com TTL | Não |
| Eventos de negócio, entregas, trabalhos de limpeza | `OperationsTable` | `USER#<sub>` / `EVENT#`, `DELIVERY#`, `JOB#`, `LAKE#`; filas `WORK#...` | com TTL | Sem dados pessoais no payload |
| Nota agregada por corrida (RunScore) | `ProjectionsTable` | `EDITION#<id>` / `SCORE#<g>`; contribuições em `USER#<sub>` / `CONTRIBUTION#<id>` | recalculável | Não |
| Pedido de exclusão de conta | `ErasureControlTable` | `ERASURE#<HMAC>` / `CONTROL` | **até 15 dias** (TTL), só pseudônimo e datas | Mínimo |
| Eventos de auditoria | `AuditBucket` | `dev/<AAAA-MM-DD>/<eventId>.json` | **60 dias** | Sem foto, nome ou e-mail |
| Logs de acesso da API | CloudWatch Logs | grupo `runpass-dev-app-HttpApiLogs-...` | 7 dias | Só método, status, latência e id da requisição |
| Logs das funções | CloudWatch Logs | grupos `runpass-dev-app-<Função>Logs-...` | 7 dias | O app registra pouco: **no DEV só aparecem as linhas START/END/REPORT**, sem rota nem erro |
| Segredos das chaves (HMAC e cursor) | SSM Parameter Store | `/runpass/dev/erasure-hmac`, `/runpass/dev/cursor-key` | até remover | **Sim**, nunca imprimir |
| Pacote da aplicação | Bucket de artefatos | `lambda/runpass-<hash>.zip` | versionado | Não |
| Custo e alertas | AWS Budgets, SNS | `runpass-dev-mensal`, `CriticalAlerts` | — | Os 4 e-mails ficam só no SNS e no Budgets, nunca no Git |

**Observações verificadas (lido no DEV).** A chave de partição `USER#<id>` usa o próprio `sub` do Cognito (conferido: o id nas tabelas é igual ao `sub` do usuário no pool). Os prefixos dos buckets, o padrão `dev/<data>/<id>.json` da auditoria e os tipos de linha acima foram conferidos por leitura.

**Persistência de outras coisas.**
- **Imagem da medalha na tela:** a foto fica no S3, mas a API **não tem rota para ler a imagem**, só devolve `medalImageReference`. Por isso o app mostra uma arte desenhada (ver seção 6).
- **No aparelho:** o app guarda só em memória a foto validada e a avaliação de um rascunho aberto. **Fechar o app apaga**. O token fica em memória e não é gravado.
- **Local (desenvolvimento):** o harness `runpass.local_api` e os testes usam `MemoryStore` em memória, nada persiste. Ver `docs/desenvolvimento.md`.

## 4. Fluxos que movem dados entre os serviços

1. **Escrita pela API.** A Lambda grava com transação no DynamoDB, sempre com versão esperada, para não sobrescrever em silêncio. Cada ação de negócio grava também uma linha de **evento** na `OperationsTable`.
2. **Do evento às filas.** O stream da `OperationsTable` aciona o `Publisher`, que publica **só uma referência** (sem payload) nas filas `EventQueue` (nota) e `AuditQueue` (auditoria). Mensagens recebidas 5 vezes sem sucesso (`maxReceiveCount: 5`) caem nas DLQs, que guardam por 24 h e disparam alarme e e-mail.
3. **Consumo.** O `ScoreConsumer` recalcula o RunScore em `ProjectionsTable`. O `AuditConsumer` grava o JSON no `AuditBucket`.
4. **Manutenção a cada 5 minutos.** Reprocessa eventos pendentes, executa os pedidos de exclusão de conta e apaga o que expirou.
5. **Foto.** O app pede um envio (`POST /uploads`), recebe uma **URL assinada do S3**, envia o arquivo **direto ao S3** (com `Content-Length`; sem isso o S3 recusa com 501), e chama `finalize`. A API valida (tipo, tamanho, pixels), reencoda sem metadados e grava em `derived/`.
6. **Exclusão de conta.** A API responde 202, esconde o conteúdo na hora e grava o controle com pseudônimo. A manutenção apaga dados de DynamoDB e S3 e remove o usuário do Cognito. Verificado em DEV com usuário sintético.

## 5. Como acessar cada informação

Pré-requisitos: `aws login --profile runpass-dev-sa` (usuário IAM com MFA) e região `sa-east-1`. O CLI **sem perfil** usa credenciais antigas e dá `InvalidClientTokenId`. A política atual dá `dynamodb:*`, `s3:*`, `sqs:*`, `logs:*`, `ssm:*`, `cognito-idp:*` e `cloudformation:*` em `sa-east-1`.

```sh
export AWS_PROFILE=runpass-dev-sa AWS_REGION=sa-east-1
exp() { aws cloudformation list-exports --query "Exports[?Name=='runpass-dev-data-$1'].Value" --output text; }
```

**DynamoDB.**
```sh
T=$(exp HistoryTable)
aws dynamodb scan --table-name $T --output json                       # tudo (DEV é pequeno)
aws dynamodb query --table-name $T --key-condition-expression "PK = :p" \
  --expression-attribute-values '{":p":{"S":"USER#<sub>"}}'          # tudo de uma pessoa
aws dynamodb get-item --table-name $(exp IdentityTable) \
  --key '{"PK":{"S":"USER#<sub>"},"SK":{"S":"PROFILE"}}'             # um item
```
No console: DynamoDB → Tabelas → escolha a tabela → **Explorar itens**. A saída vem no formato tipado (`{"S":"texto"}`).

**S3.**
```sh
aws s3 ls s3://$(exp MedalBucket) --recursive      # fotos: temporary/ e derived/
aws s3 ls s3://$(exp AuditBucket) --recursive      # auditoria: dev/<data>/<id>.json
aws s3 cp s3://$(exp AuditBucket)/dev/2026-11-04/<id>.json -   # ler um evento
```
**Fotos são dados pessoais**: baixar só quando necessário e apagar a cópia.

**Cognito (usuários).**
```sh
aws cognito-idp list-users --user-pool-id <RunnerPool> \
  --query 'Users[].[Username,Attributes[?Name==`sub`]|[0].Value,UserStatus]' --output text
```
O `sub` retornado é o `<sub>` das chaves `USER#<sub>`. IDs do pool vêm das saídas da stack de identidade.

**Filas, logs e alarmes.**
```sh
aws sqs list-queues
aws sqs get-queue-attributes --queue-url <url> --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text
aws logs filter-log-events --log-group-name <grupo> --start-time <epoch-ms>
aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]' --output text
```

**Pela API** (é o que o app enxerga). Precisa do token de acesso do usuário. Com o usuário real, o caminho é o próprio app. Para os usuários **sintéticos** de teste o fluxo é `admin-set-user-password` seguido de `initiate-auth` (como em `scripts/smoke_journey.py`, que lê o token só do ambiente):
```sh
API=$(aws cloudformation describe-stacks --stack-name runpass-dev-app --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" --output text)
curl -s "$API/me/participations?state=draft" -H "Authorization: Bearer $TOKEN"
```
Rotas implementadas no backend real: `/me` (PUT, GET, PATCH, DELETE), `/beta/status`, `/beta/admissions`, `/beta/waitlist`, `/me/waitlist`, `/editions`, `/editions/{id}`, `/participations` (POST), `/participations/{id}` (GET, PATCH, DELETE), `/participations/{id}/complete`, `/participations/{id}/review` (GET, PUT), `/me/participations`, `/deletion-operations/{id}`, `/uploads`, `/uploads/{id}/finalize`, `/uploads/{id}/status`. Toda requisição que muda dados exige o cabeçalho `Idempotency-Key`.

**Catálogo (escrita).** Só por operador com MFA: `scripts/operator_tool.py` (`enroll`, `grant`, `load-catalog`), ver `docs/operadores.md`.

**Segredos.** `aws ssm describe-parameters` lista nomes e versões sem mostrar valores. Não use `--with-decryption` em terminal compartilhado, em chat ou em log.

## 6. O que ainda não existe (para não procurar onde não há)

- **Feed, curtidas, comentários, seguir, wishlist, perfis públicos, busca de corredores, avisos e moderação:** o contrato lista algumas dessas rotas, mas o **backend real ainda não as implementa**; só a demo as simula. Não há tabelas para isso.
- **Leitura da foto:** não há rota para devolver a imagem da medalha ou da participação; falta URL assinada de leitura, só para o dono (item "imagem da medalha exibível" do S12).
- **Imagens oficiais de medalha por edição:** o importador as aceita, mas não há upload administrativo implementado.
- **Logs de aplicação:** as Lambdas não escrevem logs de negócio; diagnosticar um erro pelos logs hoje é difícil. Vale um slice de observabilidade.
- **Backups e restauração:** as 5 tabelas principais têm recuperação pontual (PITR) ligada no template e a `ErasureControlTable` não; **nenhum ensaio de restauração foi feito** (item pendente do S09).
- **PROD e HOM:** não existem. Este documento cobre só DEV.

## 7. Cuidados

- **Não edite itens à mão** nas tabelas: o servidor usa versão (`_rev`) e um registro por edição; mexer fora do código quebra a integridade (por exemplo `PARTICIPATION_INTEGRITY_FAILURE`). Para apagar, use o app ou a API.
- **As tabelas têm `DeletionPolicy: Retain`** (exceto `ErasureControlTable`): excluir a stack não apaga os dados. Ver "Desfazer" em `docs/deploy-dev.md`.
- **`scan` lê tudo**: em DEV é barato; em PROD não use.
- **Dados pessoais** (e-mail, nascimento, fotos, resultados) não vão para Git, chat nem capturas de tela compartilhadas.
- Alterou um serviço ou a forma de guardar um dado? Atualize este documento junto com `PDLC/M4/MODELO-DYNAMODB-RunPass-v1.md`.
