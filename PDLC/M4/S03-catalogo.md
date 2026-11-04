# S03 — Catálogo inicial consultável

Data: 28/10/2026. Estado: **implementação local em revisão**. Usuário autorizou o próximo slice após S02 local e solicitou continuar depois do bloqueio de armazenamento. Sem aceite humano do slice ou integração AWS real.

## Entrega

- GET /editions e GET /editions/{id} exigem identidade atual, conta ativa e admissão; acesso é revalidado antes de responder. Bootstrap não concede catálogo.
- Seis filtros combináveis da S01: início do nome, cidade, UF, distância Decimal e intervalo de datas. Comparação de nome/cidade ignora caixa/acentos e colapsa espaços; UF normalizada em maiúsculas. Datas e distâncias inválidas retornam 422.
- Paginação por data ou título conforme o plano, padrão 20/máximo 100, com teto de 500 candidatos por resposta e continuação mesmo em página vazia. Cursor cifrado/autenticado, vinculado a ator/ambiente/rota/filtros/limite, expira em 15 minutos. Mudança concorrente não é snapshot; fonte ativa sempre revalidada.
- Detalhe preserva distâncias, referências oficiais disponíveis e estado de arquivamento. Data futura passa a passada por data local São Paulo, sem arquivamento automático. Guard de conclusão rejeita edição arquivada; S04/S06 precisam condicionar o commit ao HEAD vigente, não apenas chamar o guard antes.
- Não há score/contagem fictícios: cliente e importador não definem RunScore/participantCount. Projeções pertencem à S07. Imagem oficial só é vinculada se registro privado estiver valid/admin, no mesmo ambiente/destino, com incremento de referências no commit.

## Carga e manutenção controladas

`CatalogImporter.put` é operação interna, sem rota HTTP de bypass. Carga não sintética exige operador com catalog_admin, sessão MFA exata e acesso atual; fonte HTTPS obrigatória e revisão/auditoria registradas. Autorização condiciona início, lotes e ativação. Cada versão imutável reserva um slot e manifesto dos índices. A geração anterior permanece ativa até todos os lotes novos estarem persistidos/verificados; falhas são retomadas com o mesmo conteúdo. Mudança concorrente ou conteúdo divergente para mesma versão retorna conflito.

Manifesto permanente contém referência de revisão e datas, não copia identidade do revisor. Ator fica na auditoria com retenção administrativa de 90 dias, sujeita à política de exclusão e aos jobs ainda a implementar em S08/S09. Origem e auditoria não são devolvidas no catálogo público. `retire_indexes` remove somente índices de versão substituída, guardando HEAD/versão e autorização na transação; mantém snapshots de catálogo/imagens referenciadas. Agendamento e reconciliação operacionais serão fechados antes de DEV.

Fixture `backend/fixtures/catalog.synthetic.json` contém cinco edições fictícias, incluindo histórico, futura, outra cidade/UF e arquivada; sem imagens inventadas. `make catalog-seed` carrega duas vezes em MemoryStore e lista IDs, demonstrando carga local idempotente sem AWS. Essa rota de seed recusa DynamoStore. Carga real precisa de origem/revisão da equipe e não foi executada; fixture não comprova cobertura de 90%.

## Mobile e demonstração

`CatalogScreen` oferece filtros, lista, continuação, erros e detalhe atualizado da edição; usuário pode selecionar uma distância. Edição arquivada mantém detalhe e desabilita seleção para novo registro. A seleção ainda não cria rascunho, que pertence à S04. Consultas preservam eventual prefixo de stage na URL da API e codificam query parameters separadamente.

A pedido de testar no simulador, foi preparada entrada separada `lib/main_demo.dart`, somente debug, com banner visível de demonstração e dados fictícios. Ela usa transporte inteiramente em memória, sem rede ou AWS; não exercita backend, concorrência real, tokens Cognito ou persistência real. Dados reiniciam ao encerrar/reiniciar o processo. A entrada real `lib/main.dart` continua fechada sem configuração; nenhum parâmetro de PROD habilita a demonstração.

Comando: `flutter run --debug -t lib/main_demo.dart -d <id-do-simulador>`, dentro de mobile. Conta fictícia inicial: demo@runpass.test / RunpassDemo123!. Novo cadastro deve usar e-mail fictício terminado em .test; confirmação/recuperação usa código 123456. O catálogo demonstrativo tem 24 provas fictícias para testar segunda página e filtros. Não inserir dados pessoais reais nessa demonstração.

## Evidências locais

50 testes backend passaram, incluindo as 64 combinações de filtros sobre dados sintéticos (conjunto completo, sem duplicatas), normalização, cursores adulterados/expirados/trocados entre usuários, limites de leitura/página vazia, fonte/versão atual, carga interrompida com mais de 100 linhas, retomada, arquivamento, limpeza de índices antigos, revogação administrativa e referências validadas. HTTP responde conforme Edition/EditionPage canônicos. Stubber verifica Query por partição com ConsistentRead, limite e ExclusiveStartKey; não é execução real DynamoDB.

Testes Flutter cobrem query parameters com stage, página vazia/continuação, filtros, detalhe/seleção, arquivo e erro de autorização; testes da demonstração percorrem login→perfil→admissão→catálogo e confirmação/recuperação. Resultado da rodada final completa consta no registro de execução ao final. Erros de rolagem dos testes foram corrigidos usando o Scrollable do catálogo e alvo visível, sem ignorar warnings de toque.

OpenAPI canônico 0.8.0-draft preservado: implementação das duas operações já contratadas, sem nova rota ou alteração de schema. `make check` valida Ruff/formatação, os 39 exemplos de contrato/64 combinações de parâmetros, testes backend e cfn-lint do template de identidade inalterado. Dependências reinstaladas no ambiente temporário `/private/tmp/runpass-s03-venv` a partir do mesmo lockfile, sem mudar versões. `make mobile-check` executa análise, formatação e testes mobile; `make catalog-seed` exercita a fixture.

## Ambiente e limites

O bloqueio anterior de disco (100–130 MB livres, erro de gravação e timeout 60 na leitura) foi resolvido antes da retomada: verificados cerca de 23 GB livres e arquivos legíveis. Somente artefatos descartáveis do projeto foram limpos; nenhum dado pessoal ou dispositivo foi apagado por essa limpeza.

Para testar as APIs sem depender do simulador, foi adicionado um harness restrito ao loopback com chaves RSA efêmeras, tokens sintéticos e os serviços reais Python de S02/S03 sobre MemoryStore. `make api-local` gera coleção/ambiente Bruno e uma cópia OpenAPI limitada às 11 operações implementadas para importação no Insomnia. Os 12 requests salvos foram executados automaticamente contra o app ASGI, incluindo sucessos, conflito de versão e validações 422; também houve smoke HTTP real em `127.0.0.1`. Isso não equivale à UI dos clientes nem à integração Cognito/DynamoDB/AWS.

Sem AWS real, benchmark, prova de MFA/autorizações IAM em serviços reais, cobertura de catálogo real ou release. Imagens pessoais/oficiais e download de bytes pertencem aos caminhos S05/administrativo; S03 usa referências previamente validadas quando fornecidas. Provas de concorrência/latência/restore e custos de linhas, leitura, versões, auditoria e limpeza continuam necessárias em DEV/S09 antes de beta. Não há provisionamento, deploy, commit, push ou publicação por este slice. Próximo slice: S04, rascunho de participação.

## Fontes técnicas

Plano segue a [Query DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html) (partição, ordenação, limite/continuação) e usa [Fernet](https://cryptography.io/en/latest/fernet/) para cursores cifrados/autenticados com prazo. São mecanismos implementados localmente; documentação de provedor não comprova implantação, custo ou desempenho do RunPass.


## Registro final das verificações

- `make check` com o ambiente `/private/tmp/runpass-s03-venv`: Ruff/formatação, OpenAPI (39 exemplos/64 combinações de parâmetros), 50 testes backend e cfn-lint passaram. `make catalog-seed` passou e confirmou cinco IDs sintéticos após carga repetida.
- `make mobile-check`: análise sem problemas, formatação e 12 testes Flutter passaram (cinco de identidade, cinco de catálogo, dois de demonstração).
- Build nativo debug para iOS Simulator a partir da cópia em `/private/tmp/runpass-ios-demo`: concluído com sucesso em 166,3 s. Isso é build de demonstração, não release ou integração AWS.
- Diagnóstico pela skill diagnosing-bugs: build original falhava com status 255; minimizado para `codesign --force --sign - --timestamp=none` no Flutter.framework gerado, que falhava com “resource fork, Finder information, or similar detritus not allowed”. Mesma assinatura numa cópia sem atributos fora de Documents passou. Build completo na cópia temporária também passou. Não há teste unitário que comprove esse comportamento do filesystem/codesign; o smoke nativo e `scripts/run-ios-demo.sh` são a reprodução operacional. Sem mudança de regras do app para contornar assinatura.
- Runtime iOS 27.1 baixado novamente com autorização explícita (7,85 GB), registro antigo tratado sem apagar dados do dispositivo e serviço CoreSimulator atualizado. `simctl bootstatus` confirmou iPhone Duo inicializado. Pacote temporário exportado e probe de assinatura foram removidos depois do uso; runtime instalado preservado.
- `scripts/run-ios-demo.sh` passou por `bash -n`; os comandos equivalentes de cópia/build foram executados e verificados nesta sessão. Diagnóstico detalhado permaneceu somente em arquivo temporário, sem credenciais de produção ou logs de autenticação reais.

Instalação/abertura no dispositivo são registradas separadamente após retorno do simctl; build concluído não é usado como prova de app aberto. Sem aceite humano do slice ou liberação de beta.


## Verificação visual do simulador — diagnóstico parcial

No iPhone Duo/iOS 27.1, instalação e launch do app debug foram aceitos pelo simctl, mas capturas do app e dos Ajustes ficaram pretas; o usuário confirmou o comportamento. A compatibilidade desse runtime se limita ao Duo. Foi então instalado iOS 27.0 arm64 e criado `RunPass iPhone 17 Pro`. Nesse dispositivo, capturas renderizam o boot e a SpringBoard corretamente, eliminando o defeito de display preto. O app foi instalado e o launch retorna PID, mas permanece em tela branca em paisagem e o comando de launch demora anormalmente. Portanto o runtime/dispositivo foi recuperado, mas a interface nativa do RunPass ainda não foi aceita; a próxima investigação deve coletar logs do processo/Flutter durante essa inicialização. Testes de widget e build concluído não substituem essa confirmação.

Revisão adicional do importador detectou que uma versão esperada futura poderia reservar um slot órfão antes de retornar conflito. A verificação passou a ocorrer antes da reserva; regressão demonstra ausência de mutação. Total atualizado: 50 testes backend aprovados.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas e pendências registradas em `implementation-slices.md` (seção "Aceite humano de S02, S03 e S04"). Integração real permanece na S09.
