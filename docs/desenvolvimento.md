# Desenvolvimento local

## Ferramentas e estrutura

Linha de base S00: Python 3.11.4, Flutter 3.47.7 stable e Dart 3.13.5. Confira com `python3 --version`, `flutter --version` e `flutter doctor -v`. `.python-version` registra Python; `mobile/pubspec.yaml` fixa Flutter e o mínimo Dart.

- `backend/`: módulos Python e testes a criar após S01.
- `mobile/`: projeto Flutter Android/iOS com tela mínima.
- `infra/`: destino dos templates CloudFormation.
- `PDLC/M4/`: SPEC única, contrato, desenho e evidências.

## Python

Na raiz:

```sh
make setup
make check
```

O setup cria `.venv` e instala `requirements-dev.lock`, com dependências transitivas fixadas. Requer rede na primeira instalação. `requirements-dev.in` registra dependências diretas; atualizações exigem instalação em ambiente limpo, regeneração com `.venv/bin/python -m pip freeze > requirements-dev.lock` e nova verificação.

`make check` executa Ruff, validação OpenAPI, testes backend e cfn-lint do template de identidade. `make format` aplica formatação/correções. `make contract` executa apenas o contrato e atualiza `PDLC/M4/VALIDACAO-OPENAPI-RunPass.json`. O script resolve os arquivos pelo próprio diretório.

O contrato verifica estrutura, referências, operações únicas, parâmetros de rota, metadados administrativos e 12 exemplos válidos/inválidos, incluindo oito notas obrigatórias e rejeição de e-mail no perfil público. Usa dados sintéticos embutidos e não acessa AWS. O script utiliza `assert`; execute sem `-O` e sem `PYTHONOPTIMIZE`.

A S02 acrescenta testes em `backend/tests`: execute `make test` para regras, JWT, HTTP e adaptadores, com `PYTHONPATH=backend` definido pelo Makefile. `MemoryStore` é local a um processo; threads e Stubber não comprovam comportamento AWS real. O contrato separado continua sem executar API. Instalação de runtime sem ferramentas de teste: `python -m pip install -r backend/requirements.in -c requirements-dev.lock`.

## Mobile

```sh
make mobile-setup
make mobile-check
cd mobile
flutter run
```

Versionar `mobile/pubspec.lock`. O setup exige o lock; mudanças intencionais de dependências usam `flutter pub get` e revisão do diff. Flutter escreve no cache do SDK e pub fora do repositório; ambientes restritos precisam permitir esse acesso ou usar SDK/cache gravável.

`mobile-check` executa análise estática, formatação e os testes de gateway/widgets da identidade S02. O transporte dos testes é sintético; não há login real AWS nos testes locais. Configurar Android SDK/emulador e Xcode/CocoaPods para builds e dispositivos. Análise estática não comprova build ou execução em Android/iPhone.

`br.com.runpass.runpass` é identificador provisório do scaffold, sujeito à confirmação antes de lojas, Cognito ou links. Não há assinatura de distribuição ou integração AWS; o template Android usa assinatura debug também no build release até configuração própria.

## Isolamento

Use somente IDs, contas, provas e imagens sintéticos. Testes futuros devem controlar relógio, reiniciar estado por caso e usar adaptadores locais sem descobrir credenciais AWS. Integração real fica em suíte separada, explicitamente habilitada para DEV autorizado. Segredos, dados reais, `.env`, `.aws` e chaves ficam fora do Git.

Os comandos de verificação não provisionam AWS nem precisam de credenciais. Para o aplicativo configurado futuramente em DEV: `RUNPASS_API_URL`, `RUNPASS_COGNITO_URL` e `RUNPASS_COGNITO_CLIENT_ID` são `--dart-define`, com endpoints HTTPS e client público, sem segredo. Sem configuração, o app informa indisponibilidade e não simula conta. A sessão fica apenas em memória e exige novo login após restart/expiração. Exemplo após provisionamento autorizado:

```sh
cd mobile
flutter run --dart-define=RUNPASS_API_URL=https://api.example.test --dart-define=RUNPASS_COGNITO_URL=https://cognito-idp.sa-east-1.amazonaws.com --dart-define=RUNPASS_COGNITO_CLIENT_ID=CLIENT_PUBLICO
```

Os endereços acima são exemplos, não serviços disponíveis. Backend: consulte `backend/README.md` para factory/configuração explícita e comando que falha fechado por padrão. O template Cognito pode ser verificado com `make infra-check` sem aplicar. Principal/substituto e recuperação de operadores: `docs/operadores.md`.

Se o ambiente virtual sob Documents apresentar lentidão ao ler dependências, crie outro fora dessa pasta com os mesmos requisitos: `make setup VENV=~/.cache/runpass/venv` e `make check VENV=~/.cache/runpass/venv`. Registrar caminho e resultados; não confundir troca de diretório com mudança de versões.

## Publicação e branches

O repositório oficial é `Runpass/RunPass-Projeto-X`, com os branches `dev`, `hom` e `main`. Todo envio vai para `dev`, por pull request: os rulesets recusam push direto (`GH013`, "Changes must be made through a pull request"). Fluxo: branch de funcionalidade a partir de `runpass/dev`, push para o remoto `runpass` e `gh pr create --repo Runpass/RunPass-Projeto-X --base dev`. Promoção para `hom` e `main` é decisão separada, também por PR. O remoto `origin` aponta para o repositório antigo (`Moura7/RunPass-Projeto-X`) e não recebe mais envios. O workflow `check.yml` roda em pull requests e em pushes para `dev`, `hom` e `main`. Não há workflow de deploy; ele só entra depois dos GitHub Environments com aprovadores (ver `PDLC/M4/S09-integracao-dev.md`).

## Smoke test da jornada

`scripts/smoke_journey.py` percorre a jornada principal por HTTP (status, perfil, admissão, catálogo, rascunho, versão antiga rejeitada, acesso alheio negado, imagem, conclusão com oito notas, avaliação e exclusão) e imprime `APROVADO`, `FALHA` ou `NAO EXECUTADO` por passo, com o tempo. Usa só a biblioteca padrão e dados sintéticos. Os tokens vêm apenas do ambiente (`RUNPASS_ACCESS_TOKEN`; opcionalmente `RUNPASS_ACCESS_TOKEN_OTHER` para o passo do usuário alheio) e nunca são impressos, assim como os corpos das respostas. Exclusão de conta é destrutiva e só roda com `--delete-account`.

```sh
make api-local   # outro terminal; escreve tokens sintéticos em api/bruno/environments/Local.bru
RUNPASS_ACCESS_TOKEN=... .venv/bin/python scripts/smoke_journey.py --base-url http://127.0.0.1:8000
```

Contra o harness local, os passos de imagem e conclusão ficam `NAO EXECUTADO`, porque o armazenamento local não oferece URL de upload HTTPS. Eles só rodam contra DEV autorizado, com URL assinada do S3 e meta de cinco segundos (`--max-image-seconds`). O script não substitui a suíte de testes nem cobre carga, DLQ, restore ou permissões IAM; é o roteiro 1 do `S09-roteiro-e-relatorio.md` em forma executável. Resultados contra DEV entram no relatório da S09 com ID de execução e horário, sem tokens.

## Catálogo S03

`make catalog-seed` cria catálogo e usuário sintéticos somente em MemoryStore, carrega a fixture duas vezes e lista cinco IDs. Não é importação para AWS nem comprovação de cobertura de catálogo. A carga interna não sintética exige catalog_admin + sessão MFA, origem/revisão e versão esperada; não há endpoint público de carga nesta entrega. `CatalogImporter.retire_indexes` retira apenas índices de versão substituída, mantendo a versão imutável e imagens referenciadas. Templates/rotas administrativas integrais continuam para entregas próprias.

A composição AWS pode receber `catalog_table` e `cursor_encryption_key` (chave Fernet base64 de 32 bytes, estável e secreta por ambiente). Sem ambos, catálogo falha fechado. Não gerar chave aleatória a cada inicialização real, pois invalidaria cursores; geração aleatória está restrita ao harness e à demonstração. Nenhum parâmetro do app concede autorização.

## Demonstração visual no simulador

Entrada debug separada, sem rede: `mobile/lib/main_demo.dart`. Banner visível, dados fictícios, estado apenas em memória. E-mail inicial `demo@runpass.test`, senha `RunpassDemo123!` (conta vazia, para o fluxo de cadastro e primeira corrida); `medalhas@runpass.test`, mesma senha, já admitida e com seis corridas concluídas fictícias, para ver Início, Meu Medalheiro e Perfil preenchidos; cadastro fictício `.test`, confirmação/recuperação `123456`. Não testa Cognito ou backend real, não inserir dados pessoais reais. `lib/main.dart` continua a entrada do app real, sem fallback de autenticação falsa.

```sh
cd mobile
flutter run --debug -t lib/main_demo.dart -d ID_DO_IPHONE
```

Xcode 27 usa Device Hub; o runtime iOS precisa estar instalado e o dispositivo deve estar inicializado. Se `codesign` recusar Finder information/resource fork ao compilar dentro de Documents, use na raiz `scripts/run-ios-demo.sh ID_DO_IPHONE`. O script copia os fontes para pasta temporária sem atributos estendidos, compila e instala no simulador, preserva o repositório e remove a cópia de build ao terminar. `FLUTTER` pode indicar o caminho do SDK. Ele não baixa runtimes nem aplica AWS.

## API local com Bruno ou Insomnia

Execute `make api-local`. O servidor escuta somente em `http://127.0.0.1:8000`, usa os serviços reais de S02/S03 com armazenamento em memória e gera ambientes locais com tokens sintéticos. Abra `api/bruno` no Bruno ou importe `.local/runpass-api/RunPass-local.openapi.json` no Insomnia. Instruções completas: [`api/README.md`](../api/README.md).

Esse fluxo não exige simulador nem AWS. O processo reinicia os dados e as chaves ao ser encerrado; os arquivos com tokens são privados, ignorados pelo Git e expiram em uma hora.

