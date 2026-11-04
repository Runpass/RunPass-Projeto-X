# S09 — Roteiro de integração DEV e modelo de relatório

Data: 03/11/2026. Estado: **modelo, nada executado**. Todos os campos de resultado começam como `NÃO EXECUTADO`. Não registrar tokens, e-mails, datas de nascimento nem payloads pessoais; usar IDs de execução e timestamps. Dados sempre sintéticos.

Estados permitidos: `APROVADO`, `FALHA`, `NÃO EXECUTADO`, `BLOQUEADO`. Ausência de medição não é aprovação.

## 1. Jornada principal (critério da primeira entrega)

| # | Passo | Critério | Evidência | Estado |
| --- | --- | --- | --- | --- |
| 1 | Cadastro e confirmação de e-mail (Cognito) | usuário confirmado; sem dado pessoal em log | ID da execução, timestamp | NÃO EXECUTADO |
| 2 | Admissão (18+, teto de mil, marco do 50º) | vaga criada uma vez; repetição idempotente | resposta sem dados privados | NÃO EXECUTADO |
| 3 | Catálogo consultável | filtros e paginação; erro protegido não mostra resultado | p50/p95 | NÃO EXECUTADO |
| 4 | Rascunho privado criar/atualizar | versão incrementa; outro usuário recebe negação | códigos HTTP | NÃO EXECUTADO |
| 5 | Upload e processamento da imagem | pronta em ≤ 5 s; metadados removidos; imagem inválida falha fechada | tempo medido, objeto S3 | NÃO EXECUTADO |
| 6 | Conclusão com oito notas | medalha emitida; nota inválida não substitui a review | resposta, evento | NÃO EXECUTADO |
| 7 | RunScore e auditoria | RunScore em ≤ 10 s; auditoria no S3 com localizador | tempo medido | NÃO EXECUTADO |
| 8 | Edição versionada | conflito de versão rejeitado | códigos HTTP | NÃO EXECUTADO |
| 9 | Exclusão de participação | foto e projeções removidas; catálogo oficial preservado | enumeração pós-exclusão | NÃO EXECUTADO |
| 10 | Exclusão de conta | Cognito, DynamoDB, S3, filas e lake sem o titular; token antigo negado | enumeração, tentativa com token | NÃO EXECUTADO |

## 2. Testes transversais

| Área | Verificação | Estado |
| --- | --- | --- |
| Permissões negativas | outro usuário, token expirado, issuer/audience errado, rota admin sem MFA | NÃO EXECUTADO |
| Permissões IAM | change set e execução sem `AccessDenied` inesperado; negações esperadas ocorrem | NÃO EXECUTADO |
| Idempotência | repetir admissão, conclusão e exclusão não duplica efeitos | NÃO EXECUTADO |
| DLQ e replay | mensagem forçada vai à DLQ após 5 recepções; replay conclui; alarme recebido | NÃO EXECUTADO |
| Alarmes | disparo e recebimento nos quatro destinatários definidos (assinatura confirmada por cada um; alarme de teste via `aws cloudwatch set-alarm-state`) | NÃO EXECUTADO (depende do deploy da stack de dados) |
| Carga | perfil aprovado em `PREMISSAS-USO-RunPass-MVP.md`; p50/p95/p99 e erros | NÃO EXECUTADO |
| Manutenção agendada | reconciliação, expiração e exclusões retomáveis a cada 5 min | NÃO EXECUTADO |
| Restore | tráfego fechado, `dispatchEpoch` incrementado, exclusões reaplicadas; RPO/RTO medidos | NÃO EXECUTADO |
| Limites de Lambda | memória, timeout e agenda confirmados ou ajustados com medição | NÃO EXECUTADO |
| Custo | observado vs. teto de R$ 1.000/mês e orçamento `runpass-dev-mensal` | NÃO EXECUTADO |
| Android real | jornada do item 1 em aparelho | NÃO EXECUTADO |
| iPhone real | jornada do item 1 em aparelho | NÃO EXECUTADO |

## 3. Ordem de execução

Pré-requisito: gate de entrada de `S09-integracao-dev.md` fechado e autorização explícita. Sem isso, parar.

1. Artefatos e segredos (sequência de implantação, passos 1 a 3).
2. Change sets de identidade e dados; revisão humana; aplicar após aprovação.
3. Change set da app; revisão; aplicar após aprovação.
4. Jornada (seção 1) com um usuário sintético.
5. Permissões negativas, idempotência, DLQ/replay, alarmes.
6. Carga mínima, depois perfil aprovado, observando custo.
7. Restore.
8. Android e iPhone reais.
9. Limpeza ou desligamento do ambiente e custo final.

Parar e pedir nova aprovação se a previsão ou o custo observado indicar ultrapassagem do teto.

## 4. Modelo do relatório

```
Relatório S09 — <data>
Executores: <iniciais> | Conta DEV / região: sa-east-1 | Commit: <hash> | Versão do artefato: <id do objeto S3>
Change sets revisados: <IDs> | Stacks: <nomes e status>
Resumo: <n aprovados / n falhas / n não executados / n bloqueados>

Resultados: tabelas das seções 1 e 2 preenchidas, com ID de execução e timestamp.
Métricas: p50/p95/p99 por operação; imagem ≤ 5 s; RunScore ≤ 10 s.
Falhas: descrição, causa confirmada ou não verificada, próximo passo.
Limites e riscos: o que não foi medido e por quê.
Custo observado: <valor> vs. teto.
Limpeza: recursos removidos ou mantidos.
Conclusão: compara com os critérios; não libera beta (feed/social, demais jornadas, políticas e requisitos de lançamento continuam necessários).
```
