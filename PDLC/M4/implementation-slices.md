# RunPass — Slices de implementação da primeira entrega

Data: 29/10/2026. Fonte única: SPEC_RunPass_MVP_v1.md. Escopo aprovado: autenticação → catálogo → rascunho → imagem → conclusão → avaliação e medalha.

Estado do plano: S00 preparada/verificada e sequência S01 autorizada pelo usuário. S01 aceita pelo usuário após revisão dos três blocos conforme S01-desenho-e-contratos.md; S02, S03 e S04 aceitas pelo usuário em 03/11/2026 (aceite local, prova real na S09). S02 a S08 foram aceitas em 03/11/2026 (aceite local) e S09 está em preparação local sem provisionamento. Cada slice possui dependências e saída verificável. Propostas técnicas são resolvidas dentro dos slices de desenho; não exigem reaprovação de nomes de atributos. Escolhas que alterem produto, custo ou privacidade voltam ao usuário.

## Regras de execução

- Antes de codificar, concluir a preparação de contexto/regras e harness prevista em M4.1/M4.2, limitada à entrega.
- Trabalho local de desenho e testes pode começar sem criar recursos AWS. Provisionamento pago exige orçamento aplicável e autorização ainda pendentes.
- Usar API-RunPass-v1.openapi.json e MODELO-DYNAMODB-RunPass-v1.md, atualizando-os com a SPEC quando o desenho for fechado.
- Evidência de aceite: revisão da mudança, resultados dos testes pertinentes e limitações registradas. Não confundir teste local com integração real na AWS.
- Cada entrega deve respeitar exclusão/bloqueios e autorização; não publicar conteúdo sob justificativa de ser um slice inicial.

## Sequência e estado inicial

| ID | Resultado | Dependências | Estado |
| --- | --- | --- | --- |
| S00 | Contexto, estrutura e verificações locais | SPEC prioritária aprovada | Verificada; usuário autorizou sequência S01 |
| S01 | Desenho físico do fluxo inicial e contratos fechados | S00 | Aceito pelo usuário em 28/10/2026 — revisão dos três blocos |
| S02 | Identidade, admissão e autorização | S01 | Aceito em 03/11/2026 — aceite local; Cognito, e-mail, MFA e concorrência real em S09. Evidências em S02-identidade-admissao.md |
| S03 | Catálogo consultável e carga controlada | S01, S02 | Aceito em 03/11/2026 — aceite local; catálogo real e cobertura de 90% pendentes para o beta. S03-catalogo.md |
| S04 | Participação em rascunho | S03 | Aceito em 03/11/2026 — aceite local; DynamoDB real e persistência entre processos em S09. S04-rascunho-participacao.md |
| S05 | Upload e imagem validada | S02, S04 | Aceito em 03/11/2026 — aceite local; HEIC no iPhone real, S3 real e p95 de 5 s em S09 |
| S06 | Conclusão atômica, avaliação e medalha | S04, S05 | Aceito em 03/11/2026 — aceite local; teste humano no simulador em 29/10; integração real em S09 |
| S07 | Entrega de eventos, RunScore e histórico restrito | S06 | Aceito em 03/11/2026 — aceite local; SQS/DLQ/S3, IAM/MFA, p95 de 10 s, carga, alarmes e replay após restauração em S09 |
| S08 | Edição, exclusão e proteção de dados | S06, S07 | Aceito em 03/11/2026 — aceite local; restauração, prazo real de 7 dias, IAM/MFA e descarte do controle de 15 dias em S09 |
| S09 | Integração real em DEV e aceite da entrega | S02–S08, orçamento/autorização | Preparação local; teto DEV de R$ 1.000/mês aprovado, provisionamento ainda bloqueado pelos demais gates |

Não é uma decomposição de todo o MVP. Feed completo, interações sociais, wishlist, painel completo e pós-beta terão slices próprios depois; não foram removidos do escopo do produto.

## S00 — Preparação do contexto e execução local

Resultado: estrutura de backend/mobile/infra documentada, instruções AGENTS/RULES pertinentes e comandos reproduzíveis para validação, teste e análise estática.

Trabalho: inspecionar código existente antes de criar estrutura; fixar versões e dependências; configurar ambiente Python, projeto Flutter quando disponível e validação OpenAPI; definir dados sintéticos e isolamento de testes. Não criar segredos nem configurar credenciais permanentes.

Aceite: outra pessoa consegue executar as verificações locais documentadas; ausência de Flutter/Dart ou demais ferramentas fica explicitamente registrada. Checagens de contrato executáveis e teste mínimo relevante da lógica existente, sem testes artificiais que apenas copiem configuração. Não iniciar implementação sem contexto e comandos de verificação definidos.

## S01 — Modelo e contratos da entrega

Resultado: proposta física revisada para identidade/admissão, catálogo, participação/review/medalha, upload e operações/eventos envolvidos. Não é necessário modelar todo o feed para fechar este slice.

Trabalho: enumerar cada consulta/escrita, PK/SK, índices, projeções, unicidade, versões, recuperação e enumeração por titular. Escolher tabelas a partir dos requisitos; a proposta histórica de seis tabelas não é obrigação. Detalhar outbox transacional, contribuição versionada de RunScore, ledger, marco de replay e controle de exclusões. Definir quais dados são fonte e quais são projeção.

Fechar antes dos slices dependentes: normalização/uniquidade de username, filtros de catálogo suportados, limite de comentário/páginas/pixels, critérios de sessão de upload e proteção de chave após validação. Propor parâmetros técnicos e revisar impacto; não reduzir filtros do contrato silenciosamente. Definir provas de concorrência/ordem e política de retenção dos controles compatível com replay/restauração sem ampliar retenção pessoal por conveniência.

Aceite: matriz rota → consulta/transação → chave/índice; nenhum acesso crítico depende de scan global não justificado; transações enumeradas com condições e cenários de falha; contrato OpenAPI válido e coerente. Pendência que afete comportamento do slice seguinte impede marcá-lo como pronto. Não declarar eficiência ou custo medidos por desenho apenas.

## S02 — Identidade, elegibilidade e autorização

Resultado: aplicativo identifica o corredor e controla acesso conforme conta/admissão. Configuração declarativa de identidade separa corredores e operadores; integração real é verificada em S09.

Trabalho: abstrair identidade validada, autenticação e recuperação via Cognito; verificar issuer/audience/expiração e estado atual na API. Implementar admissão transacional, e-mail confirmado, data de nascimento privada, 18 anos completos, teto de mil e marco do 50º. Fluxos de status/espera/exclusão não exigem vaga prévia; demais rotas exigem admissão quando previsto. Separar MFA administrativo por autenticador e autorização por função, sem criar painel completo.

Aceite: tokens inválidos ou destinados a outro cliente negados; usuário não admitido não acessa catálogo protegido; concorrência não ultrapassa mil nem perde o marco inicial; nascimento não aparece em resposta pública/log; conta bloqueada não opera com token anterior. Documentar/bootstrap e recuperação de operadores antes de ativar administração. Testes locais de regras não substituem prova real de MFA em S09.

## S03 — Catálogo inicial consultável

Resultado: listar e detalhar edições/distâncias; estados e referências de imagens oficiais disponíveis para seleção no app.

Trabalho: consultas paginadas pelos filtros efetivamente definidos em S01; carga idempotente de catálogo sintético e importação controlada pela equipe. Não depender de painel completo para integração local. Upload administrativo só é exigido aqui se utilizado como caminho de carga; nesse caso cumprir autorização/MFA e contrato próprio.

Aceite: edição/distâncias corretas, filtros combinados previsíveis e cursor sem vazamento entre filtros; edição arquivada não aceita nova conclusão; dados de score não podem ser definidos pelo cliente. Catálogo real tem origem e revisão registradas; fixture não comprova cobertura das principais provas.

## S04 — Rascunho de participação

Resultado: corredor cria, consulta e altera rascunho de sua participação, sem publicar nem ativar conquistas.

Trabalho: persistir edição/distância e campos parciais, versões e autorização; integrar seleção de catálogo no aplicativo. Preservar rascunho em falhas e conflito; não ativar automaticamente solicitação de edição ausente. Solicitação completa é entrega posterior se não utilizada no primeiro fluxo.

Aceite: dados de outro usuário inacessíveis; edição/distância incompatível rejeitada; alteração concorrente não sobrescreve silenciosamente; rascunho não gera medalha pública, RunScore ou ativação. Repetir criação com a mesma chave respeita contrato idempotente.

## S05 — Upload e processamento da foto

Resultado: imagem própria passa de pendente para válida ou falha antes de poder concluir participação.

Trabalho: sessão privada, URL de upload de 15 minutos, finalização e consulta de estado; verificar dono/objeto real, JPEG/PNG até 10 MB, decodificação, GPS/orientação e otimização com meta de 1 MB. Integrar conversão HEIC no mobile conforme solução validada; original não tratado não é exposto. Limite de pixels e processamento definidos em S01.

Aceite: upload alheio, adulterado, expirado ou inválido não conclui corrida; timeout não aprova imagem; falha preserva rascunho; referência validada é protegida de sobrescrita pela URL ainda válida. Testes de metadados, orientação, tamanhos, retry e compatibilidade; meta de cinco segundos medida em S09, não presumida por mock.

Arquivos abandonados e imagens validadas nunca vinculadas seguem prazos aprovados, com rechecagem de vínculos. Não apagar imagem oficial compartilhada para limpar foto pessoal.

## S06 — Conclusão, avaliação e medalha

Resultado: fluxo vertical no aplicativo conclui a corrida e exibe participação, avaliação e medalha persistidas.

Trabalho: validar autodeclaração, edição/distância, oito notas e imagem oficial ou própria válida; transação grava itens relacionados, conversão do rascunho, idempotência e outbox. Guardar referência/versionamento da imagem oficial. Publicação respeita escolha de visibilidade e ocultação de resultado/pace.

Aceite: duas conclusões concorrentes geram apenas uma participação por usuário/edição; falha não deixa medalha ou review órfãos nem evento perdido; retry após resposta perdida não duplica efeitos. Sem nota obrigatória/imagem válida não conclui; uma edição distinta permite nova participação. Nova imagem oficial não muda medalha já registrada. Conferir jornada completa app → API → armazenamento local de teste.

## S07 — Consumidores, RunScore e auditoria de avaliação

Resultado: evento durável entrega efeitos derivados com recuperação; score usa contribuição vigente e histórico restrito recebe antes/depois necessário.

Trabalho: publicador/reconciliador, consumidores por finalidade, confirmação por destino, retentativas/falhas e replay controlado de até sete dias. Atualizar contribuição/score atomicamente quando possível; separar comentário histórico de consumidores operacionais. Ingestão S3 privada do histórico com expiração por ocorrência, acesso específico/MFA e auditoria. Meta de dez segundos para RunScore.

Aceite: duplicação, fora de ordem e falha entre escrita e confirmação não alteram score duas vezes; pendência reencontrável sem depender de uma única cópia de transporte; replay não renova prazos nem ressuscita dados excluídos. Payload concluído retido por sete dias desde última confirmação obrigatória; ledger segue desenho fechado em S01. Histórico vencido/excluído não é consultável. Política de payload de auditoria pendente após expiração deve estar resolvida antes de liberar esse caminho.

## S08 — Edição, exclusão e privacidade da entrega

Resultado: o usuário corrige/exclui seu cadastro e pode encerrar conta sem conteúdo permanecer acessível por índices atrasados.

Trabalho: alteração versionada de participação, PUT completo de review, exclusão própria, retirada/recomposição de score, ocultação de resultados e limpeza por titular. Omitir comentário no PUT remove o atual e grava histórico restrito. Troca de edição revalida unicidade e ajusta contribuições. Exclusão de conta bloqueia imediatamente e agenda limpeza por destino em até sete dias; proteger restore/replay com controle mínimo aprovado.

Aceite: conflito/duplicidade não sobrescreve outro cadastro; notas inválidas não substituem a review; exclusão não remove catálogo/imagens oficiais compartilhadas; projeções antigas não expõem conteúdo; tokens anteriores não dão acesso. Enumeração cobre atributos privados, fotos, filas e lake; execução parcial é retentada sem marcar conclusão prematura. Ensaio de restauração real ocorre em S09.

## S09 — Integração DEV, evidências e aceite da primeira entrega

Resultado: fluxo inicial demonstrado em DEV isolado, com relatório de limites e evidências dos serviços reais.

Pré-condições: orçamento aplicável completo e autorizado; acesso/configuração de conta DEV; responsáveis e recursos necessários definidos. Preparar CloudFormation e CI localmente antes disso é permitido; aplicar não é autorizado por este plano.

Trabalho: implantação por CloudFormation/GitHub Actions OIDC; integração real API Gateway/Cognito/Lambda/DynamoDB/S3/filas e monitoramento; testes Android/iPhone; carga no perfil aprovado; restore com RPO/RTO e reaplicação de exclusões; jobs de retenção, falhas/replay e permissões negativas. Promover mesmos artefatos somente após aprovação específica de PROD.

Aceite: relatório demonstra o fluxo, lista as evidências e compara com critérios acordados; registra limites, riscos e falhas sem declarar sucesso por ausência de medição. Testes de integração não acessam PROD. Aceite desta entrega não libera beta completo: feed/social, demais jornadas, políticas e requisitos de lançamento permanecem necessários.

## Fora desta primeira entrega

Feed completo, follow/block/comentários/likes, wishlist e avisos completos, painel administrativo integral, fila de solicitações/moderação completa e operação pós-beta. As regras desses módulos continuam aprovadas quando já definidas; não são implementadas implicitamente. Autorizações e privacidade relevantes ao fluxo inicial não podem ser adiadas com esses módulos.

## Acompanhamento

Atualizar estado por evidência: planejado → pronto (dependências resolvidas) → em execução → em revisão → aceito. Registrar por slice referência da mudança, verificações, resultados, decisão do revisor e pendências. A S00 possui scaffold e verificações locais, conforme seu relatório. Não há infraestrutura provisionada, tickets externos publicados ou commit/push por esta execução.

## Evidência S01 — 28/10/2026

Desenho em MODELO-DYNAMODB-RunPass-v1.md; contrato 0.8.0-draft e revisão em S01-desenho-e-contratos.md. Controle mínimo de exclusão por até 15 dias aprovado explicitamente pelo usuário. Nenhuma aprovação de infraestrutura/custo/release decorre da S01. Pendência de descarte do payload de auditoria ao vencer deve ser resolvida antes do caminho afetado em S07.


## Evidência S02 — 28/10/2026

Backend e mobile implementados localmente para identidade/perfil/admissão/espera, com adaptadores explícitos, JWT, controle de operadores e template Cognito não aplicado. Relatório: S02-identidade-admissao.md. Não confundir testes locais/stubs com AWS real; limpeza física/S08, operação e integração/S09 continuam pendentes. Sem aceite humano ou autorização de provisionamento.


## Evidência S03 — 28/10/2026

Catálogo implementado localmente com autorização de admissão, filtros/paginação, versão ativa, carga idempotente/retomável, auditoria restrita e interface de busca/detalhe/seleção. Seed em memória e demonstração debug sem AWS preparados. Relatório S03-catalogo.md distingue testes locais e execução do simulador. Não comprova catálogo real, imagens processadas, AWS ou conclusão de participação. S04 continua próximo slice; sem aceite humano inferido ou autorização de infraestrutura.

## Evidência S04 — 28/10/2026

Rascunho privado implementado localmente com reserva única por usuário/edição, idempotência, versão esperada, autorização do titular, revalidação de catálogo, listagem paginada e integração da seleção no Flutter. Relatório: S04-rascunho-participacao.md. Não cria review, medalha, score, evento ou publicação; solicitação de prova ausente continua fora deste caminho. Sem AWS, deploy, commit, push ou aceite humano inferido. Próximo slice: S05.

Revalidação em 29/10/2026: 28 testes focados de participação/catálogo e a suíte completa de 63 testes backend passaram. Os 13 testes Flutter, análise estática e formatação também passaram. O estado permanece em revisão até aceite humano; execução local não comprova DynamoDB/Cognito reais.

## Evidência S05 — 29/10/2026

Backend local em execução com sessão privada de 15 minutos, finalização idempotente, versão do objeto fixada, autorização antes da consulta ao blob, estados pending/valid/failed, prazo de processamento e referência derivada imutável. Validação real decodifica JPEG/PNG, confere formato/tamanho declarado, limita 25 megapixels, corrige orientação, remove metadados e otimiza com meta de 1 MB. Seis testes específicos passaram, incluindo sobrescrita posterior, titularidade, expiração, timeout, bytes inválidos e limite de pixels. O Flutter seleciona/reduz a foto, verifica assinatura/tamanho, envia bytes pela URL assinada e finaliza depois; a suíte passou com 14 testes e análise limpa. Relatório: S05-upload-imagem.md. Conversão HEIC em iPhone real, adaptador S3 e medição de cinco segundos continuam pendentes; não há autorização de AWS.

## Evidência S06 — 29/10/2026

Conclusão local em revisão com uma única transação otimista para participação, claim, review, medalha, referência da imagem, evento durável e comando idempotente. O backend exige autodeclaração, oito notas, versão do rascunho, edição passada/não arquivada e imagem própria ou oficial válida; retry não duplica efeitos e concorrência tem um vencedor. O teste mobile vertical percorre upload sintético, imagem válida, oito notas, declaração e conclusão. Resultado: 66 testes backend e 15 Flutter, com análise estática limpa. Relatório: S06-conclusao-avaliacao-medalha.md. Integração real continua S09; sem AWS ou publicação de feed.

Teste humano no simulador em 29/10/2026 confirmou preenchimento, imagem validada e mensagem de participação/medalha/avaliação registradas. A captura revelou controles de rascunho ainda visíveis após concluir; foi criado teste de regressão, reproduzida a falha e corrigida a renderização para uma tela final exclusiva. O teste passou e a correção foi reinstalada no simulador.

## Evidência S07 — 01/11/2026

Consumidores locais em execução para `score` e `audit`, com DELIVERY idempotente por evento/destino, contribuição vigente, soma inteira das oito notas, reconciliação da fonte atual para eventos fora de ordem, `dispatchEpoch`, confirmação final e prazo de replay sem renovação. Pendências possuem marcador durável em 16 shards e são reencontradas pelo reconciliador. Auditoria local separa comentário do evento operacional e fixa expiração de 60 dias desde a ocorrência. Cinco testes específicos passaram; relatório: S07-eventos-runscore-auditoria.md. SQS/S3, lease/fencing, carga, latência e descarte físico continuam pendentes para integração autorizada.

## Evidência S08 — 01/11/2026

Edição versionada, substituição de avaliação, exclusão de participação e de conta implementadas localmente, com limpeza retomável e telas Flutter. Relatório: S08-edicao-exclusao-privacidade.md.

## Evidência de correções e preparação S09 — 02/11/2026

Correções com teste de regressão visto falhando antes:

- **S05:** PNG de 23 KB com 196 megapixels derrubava a validação com exceção não tratada; limite agora é checado antes de decodificar e a imagem falha fechada. Comentário JPEG sobrevivia à remoção de metadados. JPEG MPO, comum em celulares, era recusado.
- **S07:** reconciliador e expiração liam só a primeira página de cada shard; marcadores concluídos podiam esconder pendências.
- **S08:** a exclusão de conta também lia só uma página e podia concluir deixando marcador com o identificador do titular. Faltava remover o usuário do Cognito e descobrir jobs aceitos (`run_pending`).

Novos: adaptadores S3 de fotos e auditoria e remoção no Cognito (`aws_adapters.py`), handlers Lambda (`lambda_entry.py`), `infra/app.template.yaml`, Streams e políticas TLS em `infra/data.template.yaml`, `make lambda-package` e CI. Com adaptador de auditoria, o comentário fica só no objeto S3 e a linha em Operations é um localizador.

Resultado: `make check` aprovado em Python 3.11 e 3.12, com 134 testes backend (eram 83), contrato e cfn-lint dos três templates. Os testes de eventos e exclusão também rodam por um cliente DynamoDB falso que serializa como o serviço. Stubber e cliente falso não comprovam AWS. Mobile não foi alterado nem reverificado. Sem provisionamento, deploy, commit, push ou aceite humano. Pendências: S09-integracao-dev.md.

## Região AWS — 02/11/2026

Uma migração para `us-east-2` foi feita e desfeita no mesmo dia: a conta de projeto `<ID da conta de projeto>` só opera em `us-east-2` e foi substituída pela conta padrão `<ID da conta DEV>`, em `sa-east-1` (SPEC, seção "Região AWS"). O que ficou: `JwksProvider` recebe a região configurada e só aceita o issuer Cognito dela, com teste de rejeição para outras regiões, e `AwsSettings` tem `region`, lida de `AWS_REGION` na Lambda. Provisionamento continua não autorizado.

## Reverificação do mobile — 03/11/2026

`make mobile-check` aprovado: análise estática sem problemas, formatação sem alterações (9 arquivos) e 18 testes Flutter aprovados (demo local, catálogo, rascunho, foto com oito avaliações, edição e exclusão de participação). É teste local com adaptadores; não substitui Android/iPhone reais nem integração com serviços AWS. Nenhum código foi alterado.

## Aceite humano de S02, S03 e S04 — 03/11/2026

Decisão do usuário em rodada de perguntas, com suíte local verde no dia (`make check`: 135 testes backend, contrato e cfn-lint; `make mobile-check`: 19 testes Flutter).

- **S02 aceita.** Ressalvas: Cognito, envio de e-mail, MFA e concorrência real no DynamoDB só serão provados na S09. Sem sessão persistente nem refresh automático nesta entrega (aceito; persistência segura em slice posterior). Bootstrap e recuperação de operadores estão documentados em `docs/operadores.md`.
- **S03 aceita.** Os seis filtros e a paginação por cursor ficam como propostos. Ressalva: a fixture de cinco edições fictícias não comprova cobertura; catálogo real (capital, dois anos iniciais, origem e revisão registradas) e cobertura de 90% são pendência do beta. Responsável pelo levantamento: Thiago.
- **S04 aceita.** Ressalvas: DynamoDB real e persistência entre processos na S09; solicitação de edição ausente segue desabilitada até o slice administrativo.
- **Pendência de política antes do beta:** prazo de retenção da lista de espera, dos rascunhos e das solicitações de catálogo (não herdam os 60 dias do beta). Decisão do usuário.

Aceite local não é aceite de integração real. Nada disso autoriza provisionamento, PROD ou beta.

## Aceite humano de S05, S06 e S08, e política de auditoria da S07 — 03/11/2026

Decisão do usuário em rodada de perguntas.

- **S05 aceita.** Ressalvas para a S09: conversão HEIC no iPhone real, adaptador S3 real (existe no código, não provado) e medição de p95 em cinco segundos.
- **S06 aceita.** Ressalva: integração real na S09. O teste humano no simulador de 29/10 confirmou o fluxo e levou à correção da tela final.
- **S08 aceita.** Ressalvas para a S09: ensaio de restauração, prazo real de sete dias, IAM/MFA e prova do descarte do controle de 15 dias.
- **Política de descarte da auditoria vencida (S07) aprovada.** Se a auditoria ainda estiver pendente no vencimento, o score é reconciliado de forma independente, o payload é descartado e fica somente o registro mínimo de expiração ou falha, sem nova tentativa. Resolve a pendência que a S07 carregava.

Aceite local não é aceite de integração real. Nada disso autoriza provisionamento, PROD ou beta.

## Aceite humano da S07 — 03/11/2026

Aceita pelo usuário como aceite local. Ressalvas para a S09: SQS, DLQ e S3 reais, IAM/MFA, p95 de dez segundos do RunScore, carga, alarmes e replay após restauração. Com isso, S02 a S08 estão aceitas localmente; falta a integração real (S09), que continua bloqueada pelo gate de entrada.
