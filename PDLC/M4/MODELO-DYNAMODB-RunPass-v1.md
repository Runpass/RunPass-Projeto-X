# RunPass — Modelo físico da primeira entrega (S01)

Atualização: 28/10/2026. Estado: desenho da primeira entrega aceito após revisão S01 com o usuário em 28/10/2026, para implementar S02–S08. Sem tabelas criadas, benchmark ou estimativa final de custo. A direção DynamoDB/outbox/Cognito está aprovada; este documento detalha o fluxo inicial e substitui as propostas parciais anteriores deste arquivo. SPEC única: `SPEC_RunPass_MVP_v1.md`. Contratos e critérios: `S01-desenho-e-contratos.md`.

## Convenções e fronteiras

PK/SK são strings. IDs opacos gerados no servidor; nomes, e-mail e nascimento não compõem chaves. Timestamps UTC, datas de prova sem horário, versões inteiras monotônicas. Valores privados não entram em GSIs. Todas as tabelas são por conta/ambiente, on-demand, sem global tables. Nomes abaixo são lógicos; recursos e nomes finais pertencem ao CloudFormation. Histórico ativo sem TTL. Índices retornam referências: hidratação e autorização atuais são obrigatórias.

| Tabela | PK / SK e entidades fonte | Índices e finalidade |
| --- | --- | --- |
| IdentityAccess | `USER#u / ACCOUNT`, `PROFILE`, `ADMISSION`, `PRIVATE`; `USERNAME#normalizado / CLAIM`; `BETA#v1 / CONTROL`; `OPERATOR#sub / ACCESS` | Sem GSI necessário ao primeiro fluxo. ACCOUNT contém status/version; PRIVATE contém nascimento, acesso restrito; PROFILE nunca contém e-mail/nascimento. ADMISSION é fonte de adesão enquanto conta existir; contador preserva total admitido após exclusão. |
| RaceCatalog | `EDITION#e / HEAD`, `V#n`; `RACE#r / META`; linhas de consulta descritas abaixo | Índices explícitos na tabela base, sem GSI obrigatório. HEAD aponta geração ativa; V contém todas as distâncias e imagens oficiais correntes. Fonte não recebe score do cliente. |
| RunHistory | `USER#u / P#p#PART`, `P#p#REVIEW`, `P#p#MEDAL`; `USER#u / EDITION#e#CLAIM`; `PARTICIPATION#p / OWNER` | H1: `USER#u#STATE#draft|completed / date#p` no PART; H2: `EDITION#e / completedAt#p` e H3: `EDITION#e#DISTANCE#d / completedAt#p` no REVIEW. KEYS_ONLY + IDs de hidratação. |
| Operations | `USER#u / CMD#operation#keyDigest`, `UPLOAD#id`, `IMAGE#id`, `EVENT#id`, `DELIVERY#event#consumer`, `JOB#id`, `LAKE#event`; `WORKER#consumer / FENCE`; `OPERATOR#sub / SESSION#tokenDigest` | O1 trabalho: `WORK#type#state#shard / nextAttemptAt#id`; O2 vencimentos: `EXPIRY#type#day#shard / expiresAt#id`. Projeção mínima, sem payload. Shard = hash(id) mod 16. Query dos 16 shards, paginação e rechecagem forte na fonte. |
| Projections | `EDITION#e / SCORE#g`; `USER#u / CONTRIBUTION#p`; `EDITION#e / REBUILD#job` | C1 contribuição: `EDITION#e / p` para enumeração/reconciliação, KEYS_ONLY. SCORE soma de notas e contagem; CONTRIBUTION guarda versão aplicada e edição atual. |
| ErasureControl | `ERASURE#HMAC(environment,pool,sub) / CONTROL` | E1: `EXPIRY#day / expiresAt#digest`. Exceção aprovada: até 15 dias desde aceitação, somente pseudônimo e datas; chave HMAC separada. Sem payload, nome/e-mail, username ou fotos. Sem renovação por replay/cópia. |

Social não é modelado nesta entrega. Fronteira candidata da SPEC continua disponível para slices futuros. Publicar conquista é intenção persistida no PART/outbox; não criar endpoint de feed fingindo implementação. As cinco tabelas operacionais mais ErasureControl são decisão de engenharia para esta entrega, não fixação da topologia de todo o MVP.

PART mantém ID estável, dono, edição ou solicitação, distância, versão, estado, resultados e visibilidade. REVIEW tem `reviewVersion` para edição direta e `effectVersion` monotônica em qualquer alteração que afete score (incluindo distância, edição, moderação e exclusão). MEDAL guarda `imageId`, origem e referência imutável da imagem oficial ou própria. CLAIM contém p e versão; existe para rascunho já vinculado e concluída. Reserva única orienta editar/excluir registro existente, sem sobrescrita. Rascunho de solicitação ainda sem edição não reserva edição; resolução administrativa não conclui automaticamente.

## Catálogo: todas as combinações, sem Scan

Normalização de comparação: Unicode NFKD, remover marcas diacríticas, casefold e colapsar espaços; preservar original para exibição. Cidade é igualdade normalizada, estado UF maiúscula; cidade sem UF busca homônimos em todos os estados. Distância é Decimal do valor JSON canônico, não float arredondado; 10 e 10.0 são iguais. UF é facetada junto com cidade quando ambas fornecidas.

Para cada edição/versão materializar escopos: GLOBAL, UF, CITY, UF+CITY; cada escopo sem distância e para cada valor de distância distinto. Cada escopo tem dois conjuntos:

- PK `CAT#scope#distanceOrANY#DATE`; SK `date#editionId#version`.
- PK `CAT#scope#distanceOrANY#NAME`; SK `normalizedTitle#editionId#version`.

Com D distâncias distintas, 8(D+1) linhas, mais HEAD e V. Não impor limite de distâncias por conveniência da transação. Índices por versão são carregados em lotes idempotentes; verificar todas as linhas e só então ativar HEAD por CAS. Até isso a geração anterior permanece ativa. Mudança de catálogo não é transação gigante; índice novo incompleto nunca fica ativo. Remover linhas antigas por manifest da edição, sem Scan. Importação controla status, autoria, origem e auditoria; dados sintéticos não comprovam 90% de cobertura.

| Filtros presentes | Query | Predicados residuais |
| --- | --- | --- |
| Sem prefixo (com/sem qualquer city/state/distance/date) | Escopo exato DATE, BETWEEN datas quando presentes; sem data, intervalo completo | Nenhum filtro de produto descartado; validar versão ativa/status após hidratação |
| namePrefix, sem intervalo de datas | Escopo exato NAME, begins_with(prefixo normalizado) | Validar fonte e versão |
| namePrefix e alguma data | Escopo exato DATE e intervalo | startswith no título da fonte hidratada; leitura limitada com continuação |

Ordenação DATE crescente por data/ID/versão; NAME lexicográfica por título/ID/versão. Default limit 20, máximo 100. Avaliar no máximo 500 candidatos por resposta, sem pular candidatos já lidos não emitidos: Query Limit = min(vagas da página, saldo de candidatos), avançar pelo último candidato efetivamente processado. Página vazia pode trazer nextCursor. Hidratar com leitura forte; não retornar edição pendente ou geração não ativa. Não prometer snapshot durante alterações: modificações concorrentes podem mudar posição entre páginas; coleções estáveis não perdem/repetem elementos. Cursor opaco autenticado vincula ator, ambiente, rota, filtros normalizados, plano, última chave e limite; expira em 15 minutos, adulterado/expirado = 422. Sem dados privados ou credenciais dentro do cursor legível. Chave de cursor via configuração segura no slice de identidade.

DATE GLOBAL com poucos filtros percorre catálogo por índice intencionalmente, não usuários/reviews: justificativa é listar todo o catálogo. Prefixo + datas pode exigir muitas páginas; custo depende da seletividade. Medir distribuição, bytes e leituras antes de DEV; não afirmar baixo custo ou busca textual arbitrária. Limite de trabalho limita cada resposta, nunca o conjunto total acessível.

## Transações e consultas por rota

Leitura GetItem/BatchGet forte da fonte, TransactGet quando for necessária visão conjunta. GSI só fornece candidatos. Admissão e autorização nunca dependem de índice eventual. `API-RunPass-v1.openapi.json` contém a superfície futura inteira; a matriz abaixo é apenas a entrega inicial.

| Operação | Consulta / transação física |
| --- | --- |
| PUT /me (bootstrap novo) | Identidade Cognito validada e e-mail verificado; Put PROFILE e ACCOUNT se ausentes, Put CLAIM username se ausente, Put CMD. Não concede admissão. Conta ausente mas identidade em exclusão não pode ser recriada. |
| GET /me; PATCH /me | Get ACCOUNT/PROFILE; PATCH CAS PROFILE e ACCOUNT ativo, reserva username novo, libera claim antigo condicionado ao dono, CMD. Se username não mudou, não emitir duas ações sobre a mesma claim. |
| GET /beta/status | Get CONTROL, ACCOUNT e ADMISSION; identidade válida sem perfil recebe not_admitted. |
| POST /beta/admissions | Get CONTROL/PRIVATE; CAS count/version (<1000 e janela aberta), Put ADMISSION se ausente, Update ACCOUNT admitted, Put PRIVATE birthDate, CMD. Na transição 49→50 persistir startedAt e endsAt=startedAt+60 dias na mesma atualização CONTROL. count nunca decrementa. |
| POST /beta/waitlist; GET/DELETE /me/waitlist | Item `USER#u / WAITLIST`; criação somente voluntária quando cheio, com CAS CONTROL e conta; DELETE remove; não concede vaga. Prazo ordinário da espera continua bloqueio de lançamento próprio. |
| GET /editions; GET /editions/{id} | Query do plano acima ou Get HEAD/V; score via Get SCORE atual separado e somente leitura. |
| GET /editions/{id}/reviews | Query H2/H3; Get REVIEW/PART/ACCOUNT atuais, bloqueios bilaterais quando social existir; retirar inválida/oculta/deletada. |
| POST /participations | Put PART draft, OWNER, CLAIM se edição conhecida, CMD; ConditionCheck ACCOUNT admitted/ativo e HEAD versão/estado. Resolução de solicitação depende do slice próprio se habilitada. |
| GET /participations/{id}; /review | Get OWNER, depois TransactGet PART/REVIEW/MEDAL/ACCOUNT; dono vê rascunho, terceiro apenas concluída autorizada. Não revelar existência de rascunho alheio (404). |
| GET /me/participations | H1 por estado; sem state, duas Queries e merge por data/ID, com cursor de ambas; revalidar fonte. |
| GET /profiles/{id}; /participations; /medals | ACCOUNT/PROFILE ou H1 completed, hidratação PART/MEDAL e autorização. Nunca drafts, bib privado, nascimento, e-mail ou resultados ocultos. |
| POST /uploads | Put UPLOAD (dono/tipo/limites/issuedAt/expiresAt), CMD; condição ACCOUNT. URL temporária produzida após commit; retry só reemite URL com expiresAt original. |
| POST /uploads/{id}/finalize | HEAD S3 captura versão; CAS UPLOAD pending/unfinalized/dentro do prazo, fixa sourceVersionId, cria JOB e CMD; retry retorna estado atual, sem escolher nova versão. |
| GET /uploads/{id}/status | Get UPLOAD/IMAGE, dono atual e estado da conta; referência apenas valid. |
| POST /participations/{id}/complete | Ver T-complete abaixo. |
| PATCH /participations/{id} | CAS PART/version, revalidar HEAD/IMAGE; se troca edição, liberar CLAIM antiga e criar nova, atualizar REVIEW.effectVersion/edition/distance, MEDAL e evento de negócio; CMD. Alteração só de rascunho não cria review/medalha/evento de score. Sem transferência, conclusão anterior em edição agora arquivada continua editável; sem troca explícita de imagem, preservar a versão já vinculada, mesmo que catálogo tenha nova versão. |
| PUT /participations/{id}/review | CAS REVIEW.reviewVersion e effectVersion, ConditionCheck PART versão/estado ativo, ACCOUNT; grava duas outboxes (negócio/auditoria), CMD. Sem comentário no corpo = remoção do atual. |
| DELETE /participations/{id} | CAS PART deleted e versão, liberar CLAIM condicionada ao p, incrementar effectVersion em REVIEW/tombstone, criar evento + job + CMD. Remove post/interações quando módulo existir. |
| DELETE /me | CAS ACCOUNT deleting, criar job durável e ErasureControl na mesma transação, CMD mínimo/recibo. Nunca decrementar CONTROL. Ocultação imediatamente na fonte; limpeza por Query USER em todas as tabelas. |
| GET /deletion-operations/{id} | Job por dono ainda autorizado; conta excluída não volta a ter API normal. Acompanhamento posterior por suporte restrito, sem rota pública nova. |
| Carga de catálogo / rotas admin utilizadas | Geração manifest acima, papel catalog_admin + MFA comprovado, versionamento e auditoria. Arquivar = HEAD atualizado via CAS; não remover histórico. Organizador e upload oficial têm contrato próprio, necessários antes de ativar essas rotas. |

Busca de perfis, feed, solicitações/moderação completas e painel completo ficam fora desta matriz. Rotas futuras devem falhar como não implementadas enquanto não entregues, sem contornar autorização. Social existente no ambiente deve ser consultado; na primeira entrega ainda sem social não há relações a interpretar. Nunca habilitar parte social com verificações fictícias.

## T-complete: commit único

Até 12 itens distintos: ConditionCheck ACCOUNT ativo/admitido; ConditionCheck HEAD com versão observada, não arquivada e data <= hoje em America/Sao_Paulo; Update PART draft/expectedVersion→completed; Update CLAIM exigindo mesmo p; Put REVIEW; Put MEDAL; Update IMAGE com estado valid e versão/origem/destino corretos e incremento refs; Put CMD; Put EVENT negócio; Put EVENT auditoria; Put/Update marcador de enumeração se exigido pelo layout. OWNER já existe e não muda. Imagem oficial exige referência vigente para edição/distância lida; grava sua versão imutável. Mesmo item IMAGE não recebe ConditionCheck separado: condição faz parte do Update. Sem imagem, sem notas ou falha em qualquer condição, nada muda.

REVIEW, MEDAL e PART compartilham PK USER e prefixo p; não são bytes de foto. 100 ações/4 MiB por transação e 400 KiB por item são limites do serviço, não metas; validar tamanho antes de enviar. Comentário até 2.000 caracteres e evento com envelope máximo 64 KiB mantém margem inicial, a medir com UTF-8 e nomes de atributos. Eventos maiores falham integralmente com 422, nunca truncam. Modelo estimado não comprova RCU/WCU ou throughput.

Dois comandos para mesma edição: CLAIM condicional serializa; retry de mesma chave usa CMD. Conclusão versus arquivamento: HEAD CAS resolve vencedor; concluída anterior permanece editável. Leitura prévia não garante integridade sozinha. Conflitos retornam 409 com código estável; falha transitória 503 retentável sem novo ID. CMD escopo ator+operationId+chave, hash de método/caminho/corpo canônico; hash diferente=409. Guardar IDs/status/versão, nunca cópia de resposta privada. Leitura idempotente reaplica autorização atual; exclusão/ocultação supera repetição da resposta. Prazo de sete dias desde primeira aceitação, sem renovação; remoção expirada não remove invariantes/versões.

## Outbox, score e reconstrução

Outbox dentro da transação, mesmo ambiente; EVENT negócio contém IDs, effectVersion e snapshot mínimo de contribuição (edição/distância/notas/validade), sem comentário. EVENT auditoria é separado, ACL própria, antes/depois. PK USER permite enumeração por titular em ambos. Transporte leva somente eventId/destino/dispatchEpoch; worker busca outbox atual, verifica conta/exclusão/epoch. SQS standard com retenção de um dia (principal e DLQ), visibility inicial 60s, processamento por execução até 30s, sem depender de ordenação. DLQ após cinco recepções alerta; nunca apaga a pendência durável. Lease 60s renovável com fencing token; reconciliador de minuto em minuto e alerta de pendência >5 min são parâmetros iniciais, não SLA aprovado.

Cada destino possui DELIVERY no mesmo USER; confirmação transacional com efeito DynamoDB. Para S3, chave determinística + hash/verificação e depois confirmação condicional. Última confirmação obrigatória fixa allConfirmedAt uma única vez; replay permitido até +7 dias, não renova marco. Ledger por evento acompanha até esse vencimento; leituras negam expirados mesmo que TTL atrase. Após remover EVENT, qualquer mensagem atrasada não encontra payload e não aplica efeito. CONTRIBUTION vigente protege versões enquanto fonte existir, sem TTL ordinário; não confundir com ledger temporário. Pendência não tem TTL genérico e só some após resolução ou exclusão/expiração específica do conteúdo.

RunScore usa inteiros: ratingSum soma dos oito critérios de cada review válida; reviewCount conta reviews. Valor = ratingSum / (8*reviewCount), arredondamento decimal half-up só na apresentação, uma casa; zero reviews=null. Não acumular médias arredondadas. Worker lê CONTRIBUTION antiga e versão fonte atual, transaciona CAS contribuição, soma/count nos SCORE antigo/novo (uma única ação se mesma edição), DELIVERY e condições ACCOUNT/PART/REVIEW. Conta deleting ou PART deleted permitem somente retirar contribuição, nunca adicionar; tombstones duram até compensação e limpeza dentro do prazo pessoal. Fonte ausente implica retirada da contribuição antiga e nenhuma criação. Evento atrasado só dispara reconciliação do estado vigente. Troca de edição retira antiga e adiciona atual em um commit; exclusão/invalidação retira antiga. Contribution de excluído é removida com a compensação, sem ledger pessoal indefinido. Nenhum cliente define score.

Reconstrução: geração nova por edição, bloquear consumidores dessa edição por fence/lease e registrar pendências; enumerar H2 e contribuições C1, hidratar fontes válidas, processar alterações acumuladas até barreira; promoção CAS da geração só sem deltas não conciliados. API pode continuar registrar mudanças na outbox. Fence vence→retomar/recomeçar, nunca publicar geração parcial. Congelar promoção/consumo durante restauração; incremento de dispatchEpoch invalida mensagens de ambiente anterior. Custo e tempo da barreira exigem ensaio S07/S09, sem promessa de desempenho.

## Upload, referências e limpeza concorrente

Sessão de recebimento expira em 15 minutos desde emissão (mesmo marco da URL). Finalizar após prazo retorna 409 SESSION_EXPIRED salvo finalização já aceita. Validar HEAD tamanho e tipo declarado, depois formato real/decodificação <=25.000.000 pixels; JPEG/PNG até 10.000.000 bytes. Mobile reduz fotos maiores/converte HEIC antes do envio; preservar rascunho em falha. Esses limites são parâmetros de engenharia iniciais, com prova de compatibilidade exigida antes do beta.

Temporários em bucket privado versionado: finalize fixa VersionId observado e lê exatamente essa versão. PUT posterior na URL ainda válida cria outra versão, não muda fonte finalizada. Worker usa lease de dois minutos, até 15 minutos desde finalize para resolver processamento; excedido→failed/PROCESSING_TIMEOUT e nova sessão pelo usuário, sem aprovação por timeout. Job durável deve resolver a sessão antes de classificar temporário como abandonado.

Derivado sanitizado vai a chave nova privada, sem permissão de escrita mobile e com criação condicional; imagem lógica aponta somente ao derivado verificado, jamais ao original. Registro IMAGE tem dono/origem/versão/refs e estado valid|deleting. Limpeza só muda valid→deleting se refs=0 e idade elegível; vinculação exige valid e incrementa refs no mesmo commit do vínculo. Exclusão de vínculo decrementa com CAS. Assim limpeza versus conclusão tem um único vencedor. Recontar referências antes de apagar em caso de inconsistência, sem confiar somente em contador restaurado.

Remover todas as versões temporárias até 24h após expiração quando não ativas; IMAGE nunca vinculada após sete dias da validação segue limpeza em até 24h. Não dar TTL a imagens oficiais referenciadas. Derivado oficial já vinculado não acompanha troca do catálogo; origem pessoal não é promovida. Download autorizado usa referência opaca resolvida pelo backend e URL de cinco minutos (parâmetro inicial); não expor chave S3 ou original. Ocultação não revoga URL já emitida, nem card exportado.

## Exclusão e recuperação

Aprovado em 28/10: controle mínimo segregado por até 15 dias desde aceitação, exceção específica ao prazo ordinário de sete dias. HMAC é pseudônimo, não anonimização. Campos: digest (com versão da chave no prefixo), acceptedAt, expiresAt; sem IDs de job, conteúdo ou histórico detalhado. MFA/permissão recovery específica, IAM técnico mínimo; nunca consultável por corredor. Não copiar controle para auditoria de 90 dias. Expiração exige remoção ativa no marco; TTL é complementar e não cumpre sozinho máximo de retenção. ErasureControl não participa de PITR, snapshots ou exports nesta linha de base, para não alongar sua retenção; durabilidade da tabela ativa não equivale a backup. Se essa autoridade for perdida, restauração fica bloqueada até prova independente de exclusões atuais; nunca presumir ausência de exclusão. Material HMAC das versões ainda válidas e controles atuais precisam estar disponíveis na promoção; validar disponibilidade e exercício de falha antes de DEV.

Justificativa do horizonte: limpeza pessoal ativa até t0+7d; último snapshot que possa conter esses dados vence até t0+14d; margem de um dia para transporte/manutenção = t0+15d. Filas levam referências, retêm um dia e dependem de outbox viva. Proibir exports/snapshots manuais mais antigos e replay fora da janela. Restauração tem tráfego/consumidores fechados até revalidar controles atuais, excluir fontes/projeções/imagens do titular e reconciliar score. Conferir controle imediatamente antes da promoção; restauração que não conclui antes da segurança do horizonte é descartada e reiniciada a partir de base elegível. Falha no descarte de snapshot ou limpeza é incidente, não autorização para estender controle automaticamente.

Identidade Cognito e conta atuais prevalecem; tokens antigos não desbloqueiam deletada. Durante limpeza, tombstone ACCOUNT deleting impede recriação; após remoção, bootstrap exige usuário Cognito vigente habilitado e ausência no controle. Excluir usuário Cognito até sete dias; sub não é reutilizado. Job limpa por Query USER todas as tabelas e índices/objetos enumerados, incluindo outbox, CMD, snapshots intermediários e lake. Preservar catálogo oficial compartilhado. Excluir PART mantém bloqueio na fonte até projeções removidas; impossibilidade de localizar fonte implica negar exibição e não recriar por evento.

Histórico S3 expira 60 dias desde occurredAt; conta excluída antecipa. Payload de auditoria ainda pendente ao vencer não pode ser entregue, mas política de descarte físico/falha específica continua decisão pendente antes de S07. Não presumir aprovação dessa exceção junto aos 15 dias do controle. Demais retenções (espera/solicitações/feedback) não são decididas por este desenho.

## Provas a executar

S02–S08 devem demonstrar disputas username/admissão/CLAIM, CAS versões, finalize versus sobrescrita, limpeza versus vínculo, eventos duplicados/invertidos e exclusão versus replay; S09 verifica AWS real, índices atrasados, restore e carga. Checagem local de contrato e matriz não substitui esses testes. Orçamento precisa incluir linhas de catálogo por versão, hidratação, sexta tabela, versionamento temporário, jobs e controles antes de provisionar.


## Detalhamento implementado na S03

CAT usa facets `UF=SP`/`CITY=<cidade normalizada codificada>` e DATE/NAME; `V#n` contém fonte imutável e manifesto `indexKeys`. HEAD só ativa após verificação de lotes. Catálogo lê fonte e revalida versão, status e autorização corrente. Revisão permanente guarda referência, enquanto identidade do revisor fica na auditoria restrita com prazo próprio. Imagem oficial pré-validada é resolvida por `Operations / EDITION#id / IMAGE#reference`, com origem administrativa, ambiente/destino e refs protegidos no commit. Não há upload administrativo implementado por esse lookup. Retirada de índices antigos não apaga V nem imagens referenciadas. A edição arquivada pode registrar `archivedReason` (`cancelled`, `unavailable`, `duplicate`, `ended`) no manifesto `V#n`; o campo só vale com `archived` e é devolvido no detalhe e na lista, sem alterar chaves nem índices. Cursor é cifrado/autenticado e configurado por chave estável de ambiente. Evidências/limites em S03-catalogo.md; Query/concorrência AWS continuam a comprovar em DEV.
