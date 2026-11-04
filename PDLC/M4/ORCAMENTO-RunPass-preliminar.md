# RunPass — Estimativa preliminar de custos

Atualizado em 27/10/2026 com tarifas coletadas em 26/10/2026, sem nova consulta. Lake incluido como sensibilidade: evento de 4 KB por chamada de escrita (20% das chamadas), objeto individual, retencao de 60 dias, 5% de reenvios, fila e worker adicional de 256 MB/100 ms. Fracao real de avaliacoes e tamanho dos comentarios nao medidos. Estoque de 60 dias em regime cheio, nao crescimento real do beta.
As novas linhas incluem entrega, PUT e estoque. Nao incluem integralmente escrita adicional de outbox/ledger, reconciliacao, limpeza, consultas administrativas, auditoria e versoes; subtotal continua parcial. Nao sao autorizacao de gastos ou custo final do lake.

**Atualização de 04/11/2026:** os itens excluídos de DEV foram incorporados em `ORCAMENTO-RunPass-DEV.md`, com câmbio PTAX de 03/11/2026 e teto de R$ 1.000/mês (aprovado em 01/11/2026). Este documento continua válido como base de PROD, que segue sem cálculo próprio.

**Estado:** simulação de sensibilidade, sem teto aprovado. Preços públicos consultados em 26/10/2026, São Paulo. USD, mês de 30 dias. Não é orçamento final nem benchmark.

## Premissas e cobertura

Base: documento de premissas de uso. Valores brutos sem gratuidades/créditos. Cognito Lite é hipótese de preço, não plano escolhido. Estoque no fim do período usado como envelope conservador de mês cheio; não confundir com média de crescimento do beta.

As RRUs/WRUs abaixo são sensibilidade agregada (4 RRUs e 2,4 WRUs por chamada), NÃO cálculo definitivo do esquema. Tamanho dos itens, índices e acessos ainda precisam de validação; o calculador da skill DynamoDB deve ser aplicado ao modelo completo após essa revisão. Esta simulação não o substitui.

Workers: evento em 20% das chamadas; publicador e consumidor sem lotes, 5% de entregas adicionais, 256 MB/100 ms. Validação de foto 1 GB/1 s e duas escritas S3 por upload. São hipóteses novas, não medições. Polling vazio e reconciliador ainda não modelados.

## Linhas mensais estimadas

| Componente | DEV | PROD econômico | PROD esperado | PROD pico |
| --- | ---: | ---: | ---: | ---: |
| API HTTP | US$ 0.10 | US$ 0.10 | US$ 0.94 | US$ 7.87 |
| Lambda HTTP e workers | US$ 0.19 | US$ 0.24 | US$ 1.84 | US$ 14.82 |
| DynamoDB consumo (sensibilidade) | US$ 0.18 | US$ 0.20 | US$ 1.78 | US$ 14.85 |
| DynamoDB estoque e PITR | US$ 0.68 | US$ 1.35 | US$ 1.35 | US$ 1.35 |
| S3 estoque e requisições | US$ 0.10 | US$ 0.28 | US$ 0.73 | US$ 2.54 |
| Transferência de imagens | US$ 0.75 | US$ 1.28 | US$ 10.77 | US$ 76.95 |
| SQS (3 operações/evento e 5% adicional) | US$ 0.02 | US$ 0.02 | US$ 0.15 | US$ 1.25 |
| Logs (ingestão) | US$ 0.90 | US$ 0.90 | US$ 2.70 | US$ 9.00 |
| Cognito Lite bruto (plano não aprovado) | US$ 0.05 | US$ 5.50 | US$ 5.50 | US$ 5.50 |
| Lake S3 estoque e PUT | US$ 0.09 | US$ 0.10 | US$ 0.91 | US$ 7.60 |
| Lake fila e worker de entrega | US$ 0.02 | US$ 0.03 | US$ 0.23 | US$ 1.89 |
| **Subtotal modelado** | **US$ 3.07** | **US$ 10.00** | **US$ 26.91** | **US$ 143.62** |

## DEV + PROD e reserva provisória

| Cenário | Subtotal somado | Com reserva provisória de US$ 25/mês | Com reserva e 30% de contingência |
| --- | ---: | ---: | ---: |
| Econômico | US$ 13.07 | US$ 38.07 | US$ 49.49 |
| Esperado | US$ 29.98 | US$ 54.98 | US$ 71.47 |
| Pico | US$ 146.69 | US$ 171.69 | US$ 223.20 |

A reserva de US$ 25 e a contingência de 30% são envelopes propostos para planejamento, não preços oficiais, garantia de suficiência ou orçamento aprovado.

## Exclusões e riscos de subestimação

Não precificados individualmente: armazenamento/consulta de logs, métricas e alarmes, auditoria, segredos/KMS, DNS/domínio, hospedagem do painel, artefatos, minutos do GitHub Actions, contas das lojas, comunicação por e-mail, restauração, S3 versionado/temporários, tráfego de respostas da API e de outros objetos, testes de carga, impostos e câmbio. A reserva não comprova sua cobertura. Serviços como NAT, WAF ou CDN só entram se adotados e exigem recálculo.

PITR não é precificado proporcionalmente a 7/35: usar tarifa de armazenamento correspondente, sem presumir economia linear de retenção. Custos de restauração não incluídos. Unidades de armazenamento/tráfego precisam ser alinhadas às convenções de medição de cada serviço no orçamento final.

Não somar os três cenários. Para os 60 dias, não duplicar estoque de imagens; recalcular crescimento e admissão por mês. O cenário de pico representa mês inteiro com uso intenso, não apenas um instante.

## Evidência e reprodução

Preços filtrados preservados em AWS-PRECOS-SA-EAST-1.json, com URL e data de publicação do catálogo. Script calcular_orcamento_runpass.py gera relatório e JSON. Nenhuma credencial, Cost Explorer, recurso AWS ou cobrança foi acessado/criado.

Endpoints: https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/{service}/current/sa-east-1/index.json ; serviços AWSLambda, AmazonApiGateway, AmazonDynamoDB, AmazonS3, AWSQueueService, AmazonCloudWatch, AmazonCognito e AWSDataTransfer.

Próximo passo: revisar atributos e acessos, modelar linhas excluídas e comparar com consumo medido em DEV antes de fixar teto ou configurar PROD.
