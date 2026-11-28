# +1pódio: passo a passo para produção (Git privado, 2 contas AWS, CI/CD com Terraform)

Guia de execução. Marque cada item quando concluir. Itens com **[VOCÊ]** exigem sua ação em console/site (e-mail,
cartão, MFA, domínio). Itens com **[CLAUDE]** posso fazer no código quando você pedir.

## Estado atual (lido no repositório)

- Repositório: `Runpass/RunPass-Projeto-X` (+ `RunPass-Catalogo`). Branches `main` e `claude/...`.
- Infra é **CloudFormation** (`infra/*.template.yaml`: identity, data, app, portal, cost, deploy-role), **nenhum template foi aplicado**.
  Isso é bom: renomear e trocar para Terraform agora não destrói nada.
- Já existe a ideia de 3 ambientes (`dev`, `hom`, `prod`), contas distintas para DEV e PROD, OIDC do GitHub e GitHub Environments
  com aprovação (`deploy-role.template.yaml`). O CI atual (`.github/workflows/check.yml`) só roda testes em `dev`, `hom` e `main`.
- Prefixo de recursos hoje: `runpass-<env>-`.

## Decisões que precisam ser fechadas ANTES (30 min)

| # | Decisão | Recomendação |
|---|---------|--------------|
| 1 | **Nome técnico** (AWS, bucket, domínio, pacote do app não aceitam `+` nem `ó`) | `maisumpodio` (curto: `mup`). Marca "+1pódio" fica só nas telas/lojas. |
| 2 | **Domínio** | `maisumpodio.com.br` (ou `.com`). Registre em Registro.br ou Route 53. Anote o e-mail do titular. |
| 3 | **E-mails** | Um alias por conta/função, todos no domínio novo (ver Etapa 1). Nunca reutilize o mesmo e-mail em duas contas AWS. |
| 4 | **Contas AWS** | `maisumpodio-prod` (nova) e `maisumpodio-dev` (a atual, que hospeda DEV **e** HOM, recursos separados por prefixo/nome). |
| 5 | **Repositórios** | Ver Etapa 3. Minha recomendação: **uma organização GitHub nova, 2 repos privados** (prod; dev+hom). |
| 6 | **Terraform vs CloudFormation** | Você decidiu Terraform. Implica **reescrever 6 templates** em módulos Terraform (Etapa 5). Faça em fatias, uma stack por vez. |
| 7 | **Orçamento** | `AGENTS.md` exige orçamento e autorização antes de provisionar algo pago, e aprovação própria para PROD. Defina o teto mensal por conta antes da Etapa 6. |

---

## Contexto da empresa: Mougen.ia (decisão de 28/11/2026, Thiago)

O +1pódio passa a ser **um produto** da empresa Mougen.ia. Isso muda o nível em que as coisas são criadas: empresa
no topo, produto embaixo. O que fica no nível da empresa (criar uma vez) e o que fica no nível do produto:

| Nível | Item | Nome sugerido |
|---|---|---|
| Empresa | Domínio e e-mail | `mougenia.com.br` (confirme: `.ia` não é um domínio registrável; o de Anguilla é `.ai`). Registro.br de `.com.br` pede CNPJ, então abra a empresa antes ou use um domínio provisório. |
| Empresa | Organização GitHub | `mougenia` (repos privados dos produtos dentro dela) |
| Empresa | AWS Organizations (conta de gerenciamento, SSO, cobrança, SCPs) | e-mail `aws-org@mougenia...` |
| Empresa | Contas de desenvolvedor Apple/Google | em nome da empresa (CNPJ), não pessoal; não dá para transferir fácil depois |
| Produto | Contas AWS | `mougenia-maisumpodio-prod` e `mougenia-maisumpodio-dev` (DEV e HOM). Produtos futuros ganham as suas, na mesma Organization |
| Produto | Repositórios | `mougenia/maisumpodio` e `mougenia/maisumpodio-dev`; catálogo: `mougenia/maisumpodio-catalogo` |
| Produto | Prefixo de recursos AWS | `maisumpodio-<env>-` (o produto, não a empresa) |
| Produto | Subdomínios | `api.maisumpodio.com.br` ou `api.podio.mougenia.com.br` (decida se o produto tem domínio próprio) |

Consequências práticas:

- Use o domínio da **empresa** nos e-mails desta guia (onde aparece `maisumpodio.com.br`, leia `mougenia...` se não houver domínio próprio do produto). Use aliases por produto, ex.: `aws-prod-podio@`, `alertas-podio@`.
- A estrutura de AWS Organizations com OUs por produto (`Podio/prod`, `Podio/dev`) permite novos produtos sem refazer governança.
- Os termos de uso, política de privacidade e o controlador de dados (LGPD) do app devem citar a **Mougen.ia**; ajuste antes de publicar nas lojas.
- Se a empresa ainda não existe juridicamente, as contas AWS e do GitHub podem ser criadas já, mas troque o titular/cobrança para a empresa assim que o CNPJ sair (é mais fácil criar certo do que migrar).

---

## Etapa 0: Parar de expor o código HOJE (privado)

1. **[VOCÊ]** GitHub → repositório `RunPass-Projeto-X` → **Settings → General → Danger Zone → Change repository visibility → Make private**. Repita em `RunPass-Catalogo`.
   Se o repo já foi público: forks e clones existentes continuam existindo; trate tudo que já esteve no histórico como possivelmente exposto.
2. **[VOCÊ]** Em **Settings → Code security**: ative *Secret scanning* e *Push protection* (e *Dependabot alerts*). Em repo privado, alguns recursos exigem GitHub Team/Advanced Security; confira o plano.
3. **[CLAUDE]** Varredura de segredos no histórico completo (gitleaks/trufflehog) e relatório. Se achar algo: **rotacione a credencial** (não adianta só apagar do Git), depois limpe o histórico com `git filter-repo` apenas se for migrar para repo novo.
4. **[VOCÊ]** Confirme que `.env`, chaves e e-mails de alerta estão fora do Git (o `CLAUDE.md` do catálogo já exige isso).

## Etapa 1: Domínio e e-mails

1. **[VOCÊ]** Registrar o domínio (ex.: `maisumpodio.com.br`). Ative bloqueio de transferência e 2FA no registrador.
2. **[VOCÊ]** Criar o e-mail no domínio (Google Workspace, Zoho, etc.). Crie **aliases/grupos** (cada conta AWS precisa de e-mail único):
   - `aws-prod@maisumpodio.com.br` → root da conta PROD
   - `aws-dev@maisumpodio.com.br` → root da conta DEV/HOM
   - `aws-org@maisumpodio.com.br` → conta de gerenciamento do AWS Organizations (se criar uma; ver Etapa 2)
   - `github@maisumpodio.com.br` → dono da organização GitHub
   - `alertas@maisumpodio.com.br` → SNS/Budgets/alarmes
   - `contato@` / `suporte@` → SES/lojas de app
3. **[VOCÊ]** Configurar SPF, DKIM e DMARC do domínio (necessário para o Cognito/SES enviar e-mail sem cair em spam).
4. Mantenha o e-mail do **dono da conta** (root) numa caixa que mais de uma pessoa de confiança consiga recuperar.

## Etapa 2: Contas AWS

Estrutura recomendada (AWS Organizations):

```
Organização (conta de gerenciamento, sem workloads)
├── maisumpodio-prod   (nova)
└── maisumpodio-dev    (a conta atual: DEV + HOM)
```

1. **[VOCÊ]** Criar a conta de gerenciamento com `aws-org@...` (ou promover a conta atual; prefira conta limpa só para governança e cobrança).
2. **[VOCÊ]** Em cada conta root: **MFA** (app autenticador ou chave física), senha longa guardada em gerenciador, **nunca criar access key de root**.
3. **[VOCÊ]** Em Organizations: **Add an AWS account → Create** `maisumpodio-prod` com `aws-prod@...` (cria a role `OrganizationAccountAccessRole`). Para a conta atual: **Invite** e, antes, troque o e-mail root dela para `aws-dev@...`.
4. **[VOCÊ]** Cobrança: ative *Billing → Preferences → alertas de uso*, *Cost Anomaly Detection* e **AWS Budgets** por conta (alertas atrasam horas; o `UsageLedger` do catálogo continua sendo a trava rígida).
5. **[VOCÊ]** **IAM Identity Center** (SSO) na conta de gerenciamento: crie seu usuário humano, grupos `admin` e `somente-leitura`, e atribua a cada conta. Pessoas usam SSO; **CI usa OIDC**; ninguém usa access key de longa duração.
6. **[VOCÊ]** SCP básica na OU: negar uso de root, negar regiões fora de `sa-east-1` e `us-east-1` (Bedrock só em `us-east-1`, ver `CLAUDE.md` do catálogo) e negar desligar CloudTrail.
7. **[VOCÊ]** Em cada conta: habilitar **CloudTrail** (trilha de organização), **AWS Config** opcional, **GuardDuty** opcional (custo; decida na Etapa 0).
8. **Cotas/pedidos** que demoram: SES saindo do sandbox (prod), Cognito e-mail com SES, limites do Bedrock. Abra os pedidos cedo.

## Etapa 3: GitHub (organização e repositórios)

Modelo que você descreveu, com minha recomendação de organização:

| Repositório (privado) | Conteúdo | Branches | Conta AWS |
|---|---|---|---|
| `maisumpodio` | código do app + **infra de PROD** (Terraform `envs/prod`) | `main` | prod |
| `maisumpodio-dev` | código em desenvolvimento + **infra DEV e HOM** (`envs/dev`, `envs/hom`) | `dev`, `hom` | dev |

Alternativa mais simples (considere): **um único repo** `maisumpodio` com `envs/dev|hom|prod` e GitHub Environments separados.
Dois repos têm vantagem de isolamento (quem mexe em dev não vê configurações de prod), mas **duplicam código** e exigem um
processo de promoção. Se escolher dois repos, defina agora como o código chega em prod:

- `maisumpodio-dev` é onde se desenvolve. Quando `hom` é aprovado, abra um **PR de promoção** `maisumpodio-dev:hom` → `maisumpodio:main` (adicione `maisumpodio-dev` como segundo remote do repo de prod e faça merge/cherry-pick), **sem** levar arquivos de `envs/dev|hom`.
- Nunca o contrário: nada de prod volta para o repo de dev.

Passos:

1. **[VOCÊ]** Criar a **organização GitHub** (ex.: `maisumpodio`) com `github@...`. Ative 2FA obrigatório para todos os membros.
2. **[VOCÊ]** Transferir/renomear o repositório atual: **Settings → Transfer** para a organização nova e **Rename** para `maisumpodio`; criar `maisumpodio-dev` (privado, vazio). O GitHub mantém redirecionamento do nome antigo.
   - Se o histórico tinha segredos (Etapa 0.3): crie o repo novo a partir de um clone limpo (`git filter-repo`) em vez de transferir.
3. **[VOCÊ]** Em `maisumpodio` → **Settings → Branches → Ruleset** para `main`: exigir PR, 1 aprovação, status checks (`python`, `mobile`, `terraform-plan`), sem force-push, sem deletar, *include administrators*.
4. **[VOCÊ]** Em `maisumpodio-dev`: rulesets para `dev` (1 aprovação) e `hom` (1 aprovação + checks).
5. **[VOCÊ]** **Settings → Environments**:
   - `maisumpodio`: ambiente `prod` com **Required reviewers** (você + 1 pessoa), e restrinja a deploys da branch `main`.
   - `maisumpodio-dev`: ambientes `dev` (sem aprovação) e `hom` (com aprovação), cada um só da sua branch.
6. **[VOCÊ]** **Actions → General**: permitir só actions da própria organização + GitHub + as que você fixar por SHA; *Workflow permissions: read-only*.
7. **[CLAUDE]** Adicionar `CODEOWNERS` (infra/ e `.github/` exigem você), `dependabot.yml` e fixar actions por SHA.
8. Atualizar **remote local**: `git remote set-url origin https://github.com/<org>/maisumpodio.git`.

## Etapa 4: Renomear RunPass → +1pódio (antes de provisionar!)

Como nada foi aplicado, o custo é só texto. **[CLAUDE]** faço em uma passada, por slice, com testes:

| Onde | De | Para |
|---|---|---|
| Prefixo de recursos | `runpass-<env>-` | `maisumpodio-<env>-` (em prod: `maisumpodio-prod-`) |
| Papéis OIDC | `runpass-<env>-gha-deploy` / `-cfn-exec` | `maisumpodio-<env>-gha-deploy` / `-tf-exec` |
| Buckets S3 (nome é global) | `runpass-...` | `maisumpodio-<conta>-<env>-<função>` (sufixo com ID da conta evita colisão) |
| Mobile | `pubspec.yaml`, bundle id Android/iOS | `br.com.maisumpodio.app` (decida agora: **não muda depois de publicar na loja**) |
| Textos de usuário | "RunPass" | "+1pódio" (apenas strings de UI/docs) |
| Docs/AGENTS.md/CLAUDE.md | menções | atualizar; manter `PDLC` como histórico |
| Repo do catálogo | `RunPass-Catalogo` | `maisumpodio-catalogo` (privado) |

Regras: sem `+`, acento ou espaço em nome de recurso; **sem travessão longo** (—) em nomes/descrições AWS; use hífen.

## Etapa 5: Terraform (estrutura, estado, OIDC)

### 5.1 Estrutura sugerida (no repo prod; no repo dev só `envs/dev` e `envs/hom`)

```
infra/
  bootstrap/            # roda 1x por conta, manualmente (estado + OIDC + roles)
  modules/
    identity/           # Cognito (corredores e operadores, TOTP obrigatório p/ operadores)
    data/               # DynamoDB (6 tabelas), S3, SQS + DLQ, alarmes
    app/                # API HTTP, Lambdas, IAM por finalidade, logs, alarmes
    portal/             # portal web (hoje portal.template.yaml)
    cost/               # budgets/alarme de custo
  envs/
    prod/  (main.tf, backend.tf, prod.tfvars)
    dev/   hom/         # só no repo de dev
```

Mapeamento 1:1 com `infra/*.template.yaml` atuais (cada template vira um módulo). Reescreva **um módulo por vez**, com `terraform validate`
+ `tflint` + `checkov`/`trivy config` no CI, e só então `plan` real. Os parâmetros hoje existentes (`Environment`, `ArtifactBucket`,
parâmetros SSM `ErasureHmacParameter`, `CursorKeyParameter`) viram variáveis; **valores secretos não entram em `.tfvars` nem no Git**.

### 5.2 Bootstrap por conta (manual, uma vez) **[VOCÊ + CLAUDE]**

1. Instale Terraform (>= 1.10) e AWS CLI v2; entre com `aws sso login` na conta alvo (nunca root).
2. `infra/bootstrap` cria:
   - bucket de **estado** `maisumpodio-<conta>-tfstate` (versionado, criptografado, bloqueio de acesso público, política só para as roles). Locking: `use_lockfile = true` (S3 nativo; confirme na doc do Terraform da sua versão) ou tabela DynamoDB.
   - bucket de **artefatos** (zip das Lambdas, de `scripts/package-lambda.sh`).
   - **Provedor OIDC** do GitHub (`token.actions.githubusercontent.com`; só pode haver 1 por conta).
   - Role `maisumpodio-<env>-gha-plan` (somente leitura + ler estado) e `maisumpodio-<env>-gha-apply` (aplica), com trust restrito assim:
     ```
     token.actions.githubusercontent.com:aud = sts.amazonaws.com
     token.actions.githubusercontent.com:sub = repo:<org>/<repo>:environment:<env>   (apply)
     token.actions.githubusercontent.com:sub = repo:<org>/<repo>:pull_request          (plan)
     ```
   - Ponto de partida: `infra/deploy-role.template.yaml` já tem esse desenho; traduzir para Terraform.
3. Rode no prod e depois no dev. Guarde os ARNs das roles (não são segredo) como *variables* do GitHub Environment.
4. Criar manualmente (fora do Terraform, para o valor nunca entrar no estado): parâmetros SSM SecureString `ErasureHmac` e `CursorKey`. Para segredos de terceiros use Secrets Manager.

### 5.3 Backend por ambiente

```hcl
terraform {
  backend "s3" {
    bucket       = "maisumpodio-<conta>-tfstate"
    key          = "prod/terraform.tfstate"   # dev/ e hom/ no repo de dev
    region       = "sa-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

Use provider com `default_tags` (`Projeto=maisumpodio`, `Ambiente=prod`, `Dono=...`) e `allowed_account_ids = ["<id da conta>"]`
**em cada env**, para um `apply` nunca cair na conta errada.

## Etapa 6: Esteira CI/CD

### 6.1 Repo de prod (`maisumpodio`)

- `ci.yml` (PR e push): `make check`, `make mobile-check`, `terraform fmt -check`, `validate`, `tflint`, scanner de IaC, scanner de segredos.
- `plan.yml` (PR em `infra/**`): assume `gha-plan` por OIDC, roda `terraform plan` e posta o plano no PR.
- `deploy-prod.yml` (push em `main`): job `plan` → **job `apply` com `environment: prod`** (pausa para aprovação humana) → `terraform apply` do plano **salvo** (o mesmo que foi revisado). Permissões do workflow: `id-token: write`, `contents: read`.
- Build do artefato Lambda uma vez (`scripts/package-lambda.sh`), versionado por SHA, enviado ao bucket de artefatos e referenciado no Terraform.
- Concurrency por ambiente (`concurrency: tf-prod`) para impedir dois applies simultâneos.

### 6.2 Repo de dev (`maisumpodio-dev`)

- Branch `dev` → deploy automático em DEV (conta dev). Branch `hom` → deploy em HOM (conta dev, estado e prefixo próprios, com aprovação).
- Mesmos workflows, trocando o ambiente. HOM deve ser **cópia fiel de PROD** (mesmos módulos, tamanhos menores) para o teste valer.

### 6.3 Segredos do CI

- Nenhuma access key no GitHub. Só *variables*: `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`.
- Segredos de app (SES, chaves de API) ficam no SSM/Secrets Manager da conta; o Terraform recebe **o nome**, não o valor.

## Etapa 7: Ordem de subida (primeiro ambiente real)

1. Conta dev: bootstrap → `identity` → `data` → `app` → `portal` em **DEV**, com dados sintéticos. Fluxo de aceite do `AGENTS.md`: autenticação → catálogo → rascunho → imagem → conclusão → avaliação e medalha.
2. **HOM**: repetir, validar, aceite humano.
3. Conta prod: bootstrap → mesmas stacks, **mesma ordem**. Domínio `api.maisumpodio.com.br`, certificado ACM, DNS (Route 53).
4. Cognito/SES: domínio verificado, tirar do sandbox, política de senha e TOTP dos operadores.
5. Backups: PITR nas tabelas ativas (a `ErasureControl` continua **sem** backup, por decisão do projeto), versionamento S3 e teste de restauração.
6. Observabilidade: alarmes → SNS → `alertas@...`; log retention; Budgets por conta.
7. Aprovação de PROD/beta (regra do `AGENTS.md`) e registro do resultado no slice, diferenciando **teste local**, **integração real** e **aceite humano**.

## Etapa 8: Segurança mínima antes de abrir ao público

- MFA em todos os humanos; ninguém usa o root após o setup.
- Roles de CI com menor privilégio (hoje o template usa `*` por serviço; **aperte após o primeiro plan real**).
- `terraform destroy` bloqueado em prod (`prevent_destroy` nas tabelas/buckets de dados; proteção de término).
- Rotação planejada das chaves (`ErasureHmac`, `CursorKey`).
- Lojas de app: contas Apple Developer / Google Play com o e-mail do domínio (nome da empresa/CNPJ, se houver).

## Checklist-resumo

- [ ] Repos atuais privados + secret scanning + varredura de histórico
- [ ] Nome técnico e domínio definidos; e-mails/aliases criados
- [ ] Organizations criada; conta `prod` nova; conta atual convidada e com e-mail novo; MFA; SSO; Budgets
- [ ] Organização GitHub; repos `maisumpodio` e `maisumpodio-dev`; rulesets; Environments com aprovação
- [ ] Renomeação RunPass → maisumpodio no código e na infra
- [ ] Bootstrap (estado, artefatos, OIDC, roles) em dev e prod
- [ ] Módulos Terraform (identity, data, app, portal, cost) com CI de validação
- [ ] Esteira: plan no PR, apply com aprovação, concurrency
- [ ] DEV → HOM → PROD, aceite humano, aprovação de PROD

> Nota: este guia foi montado a partir do código do repositório e de prática comum; antes de aplicar, confirme na documentação
> oficial da AWS e do Terraform os detalhes de versão (ex.: bloqueio de estado nativo em S3) e preços. Não executei nenhuma
> ação em AWS ou GitHub.

---

## Custos (levantados em 28/11/2026)

Preços unitários: tabela oficial da AWS (Price List API), região `sa-east-1`, consultada em 28/11/2026. Câmbio de referência: PTAX R$ 5,4935
(`CLAUDE.md` do catálogo, 03/11/2026). Lido nos templates: `infra/data`, `app`, `portal`, `identity`, `cost`, `deploy-role`.

### Custo fixo por ambiente (existe mesmo sem usuários)

| Recurso (origem) | Quantidade | US$/mês |
|---|---|---|
| Alarmes CloudWatch (`app`: 2, `data`: 2) a US$ 0,135 | 4 | 0,54 |
| Chave KMS `AlertsKey` (`data`) a US$ 1,00 | 1 | 1,00 |
| Sondagem SQS dos 2 consumidores (suposição: 5 pollers, 3 req/min) a US$ 0,40/M | 2 filas | até 0,52 |
| Lambda de manutenção, `rate(5 minutes)`, 512 MB, suposição de 1 s | 8.640/mês | 0,06 |
| Lambda do portal (importação), `rate(1 hour)`, 1769 MB, suposição de 10 s | 720/mês | 0,17 |
| DynamoDB (6 tabelas), S3 (2 buckets), SQS (4 filas), 2 APIs HTTP, SNS, EventBridge, Budgets, IAM/OIDC | sem taxa fixa | 0,00 |
| **Total por ambiente** | | **cerca de 2,3** |

DEV + HOM + PROD (3 stacks) ≈ **US$ 6,9 por mês**, mais **US$ 0,50** da zona DNS no Route 53 = **US$ 7,4 (cerca de R$ 40) por mês**.
As duas suposições de duração (1 s e 10 s) e a de pollers do SQS **não foram medidas**; meça no primeiro deploy.

### Custo variável (por uso)

| Item | Preço |
|---|---|
| Cognito Lite / Essentials / Plus | US$ 0,0055 / 0,015 / 0,02 por MAU; **os primeiros 10.000 MAU são grátis** (faixa global gratuita na tabela de preços) |
| API HTTP | US$ 1,59 por milhão de requisições |
| Lambda (arm64) | US$ 0,20 por milhão + US$ 0,0000133334 por GB-s |
| DynamoDB sob demanda | US$ 0,9375/M escritas, US$ 0,1875/M leituras; armazenamento: 25 GB grátis, depois US$ 0,375/GB; PITR US$ 0,30/GB |
| S3 | US$ 0,0405/GB-mês |
| SQS padrão | US$ 0,40 por milhão de requisições |
| Logs CloudWatch | US$ 0,90/GB ingerido, US$ 0,0408/GB guardado (retenção: 7 dias em dev/hom, 30 em prod) |
| SES (e-mail) | US$ 0,16 por mil |

Referência por 1 milhão de chamadas de API (1 escrita + 3 leituras cada, 150 ms a 1024 MB, suposto): **cerca de US$ 5,3**.

### Pontos que mudam a conta ou o comportamento

1. **Plano do Cognito não fixado.** O template não define `UserPoolTier`; o padrão de pools novos não foi confirmado aqui. Até 10.000 MAU é grátis; acima disso, Lite custa US$ 55 e Essentials US$ 150 por 10.000 MAU extras.
2. **Cognito sem SES.** Sem `EmailConfiguration`, o envio usa o remetente padrão do Cognito (limite diário baixo, não confirmado na doc). Em produção, configure SES com o domínio.
3. **Limite do projeto**: `cost.template.yaml` usa **US$ 54,61 por mês por ambiente** (R$ 300). Hoje o gasto fixo previsto é ~4% disso.
4. **OpenAI (portal)**: o painel mostra um limite mensal padrão de **US$ 10**, fora da AWS e sem relação com os templates. O catálogo tem o piloto Bedrock de R$ 100, à parte.
5. **Free tier da conta nova** não foi descontado nem verificado (as páginas oficiais da AWS não abriram neste ambiente).

### Custos fora da AWS (confirmados quando há fonte oficial)

| Item | Valor | Fonte |
|---|---|---|
| Apple Developer Program | US$ 99 por ano | developer.apple.com/support/enrollment |
| Google Play Console | US$ 25 (uma vez) | fonte secundária; confirmar na página do Google |
| GitHub Team | US$ 4 por usuário/mês | fonte secundária; confirmar em github.com/pricing |
| Domínio `mougen.ia.br` | **não localizado** | consultar a tabela do Registro.br |
| E-mail corporativo, contador/CNPJ, plano de suporte AWS | **não levantados** | |
