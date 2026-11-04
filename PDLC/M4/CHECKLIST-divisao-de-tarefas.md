# RunPass — Checklist de tarefas para dividir entre pessoas

Data: 04/11/2026 (criado em 03/11/2026). Fonte: `implementation-slices.md`, `S09-integracao-dev.md` e `S09-roteiro-e-relatorio.md`.

Estado: S00 a S08 implementadas e aceitas localmente (03/11/2026). O que resta é fechar os gates de entrada e a integração real em DEV (S09). Nada foi provisionado.

Publicação: repositório `Runpass/RunPass-Projeto-X`, sempre para o branch `dev`, por pull request (os rulesets exigem). O PR #2 (visual do mockup, smoke test, cronograma) foi mesclado na `dev` em 04/11/2026.

Como usar: escreva o nome em **Resp.** e marque `[x]` ao concluir, com a evidência (data, ID de execução ou link). Não registre tokens, senhas, e-mails ou dados pessoais. Dados sempre sintéticos.

Legenda de dependência: **→** só começa depois do bloco indicado. Blocos sem seta podem andar em paralelo.

---

## Próximos passos (04/11/2026), em ordem

Concluído desde 03/11/2026: aceite local de S02 a S08; usuário do Thiago (`runpass-dev-thiago`) e do Rafael criados; repositório oficial definido; PR #2 mesclado na `dev`; visual do mockup, smoke test e cronograma publicados.

1. ~~GitHub Environments~~ **Concluído em 04/11/2026:** `dev`, `hom` e `prod` criados com aprovadores (`thicost` e `Moura7`) e restrição de branch, verificados por `gh api`. Falta só conferir que os rulesets exigem a verificação "Verificações locais". O próximo bloqueio é o acesso AWS (item 2).
2. ~~Acesso AWS~~ **Informado como ok pelo usuário em 04/11/2026:** primeiro login e MFA do Rafael e segundo MFA do root. Restam o e-mail do root compartilhado e confirmar `aws sts get-caller-identity` com o ARN de cada pessoa.
3. **Alertas e orçamento:** destinatários definidos (04/11/2026), template corrigido (chave KMS própria) e escalonamento definido (Thiago primeiro, Rafael segundo); falta provar o recebimento no deploy. **Orçamento do DEV concluído em 04/11/2026** (`ORCAMENTO-RunPass-DEV.md`): US$ 9,95/mês, 25% do teto com reserva e contingência. Resta definir quem recebe os alertas de custo.
4. **Artefatos e change sets:** bucket, chaves no SSM, `make lambda-package`, change sets de identidade, dados e app para revisão. Atualizar `GitHubOrg=Runpass` ao aplicar o papel OIDC.
5. **Autorização de provisionamento** dos dois responsáveis, depois deploy em DEV e jornada com `scripts/smoke_journey.py`.
6. **Mobile em aparelhos reais** (Android e iPhone), começando pela demo, que não depende da AWS; depois apontar para DEV com `--dart-define`.
7. **Decisões de produto abertas:** passaporte, conquistas e stories do mockup (fora do MVP no PRD); arquivos de imagem e arte das medalhas; prazo de retenção da lista de espera, dos rascunhos e das solicitações; dono do catálogo real (Thiago).

## Bloco 1 — GitHub e CI (dono ou administrador do repositório)

Resp.: ______ · Destrava: bloco 6 (papel OIDC)

- [x] Repositório oficial: `Runpass/RunPass-Projeto-X` (conta de usuário), publicação por pull request para `dev` (decisão de 03/11/2026); o antigo `Moura7/RunPass-Projeto-X` deixou de ser o destino
- [x] Criar o Environment `dev` em `Settings → Environments` (nome exato, minúsculas); depois `hom` e `prod` (04/11/2026)
- [x] Adicionar os dois responsáveis como **Required reviewers** (decidir "Prevent self-review" e registrar) (04/11/2026)
- [x] Restringir cada Environment ao seu branch (`dev`→`dev`, `hom`→`hom`, `prod`→`main`) em Selected branches and tags (04/11/2026)
- [x] Não colocar segredos no Environment (o papel é assumido por OIDC) (04/11/2026)
- [ ] Rulesets de `dev`, `hom` e `main` já exigem pull request; conferir que a verificação "Verificações locais" também é exigida
- [x] Rodar `gh api repos/Runpass/RunPass-Projeto-X/environments/dev --jq '{name, rules: [.protection_rules[] | {type}], branches: .deployment_branch_policy}'` e confirmar `required_reviewers` + política de branches (04/11/2026)
- [x] Registrar em `S09-integracao-dev.md`: data, quem aprovou, resultado do comando (04/11/2026)
- [ ] Conferir que o workflow `check.yml` passa em Python 3.11 e 3.12

## Bloco 2 — Conta AWS DEV e acesso

Resp.: ______ · Destrava: blocos 4, 5, 6

- [X] Confirmar o MFA do usuário raiz (pendente)
- [ ] Os dois responsáveis fazem `aws login` no perfil `runpass-dev-sa` e confirmam `aws sts get-caller-identity` (conta e região `sa-east-1` corretas)
- [x] Usuário do Thiago: `runpass-dev-operator` renomeado para `runpass-dev-thiago` em 03/11/2026 (login confirmado por `sts get-caller-identity`)
- [x] Usuário do Rafael: criado em 03/11/2026; primeiro login, MFA e `aws login` informados como ok pelo usuário em 04/11/2026 (não verificado pelo assistente)
- [ ] Garantir backup/sincronização do app autenticador do MFA (hoje está em um único celular)
- [x] Decisão: um usuário IAM por pessoa (03/11/2026), no lugar do usuário compartilhado
- [ ] Confirmar o formato das ações `aws-mcp:*` no primeiro uso do usuário IAM

## Bloco 3 — Orçamento e custo

Resp.: ______ · Destrava: autorização de provisionamento

- [x] Itens antes excluídos incorporados em `ORCAMENTO-RunPass-DEV.md` (04/11/2026): DEV em US$ 9,95/mês, US$ 45,44 com reserva e contingência
- [x] `runpass-dev-mensal` revisado com a PTAX de 03/11/2026 (R$ 5,4935): teto de R$ 1.000 = US$ 182,03
- [ ] Aplicar o novo limite do `runpass-dev-mensal`: 30% do teto = R$ 300 = US$ 54,61 (decisão de 04/11/2026; hoje está em US$ 150). `runpass-dev-thiago` não tem `budgets:ModifyBudget`: aplicar no console (Billing → Budgets → Edit) ou com o root
- [x] Preços atualizados e cálculo registrado (`calcular_orcamento_dev_exclusoes.py`, `AWS-PRECOS-EXCLUSOES-SA-EAST-1.json`)
- [ ] Definir quem recebe os alertas de custo (50%, 80% real, 100% previsto) e confirmar o recebimento

## Bloco 4 — Alertas operacionais

Resp.: ______ · → bloco 2

- [x] Destinatários dos alertas definidos em 04/11/2026 (quatro e-mails, fora do Git; entram como `AlertEmail1` a `AlertEmail4` no deploy)
- [x] Escalonamento definido em 04/11/2026: Thiago primeiro, Rafael segundo (prazo de resposta a definir)
- [ ] No deploy da stack de dados, passar `AlertEmail1` a `AlertEmail4` e cada destinatário confirmar o e-mail de assinatura
- [ ] Planejar o teste de disparo e recebimento (DLQ e alarmes de erro da API e da manutenção)

## Bloco 5 — Artefatos, segredos e pré-deploy

Resp.: ______ · → blocos 2 e 3

- [ ] Rodar `make check` e `make mobile-check` no commit que será implantado e registrar os resultados
- [ ] Criar o bucket de artefatos em `sa-east-1` (privado, versionado, fora do CloudFormation)
- [ ] Criar no SSM Parameter Store dois SecureString com valores aleatórios: chave HMAC de exclusões (32 bytes) e chave Fernet de cursores (32 bytes em base64url). Os valores não passam por templates, Git nem chat
- [ ] `make lambda-package`, enviar o zip e anotar a versão do objeto
- [ ] Definir a assinatura/integridade dos artefatos
- [ ] Gerar os change sets `CREATE` de `runpass-dev-identity` e `runpass-dev-data` (somente leitura) e anexar a revisão

## Bloco 6 — Papel OIDC de deploy

Resp.: ______ · → blocos 1 e 2 e autorização explícita

- [ ] Preencher org/repositório no `infra/deploy-role.template.yaml`
- [ ] Gerar o change set de `deploy-role.template.yaml` e revisar (o `sub` deve ser `repo:<org>/<repo>:environment:dev`)
- [ ] Aplicar após autorização
- [ ] Criar o workflow de deploy com aprovação do Environment (só depois do bloco 1 liberado)

## Bloco 7 — Autorização de provisionamento

Resp.: os dois responsáveis · → blocos 3, 4, 5 e 6

- [ ] Revisar os change sets (identidade, dados, app) e a estimativa atualizada
- [ ] Registrar a autorização explícita dos dois responsáveis (data e escopo)
- [ ] Confirmar que o teto de R$ 1.000/mês vale e definir a regra de parar se a previsão ultrapassar

## Bloco 8 — Deploy em DEV

Resp.: ______ · → bloco 7

- [ ] Aplicar `runpass-dev-identity` e `runpass-dev-data`
- [ ] Gerar, revisar e aplicar `runpass-dev-app` (depende dos exports da stack de dados)
- [ ] Registrar outputs das stacks, versão do artefato e IDs dos change sets
- [ ] Confirmar `AccessDenied` inesperado = nenhum nos logs de deploy
- [ ] Carregar o catálogo sintético (carga idempotente)

## Bloco 9 — Jornada principal em DEV (usuário sintético)

Resp.: ______ · → bloco 8 · Registrar em `S09-roteiro-e-relatorio.md`

- [ ] 1. Cadastro e confirmação de e-mail (Cognito)
- [ ] 2. Admissão (18+, teto de mil, marco do 50º), com repetição idempotente
- [ ] 3. Catálogo com filtros e paginação (p50/p95)
- [ ] 4. Rascunho privado criar/atualizar; outro usuário recebe negação
- [ ] 5. Upload e imagem pronta em ≤ 5 s; metadados removidos; imagem inválida falha fechada
- [ ] 6. Conclusão com oito notas e medalha; nota inválida não substitui a review
- [ ] 7. RunScore em ≤ 10 s e auditoria no S3 com localizador
- [ ] 8. Edição versionada; conflito rejeitado
- [ ] 9. Exclusão de participação (foto e projeções removidas; catálogo oficial preservado)
- [ ] 10. Exclusão de conta (Cognito, DynamoDB, S3, filas e lake sem o titular; token antigo negado)

## Bloco 10 — Testes transversais em DEV

Resp.: ______ · → bloco 9 (itens independentes entre si podem ser divididos)

- [ ] Permissões negativas: outro usuário, token expirado, issuer/audience errado, rota admin sem MFA
- [ ] Idempotência: repetir admissão, conclusão e exclusão
- [ ] DLQ e replay: forçar mensagem à DLQ após 5 recepções, replay conclui, alarme recebido (→ bloco 4)
- [ ] Manutenção agendada: reconciliação, expiração e exclusões a cada 5 min
- [ ] Limites de Lambda (memória, timeout, agenda): medir e ajustar
- [ ] Carga: mínima, depois perfil de `PREMISSAS-USO-RunPass-MVP.md` (p50/p95/p99 e erros) observando custo
- [ ] Restore: tráfego fechado, `dispatchEpoch` incrementado, exclusões reaplicadas; medir RPO/RTO
- [ ] Custo observado vs. teto de R$ 1.000/mês

## Bloco 11 — Mobile em aparelhos reais

Resp.: ______ · Pode começar o preparo antes do bloco 8; o teste completo → bloco 8

- [ ] Android real: instalar e percorrer a jornada do bloco 9
- [ ] iPhone real: instalar e percorrer a jornada do bloco 9
- [ ] iPhone real: validar a conversão HEIC e a foto no fluxo de upload (pendência da S05)
- [ ] Apontar o app para a API e o Cognito de DEV (sem credenciais no Git)
- [ ] Registrar defeitos encontrados e reexecutar `make mobile-check` após correções

## Bloco 12 — Aceite humano dos slices (paralelo, não depende da AWS)

Resp.: ______ · Cada pessoa revisa slices diferentes; registrar a decisão no relatório do slice

- [x] S02 identidade e admissão: revisão e decisão
- [x] S03 catálogo: aceito em 03/11/2026 (catálogo real e cobertura de 90% pendentes para o beta; responsável: Thiago)
- [x] S04 rascunho: revisão e decisão
- [x] S05 upload: revisão e decisão (pendente: adaptador S3 real e medição de 5 s)
- [x] S06 conclusão, avaliação e medalha: revisão e decisão
- [x] S07 eventos, RunScore e auditoria: aceito em 03/11/2026 (política de descarte aprovada)
- [x] S08 edição, exclusão e privacidade: revisão e decisão
- [x] Atualizar o estado de cada slice em `implementation-slices.md` (em revisão → aceito)

## Bloco 13 — Encerramento da S09

Resp.: ______ · → blocos 9, 10, 11

- [ ] Preencher o relatório (modelo em `S09-roteiro-e-relatorio.md`): aprovados / falhas / não executados / bloqueados
- [ ] Anexar métricas, IDs de execução, falhas com causa confirmada ou "não verificada", limites e riscos
- [ ] Limpar ou desligar o ambiente DEV (ou justificar mantê-lo) e registrar o custo final
- [ ] Decisão de aceite da primeira entrega pelos responsáveis
- [ ] Registrar que o aceite **não** libera PROD nem beta (feed/social, demais jornadas, políticas e requisitos de lançamento continuam necessários)

---

## Sugestão de divisão para duas pessoas

| Pessoa A | Pessoa B |
| --- | --- |
| Bloco 1 (GitHub, se for dono/admin) e 6 (OIDC) | Bloco 2 (conta e acesso) e 3 (orçamento) |
| Bloco 5 (artefatos e segredos) | Bloco 4 (alertas) |
| Bloco 8 (deploy) | Bloco 12 (aceite dos slices S02–S04) e 11 (Android) |
| Bloco 9 (jornada) | Bloco 12 (S05–S08) e 11 (iPhone) |
| Bloco 10 (permissões, idempotência, DLQ, restore) | Bloco 10 (carga, custo, limites de Lambda) |
| Bloco 13 (relatório), em conjunto | Bloco 7 (autorização), em conjunto |

Observação: o GitHub exige que o dono da conta `Runpass` ou um administrador do repositório crie os Environments; a conta `thicost` tem `push`, sem `admin`. Se a pessoa A não tiver esse papel, a tarefa vai para quem tiver, ou ele concede permissão de administrador.

## Caminho crítico

Bloco 1 + 2 + 3 + 4 → 5 → 6 → 7 → 8 → 9 → 10 e 11 → 13. O bloco 12 corre em paralelo e deve terminar antes do 13.
