# S07 — Eventos, RunScore e auditoria

Data: 01/11/2026. Estado: **em revisão local**. Dependência S06 disponível em revisão; transporte e armazenamento AWS permanecem S09.

## Implementação local

A conclusão cria EVENT e marcador de trabalho no mesmo commit. O marcador usa um dos 16 shards definidos no desenho e contém somente proprietário, eventId, estado e próxima tentativa. O transporte futuro precisa carregar apenas esses identificadores e `dispatchEpoch`; o payload continua na fonte durável.

`EventProcessor` entrega para dois destinos obrigatórios: `score` e `audit`. Cada destino possui DELIVERY próprio. Repetição retorna a confirmação existente sem reaplicar efeito. A última confirmação fixa `allConfirmedAt` e `payloadExpiresAt` uma única vez; replay não renova o prazo. Epoch antigo, evento ausente ou payload vencido falham fechados.

O consumidor de score não confia no snapshot da mensagem: lê ACCOUNT, PART e REVIEW atuais, compara a contribuição vigente e transaciona contribuição, soma e contagem. RunScore é calculado como `ratingSum / (8 * reviewCount)`, com apresentação decimal half-up em uma casa. Eventos duplicados ou fora de ordem reconciliam o estado atual sem contar duas vezes.

O consumidor de auditoria grava um artefato local determinístico separado, com notas e comentário, expiração 60 dias após a ocorrência original e colisão protegida. O evento operacional não contém comentário. Isso simula a fronteira e a retenção, mas não é evidência de S3, IAM, MFA ou descarte físico.

O reconciliador percorre os 16 shards, reencontra marcadores `pending`, tenta os destinos obrigatórios e marca o trabalho concluído apenas após ambos confirmarem. Falha permanece reencontrável.

Cada consumidor usa lease renovável de 60 segundos em `WORKER#consumer/FENCE`. Tomada após vencimento incrementa o fencing token; worker anterior é rejeitado mesmo que ainda possua uma mensagem. Falhas incrementam tentativas e definem `nextAttemptAt` com backoff exponencial limitado a cinco minutos, sem remover a pendência durável.

A limpeza ativa nega e remove EVENT/DELIVERY após sete dias da última confirmação. Quando existe artefato de auditoria, permanece apenas o localizador mínimo necessário à sua remoção no prazo original de 60 dias; depois lake e localizador são removidos. Se a auditoria ainda estiver pendente no vencimento, o score é reconciliado independentemente, o payload é descartado e fica somente registro mínimo de expiração/falha, sem DELIVERY de auditoria.

## Evidências e pendências

- Nove testes específicos aprovados: duplicação, soma inteira, separação de auditoria, prazo sem renovação, fora de ordem, epoch inválido, reconciliação parcial, lease/fencing, backoff e os dois caminhos de expiração.
- `make check` aprovado: Ruff/formatação, OpenAPI sem erros (55 paths/72 operações), 75 testes backend e cfn-lint.
- O teste de falha remove temporariamente a fonte de auditoria, comprova pendência reencontrável e impede nova tentativa antes do backoff.
- Pendente: SQS/DLQ/S3 reais, IAM/MFA, benchmark p95 de dez segundos, carga, alarmes e replay após restauração. Todos exigem integração DEV autorizada no S09.

Nenhum recurso AWS foi criado e nenhum score é aceito do cliente.


## Política de descarte aprovada — 03/11/2026

O usuário aprovou que, com a auditoria ainda pendente no vencimento, o payload seja descartado e permaneça só o registro mínimo de expiração ou falha. Aceite da S07 depende de decisão separada.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas em `implementation-slices.md` (seção "Aceite humano da S07"). Integração real permanece na S09.
