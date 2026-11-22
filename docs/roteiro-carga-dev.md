# Roteiro: teste de carga real no DEV

Estado: **preparado, nada executado contra a AWS.** O script `scripts/load_test.py` foi testado só contra a API local. Cada rodada contra o DEV gera custo e só roda com a **autorização explícita de Thiago e Rafael**, registrada no `PDLC/M4/S09-integracao-dev.md`. Conta DEV `263097734277`, região `sa-east-1`, perfil `runpass-dev-sa`.

O script só faz leituras (GET): Início (três feeds), Avisos, Corridas, detalhe e avaliações da corrida, Medalhas, Perfil, Minhas publicações, Sugestões de amigos e Planos de corrida. Não grava, não apaga e não imprime o token nem o corpo das respostas.

## Antes de rodar: três decisões

1. **Limite de taxa do API Gateway.** `ApiRateLimit` vale 20 req/s e `ApiBurstLimit` 40 (`infra/app.template.yaml`), e nada nos registros da S09 indica que o DEV tenha outro valor. Com isso:
   - a rodada de **20 req/s** fica exatamente no limite e deve receber respostas 429;
   - a rodada de **100 req/s** deve receber 429 em cerca de 80% das chamadas, o que mede o limite e não o código.

   Escolha uma: **(a)** subir os dois parâmetros da stack `runpass-dev-app` só para o teste (change set de UPDATE, revisado pelos dois, e voltar depois); ou **(b)** aceitar que a rodada mede o limite atual. Confira o valor em vigor: `aws apigatewayv2 get-stage --api-id <id> --stage-name '$default' --query DefaultRouteSettings`.
2. **Qual versão medir.** O PR #152 (menos idas ao banco) muda feed, avisos e perfil. Medir antes do deploy dele dá a linha de base; depois, o que vai para o beta. Faça o deploy do #152 primeiro, a menos que queiram os dois números.
3. **Cota de execuções da Lambda.** O app já precisou limitar as chamadas simultâneas por causa da cota de execuções da conta DEV (comentário em `mobile/test/medals_resilience_test.dart`). Confira `aws lambda get-account-settings --query AccountLimit` antes do patamar de 100 req/s.

## Preparo

```sh
export AWS_PROFILE=runpass-dev-sa AWS_REGION=sa-east-1
aws sts get-caller-identity --query Arn --output text    # nunca root
git checkout dev && git pull && make check               # verde no commit medido
```

- **Usuário sintético:** admitido, com perfil, no pool de corredores (`docs/deploy-dev.md`, seção 9, item 2). A admissão pede `birthDate`, `declaresAdult` e `gender`.
- **Token:** obtido pelo mesmo caminho do smoke test, **sem imprimir**, direto na variável de ambiente `RUNPASS_ACCESS_TOKEN`. Confira a validade do token no client do Cognito: o script para se o token for recusado em sequência, e a rodada de 30 minutos precisa de um token que dure.
- **Conferência rápida (sem carga):**
  `python3 scripts/smoke_journey.py --base-url "$APIURL"`
- **Alarme de custo:** confirmar que `runpass-dev-mensal` e o tópico `CriticalAlerts` estão recebendo, e avisar os quatro destinatários de que haverá alarmes durante o teste.

## Rodadas

`--max-requests` é um teto duro de chamadas. O orçamento (`ORCAMENTO-RunPass-DEV.md`, R$ 4,73) conta 192.000 chamadas: cada patamar duas vezes.

```sh
URL=https://<id>.execute-api.sa-east-1.amazonaws.com    # saída ApiUrl da stack runpass-dev-app

# 0. aquecimento e checagem do gerador: 5/s por 60 s
python3 scripts/load_test.py --base-url "$URL" --rate 5 --duration 60 --autorizado --json aquecimento.json

# 1. patamar de 20 req/s por 30 min (36.000 chamadas)
python3 scripts/load_test.py --base-url "$URL" --rate 20 --duration 1800 --max-requests 36000 --autorizado --json carga-20.json

# 2. patamar de 100 req/s por 10 min (60.000 chamadas)
python3 scripts/load_test.py --base-url "$URL" --rate 100 --duration 600 --max-requests 60000 --autorizado --json carga-100.json
```

Rode a rodada 1 inteira e leia o resultado antes da 2. Se o veredito "Gerador de carga" der FALHA, os números daquela rodada não valem: aumente `--workers` ou rode de outra máquina e repita.

## Quando parar

O script para sozinho se, nas últimas 200 respostas, mais de 5% forem erro de servidor ou de rede (`--abort-5xx`), mais de 50% forem 429 (`--abort-429`) ou se o token for recusado dez vezes seguidas. Pare à mão (Ctrl+C) se:

- chegar alarme em `CriticalAlerts` (DLQ, 5xx da API, falha de manutenção);
- o gasto do dia no Cost Explorer passar do previsto para a rodada;
- aparecer `AccessDenied` ou erro que o teste não deveria causar.

Depois de uma parada, registre o motivo e peça nova aprovação antes de repetir.

## O que ler na AWS depois de cada rodada

O script mede o que o app enxerga. A causa de um número ruim está nestas métricas do CloudWatch, na janela da rodada:

- **Lambda `ApiFunction`:** `Duration` (p95), `Errors`, `Throttles`, `ConcurrentExecutions`, e início a frio nos logs.
- **DynamoDB (tabelas da stack de dados):** `ThrottledRequests`, `ConsumedReadCapacityUnits`, `SuccessfulRequestLatency`.
- **API Gateway:** `4xx`, `5xx`, `Latency` e `IntegrationLatency`; a diferença entre as duas mostra o tempo fora da Lambda.
- **Custo:** gasto do dia, comparado com os R$ 4,73 previstos.

## Como registrar

Preencher a linha **Carga** de `PDLC/M4/S09-roteiro-e-relatorio.md` e acrescentar uma entrada em `S09-integracao-dev.md` com: commit e pacote medidos, horário UTC de início e fim, parâmetros de cada rodada, p50/p95/p99 por rota (`--json`), contagem de 429 e de 5xx, custo observado, o que mostraram as métricas acima e a decisão sobre o limite de taxa. Sem token, sem corpo de resposta, sem dado pessoal. Os `.json` do script não têm token; guarde-os com o relatório.

## O que este teste não cobre

- **Só leitura.** Não mede gravações (rascunho, conclusão, curtir, comentar), upload de imagem (meta de 5 s após o upload) nem a projeção do RunScore (meta de 10 s). Esses ficam para um segundo roteiro.
- **Uma conta só.** Todas as chamadas usam o mesmo usuário, então o feed de amigos e as listas ficam pequenos e os caches esquentam mais do que com 200 usuários simultâneos (patamar de pico em `PREMISSAS-USO-RunPass-MVP.md`).
- **Catálogo e dados do DEV são sintéticos e pequenos**, diferentes do volume esperado no beta.
- **Percentis aprovados.** O p95 de 1 s para operações leves e a média abaixo de 500 ms são metas propostas na SPEC, ainda não aprovadas como critério formal. O script as usa como referência.
