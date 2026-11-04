# S06 — Conclusão, avaliação e medalha

Data: 29/10/2026. Estado: **implementação local em revisão**. S04 está revalidado e o caminho local do S05 fornece referências de imagem válidas; pendências físicas/AWS desses slices permanecem explícitas.

## Backend implementado

`POST /participations/{id}/complete` exige rascunho do titular, versão esperada, autodeclaração verdadeira, oito notas entre 1 e 5, intenção explícita de publicação e referência opaca de imagem. A edição e a versão do catálogo são revalidadas dentro da transação; prova futura, arquivada ou alterada não conclui.

A imagem pode ser própria do titular ou oficial da edição/distância. O estado `valid`, origem e titular/versão são conferidos no mesmo commit. A referência recebe incremento e a medalha fixa origem, referência e versão do catálogo, portanto uma alteração oficial posterior não reescreve a medalha existente.

Uma única transação converte PART para `completed`, incrementa sua versão, atualiza CLAIM e grava REVIEW, MEDAL e EVENT durável. O evento contém somente IDs, versão do efeito, edição/distância e notas; comentário não entra no evento de negócio. O comando idempotente faz retry retornar a participação já concluída sem novo evento ou incremento de referência.

## Aplicativo

Após validar a foto, a tela do rascunho exibe as oito notas, comentário opcional de até 2.000 caracteres, declaração de conclusão e intenção de publicação. O cliente envia a versão corrente e a referência validada. O transporte de demonstração implementa o mesmo encadeamento sintético; nenhuma publicação de feed acontece no S06.

## Evidências e limites

- Dez testes focados de participação passaram antes da ampliação HTTP: atomicidade, retry, concorrência com um vencedor, imagem fixada, imagem inválida e prova futura preservando o rascunho.
- A rota HTTP canônica possui teste com modelo estrito e conclusão real sobre os serviços locais.
- A suíte Flutter passou com 15 testes e análise estática limpa. O novo teste vertical percorre rascunho → sessão de upload → envio JPEG sintético → imagem válida → oito notas → declaração → conclusão, e verifica a ordem das chamadas e o corpo final.
- EVENT é apenas outbox persistida. Publicação, reconciliação, entrega, RunScore e replay pertencem ao S07.
- Sem DynamoDB/S3/Cognito reais, benchmark, feed, deploy, commit ou push. A prova de transação DynamoDB e integração DEV pertence ao S09.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas registradas em `implementation-slices.md` (seção "Aceite humano de S05, S06 e S08"). Integração real permanece na S09.
