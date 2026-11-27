# S04 — Rascunho de participação

Data: 29/10/2026. Estado: implementação local revalidada, em revisão. Dependência funcional: S03 implementada localmente; integração AWS permanece S09.

## Resultado entregue

O corredor admitido pode criar, consultar, listar e alterar um rascunho privado vinculado a uma edição e distância aprovadas. A combinação usuário+edição é reservada no mesmo commit do rascunho; repetir a chave idempotente não duplica o registro. Edição arquivada, distância incompatível, usuário não admitido, versão antiga e segunda participação na mesma edição são rejeitados.

O rascunho guarda ID estável, catálogo observado, estado e versão monotônica. Campos opcionais podem ser preenchidos ou limpos. O dono é revalidado na fonte e rascunho alheio retorna 404. A lista é exclusiva do titular e usa cursor opaco ligado a ator, ambiente, estado e limite.

Esta entrega não cria review, medalha, publicação, RunScore ou outbox. Solicitação de edição ausente continua desabilitada: o contrato futuro existe, mas esse caminho depende do slice administrativo próprio.

## Aplicativo e clientes HTTP

No detalhe do catálogo, selecionar uma distância habilita **Criar rascunho**. A tela seguinte permite salvar tempo em segundos, colocação e número de peito, com mensagem explícita de privacidade. Falhas preservam o formulário e conflitos não são sobrescritos silenciosamente.

O harness local expõe quatro rotas novas. Os requests Bruno 13 e 14 criam e listam o rascunho; o OpenAPI local filtrado passa a conter 15 operações. O armazenamento continua em memória e os tokens são sintéticos.

## Verificação

- 57 testes backend aprovados: sete novos cobrem HTTP, idempotência, concorrência com um vencedor, isolamento, catálogo inválido/arquivado, limpeza de campos, versão esperada e listagem.
- 13 testes Flutter aprovados e análise estática sem problemas; o novo teste percorre catálogo → criação → edição do rascunho.
- CloudFormation não foi aplicado e nenhuma integração AWS foi alegada.

Revalidação em 29/10/2026: 28 testes focados de catálogo/participação passaram; a suíte completa, já incluindo o S05 em andamento, passou com 63 testes. Os 13 testes Flutter passaram novamente, junto de análise estática e verificação de formatação. Nenhum dado real ou serviço externo foi utilizado.

## Limitações e próximo passo

Não há DynamoDB/Cognito reais, ensaio de falha AWS, benchmark, aceite humano ou persistência entre processos. A composição aceita a tabela lógica `history`, mas nenhum recurso foi provisionado. O simulador nativo continua com diagnóstico visual separado em S03; testes Flutter não substituem aparelho.

Próximo slice técnico: S05, upload e processamento de foto. Ele deve preservar este rascunho em falha/timeout e não aceitar imagem pendente ou inválida.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas e pendências registradas em `implementation-slices.md` (seção "Aceite humano de S02, S03 e S04"). Integração real permanece na S09.
