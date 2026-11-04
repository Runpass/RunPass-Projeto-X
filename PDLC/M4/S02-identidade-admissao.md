# S02 — Identidade, perfil e admissão

Data: 28/10/2026. Estado: **implementação local em revisão**, sem aceite humano ou integração real AWS. Autorização: usuário solicitou seguir para S02 após aceitar S01.

## Entrega

Backend Python/FastAPI implementa nove operações: PUT/GET/PATCH/DELETE /me, GET /beta/status, POST /beta/admissions, POST /beta/waitlist e GET/DELETE /me/waitlist. Contrato canônico 0.8.0-draft preservado; endpoint de login/senha continua no Cognito. Default da API é fechado, sem dependências configuradas.

Perfil inicial exige identidade/e-mail confirmados, normaliza username, reserva nome e perfil no mesmo commit. PATCH exige admissão, versão e reserva/liberação atômica; não aceita nascimento, papel ou campos desconhecidos. API retorna allowlist e erros sem ecoar nascimento/corpo/tokens. Exclusão marca conta indisponível e registra controle pseudonimizado e job na mesma transação; token anteriormente aceito perde acesso pela consulta ao estado atual.

Admissão valida idade completa em America/Sao_Paulo e declaração explícita; reserva por identidade, contador e marco do 50º são transacionais. Teto de mil nunca é decrementado por exclusão. Espera exige ação voluntária depois do teto, sem admissão ou posição prometida. Idempotência de sete dias preserva invariantes depois da expiração; replay de saída antiga não remove nova inscrição voluntária.

Autenticação valida RS256/JWKS conhecido, assinatura, issuer, client_id, token_use=access, exp/iat/sub e estado corrente de atributos Cognito. Outros clients/pools/ID tokens/assinaturas inválidas são recusados. Operadores usam verificador separado, permissão atual e sessão exata emitida somente após desafio TOTP concluído. Template CloudFormation prepara pools/clients separados, TOTP e recuperação restrita; nenhum recurso foi criado.

Mobile Flutter tem cadastro, confirmação/reenvio de código, login, recuperação de senha, preenchimento de perfil, admissão, espera e saída da espera. Usa HTTPS, não segue redirects no transporte, mantém token apenas em memória e reutiliza chave de idempotência em retry do comando. Token expirado/inválido exige novo login; não há persistência de sessão ou refresh automático nesta primeira implementação. Catálogo ainda não existe. Nenhuma senha vai para API RunPass ou armazenamento local.

## Verificações

Comandos reproduzíveis: `make check` (Ruff, contrato, unittest e cfn-lint) e `make mobile-check` (análise/formatação/testes Flutter). SDK e dependências fixadas no lock atualizado. Resultados locais: 25 testes backend e cinco testes Flutter passaram; Ruff, formatação, OpenAPI e cfn-lint também passaram. O contrato preserva 39 exemplos e 64 combinações de filtros aceitas. A verificação final do ambiente usou os comandos e lock descritos abaixo.

Testes backend cobrem fluxo HTTP validado pelos schemas canônicos, dados inválidos/privados, identidades distintas, usernames concorrentes, versões, resposta perdida/idempotência, transições 50/1000, início/fim da janela, idade na virada do dia local, espera/remoção/reentrada e bloqueio após exclusão. JWTs são assinados com RSA gerada no teste. Sessões de operador são testadas com respostas Cognito sintéticas; nenhuma chamada de autenticação real foi feita. Adaptador DynamoDB usa leitura forte e TransactWriteItems por versão, com requests interceptadas por Stubber (não é integração).

## Limites antes de habilitar ambiente real

- Concorrência provada no adaptador em memória de um processo; comportamento/latência real DynamoDB continua S09. Modelo e transações não são benchmark.
- Cognito, envio de e-mail, signup/recuperação, MFA/refresh/enrollment e revogação precisam de execução na conta DEV autorizada. Composição AWS existe, mas clientes/configuração/recursos não foram habilitados.
- Worker de limpeza física e remoção Cognito, enumeração de destinos, jobs de descarte, restauração e prova dos prazos pertencem a S08/S09. O job persistido não prova que a limpeza já acontece. Não liberar beta assim.
- Sessões/HMAC, IAM do componente de atestação, segredo estável/versionado, logs, antiabuso e responsáveis operacionais devem ser configurados/verificados antes de ativar administração ou tráfego real.
- Foto de perfil ainda não aceita vínculo não validado; retorna 503 para nova referência até o fluxo de imagem correspondente. Exclusão pelo mobile e demais configurações de conta serão completadas com a jornada S08; DELETE já é verificável na API local.
- Sem builds Android/iOS, simulador ou aparelho nesta etapa; testes Flutter usam transporte sintético. Persistência segura de sessão/refresh não foi implementada; usuário volta a autenticar após reiniciar ou expirar token.
- Retenção ordinária da lista de espera e outros módulos continua pendência de liberação, sem prazo inventado ou dispensa de exclusão pessoal.
- Avisos de depreciação RefResolver e TestClient/httpx não impedem os testes com versões fixadas; migração futura deve preservar os casos de contrato e HTTP.

## Fontes técnicas

Verificadas na implementação: [JWT Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-tokens-verifying-a-jwt.html), [GetUser e scope](https://docs.aws.amazon.com/cognito-user-identity-pools/latest/APIReference/API_GetUser.html), [PyJWT](https://pyjwt.readthedocs.io/en/stable/usage.html), [testes FastAPI](https://fastapi.tiangolo.com/tutorial/testing/), [CloudFormation UserPool](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-cognito-userpool.html) e [UserPoolClient](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-cognito-userpoolclient.html). Escolhas e limites locais acima são do RunPass, não comprovação pelo provedor.

Sem provisionamento, custo AWS, deploy, commit, push ou publicação. Próximo slice técnico: S03, catálogo protegido usando a autorização/admissão corrente.


## Registro de execução

Ambiente Python isolado já utilizado na S01, `/private/tmp/runpass-s01-validation-venv`, atualizado pelas dependências fixadas em requirements-dev.lock. Comandos: `make check PYTHON=/private/tmp/runpass-s01-validation-venv/bin/python RUFF=/private/tmp/runpass-s01-validation-venv/bin/ruff CFN_LINT=/private/tmp/runpass-s01-validation-venv/bin/cfn-lint` e `make mobile-check`. Execuções locais concluídas sem credenciais reais. Instalador/SDK precisaram de acesso à rede/cache do ambiente, sem alteração de versão Flutter e sem serviços pagos. `pip check` e `git diff --check` integram a conferência final.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas e pendências registradas em `implementation-slices.md` (seção "Aceite humano de S02, S03 e S04"). Integração real permanece na S09.
