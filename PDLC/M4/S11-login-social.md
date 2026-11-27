# S11 — Login social (Google e Facebook) (25/11/2026)

Estado: **planejado, nada implementado**. Sem infraestrutura, sem pacotes no mobile, sem código. Este documento registra o desenho acordado antes do início da implementação.

## Decisão de produto (usuário, 25/11/2026)

Supera o registrado em `PRD_RunPass_MVP_v2.md` §6 ("Login Google e Apple permanecem como evolução sujeita à validação dos requisitos de distribuição"): login social entra agora, ainda na primeira entrega, escopo **Google + Facebook** (Apple fica de fora por enquanto — não há build iOS em andamento; revisar se/quando houver, por causa da App Store Guideline 4.8, que normalmente exige "Sign in with Apple" quando outros provedores sociais são oferecidos).

Ambiente: **apenas DEV**. Sem provisionamento em produção nesta entrega.

Vinculação de conta: se uma conta já existir por e-mail/senha e a pessoa entrar depois via Google/Facebook com o **mesmo e-mail verificado pelo provedor**, a conta é **vinculada automaticamente** — mesma conta passa a aceitar os dois métodos de login. Não bloquear nem criar conta duplicada.

## Dependências

- S02 (Identidade, admissão e autorização) — este slice estende o `RunnerPool`/`RunnerClient` descritos em `S02-identidade-admissao.md` e `infra/identity.template.json`.
- Credenciais OAuth (Google Cloud Console e Meta for Developers) para DEV — ainda não criadas; usuário vai criar com orientação, guardadas no Secrets Manager (nunca em `dart-define` puro nem no Git).

## Desenho (a confirmar durante a implementação)

- **Infra** (`infra/identity.template.json`): `AWS::Cognito::UserPoolIdentityProvider` para Google e Facebook no `RunnerPool`; `UserPoolDomain` (Hosted UI); `RunnerClient.SupportedIdentityProviders` passa a incluir `Google`/`Facebook`; `AllowedOAuthFlows` (`code`); `CallbackURLs`/`LogoutURLs` com deep link do app mobile.
- **Mobile** (`mobile/lib/main.dart`, `mobile/lib/identity_gateway.dart`): botões com ícone Google/Facebook na tela de "Criar conta" (ícones discretos, sem botão grande colorido, conforme padrão único por função do AGENTS.md); fluxo via Cognito Hosted UI (webview/`flutter_web_auth_2`) em vez de SDKs nativos — evita configuração extra de SHA-1/Bundle ID por enquanto; troca do `authorization_code` por tokens Cognito em `/oauth2/token`.
- **Backend**: confirmar se a Lambda de admissão precisa tratar usuários federados sem senha e sem `gender`/`birthDate` garantidos pelo provedor (continuam preenchendo a tela de admissão normalmente).
- **Modelo de dados**: revisar `MODELO-DYNAMODB-RunPass-v1.md` e `API-RunPass-v1.openapi.json` apenas se o desenho exigir atributo novo (ex. provedor de origem); não alterar contrato sem necessidade.

## Limites conhecidos (registrados antes de começar)

- Sem suporte a Apple nesta rodada.
- Sem provisionamento em produção.
- Vinculação de conta depende do e-mail vir marcado como verificado pelo provedor (`email_verified`); caso de provedor não verificar e-mail precisa de tratamento à parte, a confirmar durante a implementação.

## Progresso

- **Fase 0 (specs)** — concluída.
- **Fase 1 (credenciais OAuth)** — concluída:
  - Google: projeto "RunPass DEV" no Google Cloud Console, OAuth consent screen configurada, Client ID tipo "App da Web" criado com redirect URI `https://runpass-dev.auth.sa-east-1.amazoncognito.com/oauth2/idpresponse`.
  - Facebook: app "RunPass DEV" no Meta for Developers, produto Login do Facebook configurado com o mesmo redirect URI.
  - Client ID/Secret e App ID/Secret guardados no AWS Secrets Manager (conta `263097734277`, região `sa-east-1`), nunca em `dart-define` nem no Git: `runpass/dev/oauth/google` (`client_id`, `client_secret`) e `runpass/dev/oauth/facebook` (`app_id`, `app_secret`).
- **Fase 2 (infra)** — concluída no desenho/template, **não deployada**:
  - `infra/identity.template.json` ganhou `GoogleIdentityProvider` e `FacebookIdentityProvider` (`AWS::Cognito::UserPoolIdentityProvider`), `RunnerPoolDomain` (`AWS::Cognito::UserPoolDomain`, prefixo `runpass-dev`) e `RunnerClient` atualizado (`SupportedIdentityProviders`, `AllowedOAuthFlows: [code]`, `AllowedOAuthScopes: [openid, email, profile]`, `CallbackURLs`/`LogoutURLs`), tudo sob `Condition: IsDev` (nada muda em PROD).
  - Esquema de deep link confirmado pelo usuário (26/11/2026): `runpass://auth/callback` e `runpass://auth/logout`.
  - Os três recursos novos puxam os segredos via `{{resolve:secretsmanager:...}}`; nenhum valor real entra no template nem no Git.

## Restrição do usuário (26/11/2026)

Nesta implementação, **não gerar .apk nem fazer commit** sem aprovação explícita do usuário — vale para todas as fases seguintes (mobile, deploy, testes), reforça [[confirm_before_deploy_and_apk]].

## Progresso (continuação)

- **Fase 3 (deploy em DEV)** — concluída em 26/11/2026: `aws cloudformation` update do stack `runpass-dev-identity` (`sa-east-1`), via change set, com aprovação explícita do usuário em cada etapa (change set revisado antes de executar). `RunnerClient` foi apenas **modificado** (sem substituição) — Client ID preservado (`16j350vb5d99u0fbg93b2a2dpk`).
  - `GoogleIdentityProvider`, `FacebookIdentityProvider`, `RunnerPoolDomain` (`runpass-dev`): `CREATE_COMPLETE`.
  - Hosted UI disponível em `https://runpass-dev.auth.sa-east-1.amazoncognito.com`.
  - Permissão IAM adicionada manualmente pelo usuário no usuário `runpass-dev-rafael`: inline policy `runpass-dev-oauth-secrets-read` (`secretsmanager:GetSecretValue` nos dois segredos, least privilege).
  - **Incidente registrado**: as duas primeiras tentativas de deploy falharam porque os Secrets foram criados com apenas uma linha (o nome da chave de um campo preenchido com o valor do outro, ex. "Secret key" = Client ID em vez de literalmente `client_id`). Corrigido pelo usuário reabrindo cada Secret, adicionando a segunda linha e renomeando as chaves para `client_id`/`client_secret` (Google) e `app_id`/`app_secret` (Facebook).
  - **Incidente de segurança**: durante o diagnóstico, um print de tela (`Secrets_Manager_AWS_Google.png`) expôs o Client Secret do Google em texto puro, salvo em `Downloads` e em `mobile/template-frontend/template-cadastro/` (pasta do repositório, não commitada). Orientado a apagar o arquivo das duas pastas e considerar regenerar o Client Secret no Google Cloud Console (ele já havia sido colado uma vez no chat antes, nesta é a segunda exposição).

## Progresso (Fase 4 — mobile)

Concluído em 26/11/2026 (local, sem `.apk` nem commit, conforme restrição do usuário):

- `mobile/pubspec.yaml`: duas dependências novas — `flutter_web_auth_2` (navegador do sistema para a Hosted UI) e `font_awesome_flutter` (ícones de marca Google/Facebook; versão `^11.0.0`, a `^10.x` quebra a compilação nesta versão do Flutter porque `IconData` virou uma classe `final` no framework).
- `mobile/lib/identity_gateway.dart`: `sendForm`/`FormTransport` (POST `x-www-form-urlencoded`, exigido por `/oauth2/token`, diferente do JSON do resto do Cognito), `WebAuthLauncher` injetável (mesmo padrão de `transport`/`byteTransport`/`sleeper`, testável sem navegador real), campos novos no `IdentityGateway` (`hostedUiDomain`, `oauthRedirectScheme`, `webAuth`) e o método `signInWithProvider(String provider)` — Authorization Code flow completo (abre a Hosted UI, troca `code` por tokens, grava `access_token`/`refresh_token` igual ao `signIn` normal).
- `mobile/lib/main.dart`: `main()` lê o `--dart-define` opcional `RUNPASS_COGNITO_HOSTED_UI_DOMAIN`; método `signInWithSocialProvider(provider)` (mesmo `perform()`/`resume()` do login normal — um federado sem perfil cai em `Step.profile` automaticamente, cobrindo o caso "sem gender/birthDate garantidos" sem código extra); dois círculos (`_SocialCircleButton`, 48px, ícones Google/Facebook via `FaIcon`, mesmo idioma visual do botão de voltar do cadastro) centralizados na tela **Criar conta** (`Step.signUp`), acima do campo de e-mail, com um divisor "ou" — só aparecem se `hostedUiDomain` estiver configurado (hoje, só DEV).
- `mobile/android/app/src/main/AndroidManifest.xml`: `CallbackActivity` do `flutter_web_auth_2` registrada para o esquema `runpass://`.
- Verificado: `flutter analyze` limpo, `dart format` aplicado, suíte completa (490 testes) passando.
- **Não verificado ainda**: fluxo de ponta a ponta contra a Hosted UI real em DEV (precisa rodar o app com os 4 dart-defines, incluindo `RUNPASS_COGNITO_HOSTED_UI_DOMAIN=https://runpass-dev.auth.sa-east-1.amazoncognito.com`); iOS (`Info.plist`) não foi tocado — sem build iOS em andamento, conforme escopo do slice.

## Primeiro teste manual (26/11/2026, APK v69) e ajustes (APK v70)

Resultado do primeiro teste de ponta a ponta:
- **Facebook**: tocar o botão abriu a pagina de login do Facebook (e-mail/senha) corretamente — fluxo nao foi concluido ate o fim nesse teste (nao confirmado o retorno pelo deep link).
- **Google**: mensagem de erro, depois tela de autenticacao; apos confirmar, ficou carregando e nunca voltou ao app; o usuario acabou entrando por "acesso rapido" (sessao salva/biometria de um login anterior), nao pelo Google.

Diagnostico (sem acesso a um dispositivo real nesta sessao, so inspecao de infra):
- `aws cognito-idp describe-user-pool-client` confirma `CallbackURLs`, `AllowedOAuthFlows`, `AllowedOAuthScopes` e `SupportedIdentityProviders` corretos.
- `curl` no endpoint `/oauth2/authorize` do Cognito, para os dois provedores, redireciona certo: Google -> `accounts.google.com` com o Client ID certo e `redirect_uri=https://runpass-dev.auth.sa-east-1.amazoncognito.com/oauth2/idpresponse`; Facebook -> `facebook.com` com o mesmo padrao. Ou seja, **o lado Cognito/AWS esta correto e identico para os dois provedores** — a diferenca de comportamento não vem daqui.
- O `AndroidManifest.xml` com o `CallbackActivity` do `flutter_web_auth_2` foi confirmado presente no manifest mesclado do APK (`build/app/intermediates/packaged_manifests/release/.../AndroidManifest.xml`).
- **Hipotese mais provavel para o travamento no Google**: o OAuth consent screen do projeto "RunPass DEV" no Google Cloud Console esta em modo **Testing** (decisao da Fase 1) — nesse modo, só contas cadastradas em **Test users** conseguem concluir o login; qualquer outra conta recebe o aviso "App not verified"/"access_denied" (a "mensagem de erro" relatada) e, mesmo insistindo, o fluxo não finaliza. A "demora depois de confirmar" e o "não voltou" são consistentes com o Google nunca completar o redirect de volta ao Cognito nesse caso. **Verificar**: Google Cloud Console → APIs & Services → OAuth consent screen → Test users — adicionar a conta usada no teste.
- O "avançou com acesso rápido" é o auto-restauro de sessão existente do app (`restoreSession()` em `initState`, baseado em "manter conectado") — comportamento normal e não relacionado ao login social; só dá essa impressão porque, ao reabrir o app depois de desistir do Google, uma sessão salva de um login anterior (e-mail/senha) ainda estava valida nesse aparelho.

Ajustes aplicados nesta rodada (APK v70):
- Ícones trocados de `font_awesome_flutter` para os PNGs oficiais fornecidos (`Google_icon.png`, `Facebook_icon.png`, copiados para `mobile/assets/icons/google-icon.png` e `facebook-icon.png`); dependência `font_awesome_flutter` removida (não usada em mais nenhum lugar).
- `_SocialCircleButton` reduzido (36px, antes 48px), fundo neutro bem sutil (preto/branco translúcido conforme o tema) sem borda — adequado a logomarcas PNG com fundo transparente, em vez do círculo com borda usado antes para ícones de fonte.
- `flutter analyze`, `dart format` e suíte completa (490 testes) — todos passando após a troca.

## Ajuste de tamanho/proporção dos ícones (APK v71, 26/11/2026)

Usuário reportou os ícones pequenos demais e o do Google menor que o do Facebook, mesmo com o mesmo tamanho de botão. Causa raiz identificada por inspeção dos PNGs (`Pillow`, bounding box do canal alfa): o `Google_icon.png` fornecido tem uma tela 946×532 com o "G" ocupando só ~30% da área (muita margem transparente nas laterais); o `Facebook_icon.png` (540×540) ocupa ~62%. Com `BoxFit.contain` numa caixa do mesmo tamanho, o Google sempre renderizava visualmente menor.

Correção: os dois PNGs em `mobile/assets/icons/` foram recortados para a área de conteúdo visível (bounding box do alfa) mais uma margem uniforme pequena, deixando os dois com preenchimento proporcional equivalente (413×421 e 462×459, quase quadrados). `_SocialCircleButton` aumentado de 36px para 44px. `flutter analyze`/`format`/testes (490) confirmados passando.

## Próximos passos

1. ~~Criar credenciais OAuth (Google e Facebook) para DEV.~~ Concluído.
2. ~~Infra: estender `infra/identity.template.json`.~~ Concluído.
3. ~~Deploy do `infra/identity.template.json` em DEV.~~ Concluído em 26/11/2026.
4. ~~Mobile: botões Google/Facebook + fluxo Hosted UI.~~ Concluído em 26/11/2026 (local); ajustes visuais na rodada seguinte (v70).
5. **Pendente, bloqueando o teste do Google**: usuário verificar/ajustar a lista de Test users no OAuth consent screen do Google Cloud Console (projeto "RunPass DEV").
6. Backend: confirmar tratamento de usuários federados sem senha e sem `gender`/`birthDate` garantidos pelo provedor na Lambda de admissão.
7. Reteste manual de ponta a ponta em DEV com o APK v70 (Google com conta de teste cadastrada; Facebook até o fim do fluxo); aceite humano separado (mesmo padrão de S09). Sem commit até aprovação do usuário (APK já autorizado a cada rodada).
