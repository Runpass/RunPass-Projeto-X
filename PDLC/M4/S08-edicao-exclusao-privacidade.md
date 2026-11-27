# S08 — Edição, exclusão e privacidade

Data: 01/11/2026. Estado: **em revisão local**. S06 e S07 estão disponíveis em revisão local; integração e descarte em serviços AWS permanecem S09.

## Implementação local

`PUT /participations/{id}/review` substitui as oito notas com versão esperada. Comentário omitido é removido. A fonte, o evento operacional sem comentário, o marcador durável e a fonte restrita de auditoria antes/depois são gravados atomicamente. Review invalidada corrigida volta como `pending_review`; as demais permanecem válidas. O consumidor da S07 recompõe contribuição e RunScore pela fonte vigente.

Participações concluídas aceitam edição versionada. Alterações de visibilidade não disparam score. Troca de edição/distância revalida catálogo e unicidade, move a claim e cria evento para retirar a contribuição antiga e aplicar a atual. A imagem já fixada permanece vinculada quando não há troca explícita.

`DELETE /participations/{id}` oculta imediatamente a fonte, libera a claim e cria job durável. Conflito de versão não altera conteúdo. A referência da imagem é decrementada, sem apagar imagem oficial compartilhada. O evento de exclusão invalida a review e remove a contribuição; o lake registra antes e ausência posterior. `GET /deletion-operations/{id}` expõe somente o status do próprio titular enquanto a conta permanece disponível.

A exclusão de conta já bloqueava tokens imediatamente e preservava controle pseudonimizado por até 15 dias. Agora também grava marcador durável. `ErasureProcessor` executa em etapas retomáveis: primeiro compensa contribuições/score; depois enumera e remove partições pessoais de identidade, histórico, operações, projeções, OWNER reverso, claim de username, marcadores de eventos e bytes originais/derivados no adaptador de objetos; por fim remove job/marcador. O contador agregado do beta e o controle segregado aprovado não são apagados.

## Evidências e pendências

- Dezesseis testes focados S07/S08 aprovados: versão/conflito, comentário omitido, antes/depois, recomposição de score, transferência de edição, visibilidade, exclusão de participação e exclusão de conta em lotes pequenos.
- A primeira execução completa encontrou apenas a expectativa antiga de 19 operações no harness local; a API passou a expor 23 com as quatro rotas S08, e o teste foi atualizado.
- `make check` aprovado após a atualização: Ruff/formatação, OpenAPI sem erros (55 paths/72 operações), 83 testes backend e cfn-lint. O novo teste confirma que exclusão de conta remove bytes originais/versionados e derivados no adaptador local.
- Pendente: lifecycle e enumeração real de índices, filas e S3 em DEV.
- Mobile local concluído: tela final permite alterar visibilidade, substituir a avaliação e solicitar exclusão da participação com confirmação; conta autenticada pode solicitar exclusão com confirmação e a sessão é encerrada. O visual foi alinhado ao mockup promocional RunPass (marca, laranja/azul-marinho, cartões e navegação inferior) e a demonstração foi instalada no iPhone virtual.
- `make mobile-check` aprovado: análise, formatação e 17 testes Flutter. Os testes cobrem edição de avaliação, exclusão da participação e confirmação de exclusão de conta com encerramento da sessão; a validação com serviços AWS permanece pendente.
- Pendente: ensaio de falha/restauração, prazo real de sete dias, IAM/MFA e prova do descarte do controle de 15 dias em S09.

Nenhum recurso AWS foi criado e nenhum dado real foi utilizado.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas registradas em `implementation-slices.md` (seção "Aceite humano de S05, S06 e S08"). Integração real permanece na S09.
