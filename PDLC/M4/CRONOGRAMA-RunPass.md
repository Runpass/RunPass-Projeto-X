# RunPass — Cronograma: priorizado, restante do MVP e fora do MVP

Data-base: 03/11/2026 (atualizado em 04/11/2026). Fontes: `PRD_RunPass_MVP_v2.md` (seções 19 e 20), `implementation-slices.md`, `S09-integracao-dev.md` e `CHECKLIST-divisao-de-tarefas.md`.

**Aviso sobre as datas.** Nem o PRD nem a SPEC trazem datas de calendário, exceto a janela do beta (60 dias a partir do 50º usuário admitido). Todas as durações abaixo são **estimativas do assistente**, sem base em histórico de velocidade da equipe, e não são compromisso. Premissa: duas pessoas (Thiago e Rafael) com dedicação alta e contínua. Com dedicação parcial, multiplique as durações. As faixas de calendário só valem se o início for a data-base. Revisar quando a capacidade for confirmada.

## 1. Já pronto (aceite local em 03/11/2026)

S00 a S08: autenticação, catálogo, rascunho, imagem, conclusão com avaliação e medalha, eventos e RunScore, edição, exclusão e privacidade. Falta provar tudo em serviços reais (S09). Telas do mockup (Início como feed, Corridas/detalhe com abas, Meu Medalheiro, Perfil) aplicadas; a demo web está disponível. O PR #2 (app, smoke test e este cronograma) foi mesclado na `dev` de `Runpass/RunPass-Projeto-X` em 04/11/2026, e a publicação passa a ser sempre por PR para a `dev`.

## 2. Priorizado agora: S09, integração real em DEV (primeira entrega)

| # | Item | Depende de | Estimativa | Previsão (se começar em 04/11) |
| --- | --- | --- | --- | --- |
| 1 | **Concluído em 04/11/2026:** Environments `dev`, `hom` e `prod` no repositório `Runpass/RunPass-Projeto-X`, com aprovadores e restrição de branch | dono da conta `Runpass` ou administrador | 0,5 dia | concluído |
| 2 | Primeiro login e MFA do Rafael; segundo MFA do root; e-mail do root compartilhado | acesso ao root, os dois online | 0,5 a 1 dia | semana de 03/11 |
| 3 | Alertas operacionais (destinatário, assinatura, teste) | conta AWS | 1 dia | semana de 03/11 |
| 4 | **Concluído em 04/11/2026:** orçamento do DEV com itens excluídos e câmbio (`ORCAMENTO-RunPass-DEV.md`) | premissas suas | 1 a 2 dias | concluído |
| 5 | Artefatos, chaves no SSM, change sets (identidade, dados, app) revisados | 1 a 4 | 2 a 3 dias | semana de 10/11 |
| 6 | Papel OIDC de deploy e workflow de deploy | 1 e 5 | 1 dia | semana de 10/11 |
| 7 | **Autorização explícita de provisionamento** | 4 a 6 | 0,5 dia | semana de 10/11 |
| 8 | Deploy em DEV (3 stacks) e carga do catálogo sintético | 7 | 1 a 2 dias | semana de 17/11 |
| 9 | Jornada completa em DEV (smoke test + manual) | 8 | 1 a 2 dias | semana de 17/11 |
| 10 | Testes transversais: permissões negativas, idempotência, DLQ/replay, alarmes, manutenção, limites de Lambda | 9 | 3 a 4 dias | semana de 24/11 |
| 11 | Carga, custo observado, restore com RPO/RTO | 10 | 2 a 3 dias | semana de 24/11 a 01/12 |
| 12 | Android e iPhone reais (HEIC, foto, jornada) | 8; aparelhos | 2 a 4 dias, em paralelo ao 10 | semana de 24/11 |
| 13 | Relatório da S09 e decisão de aceite | 9 a 12 | 1 a 2 dias | início de dezembro |

**Previsão da S09: 3 a 5 semanas, ou seja, entre o fim de novembro e meados de dezembro de 2026.** O caminho crítico passa pelos itens 1 e 7 (decisões e acessos de vocês), não por código. O aceite da S09 não libera o beta.

## 3. Restante do P0 do MVP (ainda sem slice, depende da S09 concluída)

Estes itens estão **no escopo do MVP** (PRD seção 20, P0), mas fora da primeira entrega. Cada um precisa de slice, contrato e modelo antes de codificar. Estimativas com duas pessoas em paralelo onde possível.

| Slice proposto | Conteúdo | Estimativa |
| --- | --- | --- |
| S10 | Solicitação de prova ausente, revisão humana e painel administrativo mínimo | 3 a 4 semanas |
| S11 | Perfil público, busca de corredores, seguir e bloquear | 2 a 3 semanas |
| S12 | Avaliações públicas por edição (rota `/editions/{id}/reviews`), notas por critério, medalhas públicas, imagem da medalha exibível | 2 a 3 semanas |
| S13 | Feed de conclusões, publicação, curtidas, comentários, cards e links compartilháveis | 4 a 5 semanas |
| S14 | Wishlist | 1 a 2 semanas |
| S15 | Avisos no app, denúncias, moderação e bloqueio | 2 a 3 semanas |
| S16 | Privacidade completa, retenções definidas, analytics do beta, feedback no app | 2 a 3 semanas |
| S17 | Lojas oficiais (contas, assinatura, TestFlight/Play, links), catálogo real com cobertura de 90%, lista de referência | 3 a 4 semanas, mais a revisão das lojas (externa) |
| Hardening | Persistência segura de sessão, aprovação específica de PROD, ensaio de operadores com MFA, revisão final | 2 a 3 semanas |

**Previsão do MVP completo: cerca de 5 a 7 meses depois da S09**, ou seja, **entre abril e junho de 2027**, com confiança baixa. O principal risco de prazo está fora do código: revisão das lojas, levantamento do catálogo real (Thiago é o responsável) e as políticas de retenção ainda sem prazo. O beta de 60 dias só começa quando o 50º usuário for admitido.

## 4. Fora do MVP (decisão explícita do PRD, seção 20)

| Item | Situação | Previsão de entrada |
| --- | --- | --- |
| Stories (mockup, tela Início) | Fora do MVP | Sem ordem aprovada |
| Conquistas por marcos (mockup: Explorador, Especialista, Maratonista) | Fora do MVP ("conquistas extras por marcos") | Sem ordem aprovada |
| Passaporte de cidades (mockup, Perfil) | Não listado; mais próximo de conquistas por marcos | **Decisão pendente de vocês** |
| Site para usuários, notificações push, importação de contatos | Fora do MVP | Sem ordem aprovada |
| Rankings, clubes, grupos, assessorias | Fora do MVP | Sem ordem aprovada |
| Monetização, premium, afiliados, anúncios, analytics B2B, marketplace, pagamentos | Fora do MVP | Sem ordem aprovada |
| GPS, treino, streaming, chat privado, reels, vídeos, feed de fotos livres | Fora do MVP | Sem ordem aprovada |
| Integrações Garmin, Strava, Apple Health, Health Connect | Fora do MVP | Sem ordem aprovada |
| Catálogo por IA, turismo esportivo | Fora do MVP | Sem ordem aprovada |

O PRD diz que "não há ordem pós-MVP aprovada" e que esses itens serão reavaliados após evidências de valor. **Não existe previsão de entrada.** O ponto natural de decisão é o encerramento do beta, 60 dias depois do 50º usuário, com os dados de adesão e feedback. Isso sugere uma revisão no segundo semestre de 2027, sujeita ao calendário real do beta.

## 5. Mapa resumido

| Período (estimativa) | Marco |
| --- | --- |
| Novembro de 2026 | Gates da S09, deploy em DEV, jornada |
| Fim de novembro a meados de dezembro de 2026 | Testes reais, carga, restore, relatório e aceite da S09 |
| Dezembro de 2026 a junho de 2027 | S10 a S17 e hardening, em paralelo onde der |
| Entre abril e junho de 2027 | MVP completo pronto para o beta (confiança baixa) |
| Após o 50º usuário + 60 dias | Fim do beta e reavaliação do que ficou fora |

## 6. O que muda esta previsão

- Capacidade real das duas pessoas e se o trabalho é de tempo integral.
- Demora das decisões e acessos de vocês nos itens 1, 2 e 7 da S09.
- Tempo de revisão das lojas e da conta de desenvolvedor Apple e Google.
- Esforço real do catálogo (fonte, revisão, cobertura de 90%).
- Qualquer decisão de ampliar o escopo da primeira entrega (por exemplo, trazer o feed para antes do beta).
