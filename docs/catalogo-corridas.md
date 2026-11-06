# Catalogo de corridas reais (comecando por Sao Paulo)

Mantem a stack existente (FastAPI + DynamoDB). Nada aqui troca banco nem desenho; os dados
sinteticos do DEV continuam ate haver dados reais autorizados para substitui-los.

## Estado em 06/11/2026

| Item | Situacao |
| --- | --- |
| Busca e detalhe (`GET /editions`, `/editions/{id}`) | Ja existia. Ganhou `q` (nome contendo), `registrationStatus`, `lat/lon/radiusKm`. |
| Campos novos da prova | `venue`, `latitude`, `longitude`, `registrationStatus`, `eventStatus`, `lastVerifiedAt`, `sourceCode`, `sourceExternalId` (todos opcionais). |
| Importacao CSV com simulacao | Pronta (`operator_tool import-csv`). |
| Proveniencia e execucoes | `sourceCode`/`sourceExternalId` na prova; cada execucao grava `INGEST#<fonte>/RUN#...` (contadores, sem payload). |
| ACTIVE e Let's Do This | **Conectores escritos e desligados.** Testados so com respostas ficticias. |
| Dados reais de Sao Paulo no DEV | **Nao carregados.** Dependem de CSV autorizado ou de credenciais (abaixo). |

### O que a rede respondeu (testado hoje, sem credencial)
- ACTIVE `GET https://api.amp.active.com/v2/search`: **403 "Developer Inactive"** (precisa de chave ativa).
- Let's Do This `GET https://api.letsdothis.com/marketplace/v1/events/search`: **401** (precisa de token).

Nao ha cobertura de Sao Paulo confirmada em nenhuma das duas. Isso so se sabe com a conta em maos.

## Como carregar provas reais de Sao Paulo (caminho que funciona agora)

1. Obtenha um CSV **autorizado** (organizador, calendario da prefeitura ou parceiro). Modelo ficticio:
   `backend/fixtures/corridas-sp.exemplo.csv` (as linhas dizem `[FICTICIA]`).
   Colunas obrigatorias: `source_external_id,name,event_date,city,state,distances_km`.
   Opcionais: `country,registration_status,event_status,official_url,registration_url,organizer_name,description,venue,latitude,longitude,last_verified_at`.
   Distancias separadas por `;` (aceita `5`, `10 km`, `21,0975`).
2. Valide sem AWS e sem gravar:
   ```
   PYTHONPATH=backend .venv/bin/python scripts/operator_tool.py import-csv \
     --file minhas-provas-sp.csv --source-code csv-sp --offline
   ```
3. Simule contra o catalogo do DEV (login de operador com MFA, nao grava):
   ```
   AWS_PROFILE=runpass-dev-sa PYTHONPATH=backend .venv/bin/python scripts/operator_tool.py \
     import-csv --username <operador> --file minhas-provas-sp.csv \
     --source-code csv-sp --origin https://fonte.exemplo.org/calendario --dry-run
   ```
4. Com a simulacao limpa e **autorizacao para escrever no DEV**, repita sem `--dry-run`.

Regras do importador:
- Reimportar o mesmo arquivo nao cria versao (conteudo e origem iguais); conteudo alterado publica a proxima versao.
- Prova que ja existe de **outra fonte ou cadastrada por administrador nunca e sobrescrita** (`needs_review`).
- Prova nova com mesmo nome, data e cidade de outra ja publicada vai para revisao, sem mescla automatica.
- Prova que some de uma coleta nao e apagada nem marcada como cancelada.
- `registrationStatus` ausente significa desconhecido; o app nunca diz "inscricoes abertas" sem a fonte informar.

## Como ligar um conector (so com credencial e autorizacao)

Pre-requisitos que **nao** estao cumpridos: chave/token validos, termos que permitam o uso comercial e a
exibicao dos dados, e uma amostra real de resposta que confirme o formato e a cobertura de Sao Paulo
(os mapeadores foram escritos pela documentacao publica e precisam ser conferidos com essa amostra).

```
export RUNPASS_SOURCE_ACTIVE_ENABLED=true
export RUNPASS_SOURCE_ACTIVE_KEY=...        # nunca no Git, no app ou em log
AWS_PROFILE=runpass-dev-sa PYTHONPATH=backend .venv/bin/python scripts/operator_tool.py sync-source \
  --username <operador> --source active --origin https://developer.active.com \
  --state SP --city "Sao Paulo" --query corrida --dry-run
```
(`letsdothis` usa `RUNPASS_SOURCE_LETSDOTHIS_ENABLED` e `RUNPASS_SOURCE_LETSDOTHIS_TOKEN`.)
Sem a flag ou sem a credencial o comando para antes de qualquer chamada de rede. 401/403 nao repete;
429/5xx/rede repetem com recuo exponencial e jitter. Falha numa fonte nunca afeta a busca interna.
Itens sem distancia sao descartados (o cadastro exige ao menos uma).

Nao ha execucao agendada: a sincronizacao e manual pelo operador. Agendar (EventBridge + Lambda) fica
para quando houver fonte habilitada, credencial no Secrets Manager e orcamento aprovado.

## Limites conhecidos
- `q`, `registrationStatus` e raio filtram o **resultado** de cada pagina (ate 500 itens avaliados por chamada); nao ha indice novo. Serve para o volume do MVP; medir antes de ampliar.
- Ordenacao continua por data (ou nome quando so ha prefixo). `date_desc`/`name_asc` do documento original nao foram feitos.
- Provas fora do Brasil: `state` continua exigindo UF de 2 letras.
- A revisao de duplicatas (`needs_review`) hoje so aparece no relatorio da importacao; nao ha tela.
- Remocao/despublicacao a pedido usa o arquivamento administrativo ja existente (`/admin/editions/{id}/archive`).
