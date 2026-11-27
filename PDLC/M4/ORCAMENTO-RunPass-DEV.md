# RunPass — Orçamento do ambiente DEV com os itens antes excluídos

Data: 04/11/2026. Complementa `ORCAMENTO-RunPass-preliminar.md`, que modelava DEV em US$ 3,07/mês e deixava vários itens de fora. Escopo: **somente DEV** (conta `263097734277`, `sa-east-1`). PROD e beta não estão cobertos e exigem aprovação e cálculo próprios.

**Estado:** simulação de sensibilidade com hipóteses explícitas, não benchmark nem custo medido. Não é autorização de gasto: o teto de **R$ 1.000/mês** para DEV já foi autorizado pelo usuário em 01/11/2026 e continua sendo o limite.

## Câmbio e teto

Câmbio: PTAX de venda do Banco Central de 03/11/2026, **R$ 5,4935 por US$** (consulta à API oficial; a PTAX de 04/11/2026 ainda não estava publicada). Com ele, o teto de R$ 1.000 equivale a **US$ 182,03**. Se o dólar subir 20%, equivale a US$ 151,69.

**Decisão de 04/11/2026:** o orçamento `runpass-dev-mensal` (AWS Budgets) passa a ter como limite **30% do teto**, ou seja, **R$ 300, equivalentes a US$ 54,61** com a PTAX acima. Os alertas continuam em 50% e 80% (gasto real) e 100% (previsão), o que dá US$ 27,31, US$ 43,69 e US$ 54,61. O orçamento já inclui impostos no cálculo (`IncludeTax`), o que cobre parte da dúvida sobre tributos.

**Aplicado em 04/11/2026 e verificado na AWS (leitura, conta `thicost`/`runpass-dev-thiago`):** o orçamento `runpass-dev-mensal` está com limite de **US$ 54,61/mês** e os três alertas (50% e 80% do gasto real, 100% da previsão) têm **quatro assinantes cada um**, todos os quatro e-mails definidos (endereços fora do Git). Pela data de início do orçamento, que continua a original (31/10/2026), a mudança foi feita **editando o orçamento no console**, e não pela stack do `infra/cost.template.yaml`.

**Ponto a conferir:** na leitura anterior à edição, o orçamento tinha `IncludeTax: true`. Depois da edição, o campo de tipos de custo não aparece mais na API. Não consegui confirmar se os impostos continuam entrando no cálculo. No console: Budgets → `runpass-dev-mensal` → Edit → opções avançadas, e conferir que **Taxes** (e Support charges) estão marcados.

**Template:** `infra/cost.template.yaml` continua válido e **não aplicado**. Serve como referência versionada e para recriar o orçamento por IaC (excluir o atual antes, para liberar o nome). Enquanto isso, o orçamento é gerenciado manualmente, e qualquer mudança futura deve ser registrada aqui.

**Leitura dos números:** o gasto esperado do DEV (US$ 9,95) usa cerca de 18% do novo limite, e o envelope com reserva e contingência (US$ 45,44) usa cerca de 83%. O alerta de 80% só deve disparar se o consumo chegar perto desse envelope conservador, o que é o propósito dele. O teto de R$ 1.000 continua sendo o limite duro; o orçamento de R$ 300 é o aviso antecipado.

## Linhas mensais de DEV

| Componente | US$ / mês |
| --- | ---: |
| DEV já modelado na estimativa preliminar | 3,07 |
| Alarmes do CloudWatch (4 alarmes padrão a US$ 0,135) | 0,54 |
| Chave KMS própria do tópico de alertas (US$ 1 por chave, mais requisições) | 1,00 |
| SNS por e-mail (abaixo da faixa gratuita de 1.000 mensagens) | 0,00 |
| Armazenamento de logs (1 GB/mês, retenção de 7 dias, US$ 0,0408/GB-mês) | 0,01 |
| S3 versionado e temporários (fator 2 sobre a linha de S3 do DEV) | 0,10 |
| Artefatos de deploy versionados (zip de 14 MB, 20 deploys/mês) | 0,01 |
| Tráfego das respostas da API (4 KB por chamada) | 0,04 |
| Restauração do DynamoDB (2 ensaios de 1 GB a US$ 0,225/GB) | 0,45 |
| Testes de carga (2 rodadas de 20 req/s por 30 min e de 100 req/s por 10 min, 192.000 chamadas) | 4,73 |
| **Total DEV** | **9,95** (cerca de R$ 54,68) |
| Com reserva provisória de US$ 25 e contingência de 30% | **45,44** (cerca de R$ 249,61) |

Com reserva e contingência, DEV usa **cerca de 25% do teto de R$ 1.000**. Mesmo com o dólar 20% mais alto, a folga continua grande.

## Hipóteses e o que elas deixam em aberto

- **Alarmes:** 4, contando as duas DLQs e os erros da API e da manutenção. Se forem criados mais, cada um custa US$ 0,135/mês.
- **KMS:** a chave própria é necessária porque alarmes do CloudWatch não publicam em tópico cifrado com a chave gerenciada `alias/aws/sns`. As requisições foram estimadas em 1.000/mês.
- **Testes de carga:** o item mais caro. O custo por chamada reaproveita as hipóteses da estimativa preliminar (4 RRUs, 2,4 WRUs, logs de 1 GB para 60.000 chamadas, eventos em 20% das chamadas) e vale US$ 0,0000247 por chamada. Não é medido; compare com o custo real da primeira rodada.
- **Perfil de carga:** os patamares de 20 e 100 req/s vêm de `PREMISSAS-USO-RunPass-MVP.md` (teste de pico, hipótese). Mudar duração ou número de rodadas muda só esta linha.
- **Versionamento do S3:** o fator 2 é uma hipótese, sem medição.
- **Restore:** 2 ensaios de 1 GB, conforme o estoque de DEV da estimativa.

## Ainda não precificado (e por quê)

| Item | Situação |
| --- | --- |
| Impostos, IOF e taxas de cobrança | **Não verificado.** A forma de cobrança da conta (USD ou BRL e quais tributos) deve ser lida na primeira fatura. A contingência de 30% é um envelope, não uma estimativa de imposto. |
| Contas das lojas (Apple e Google) | Fora do DEV: são custo de beta, não de AWS. Valores não verificados nesta sessão. |
| GitHub Actions | Como o repositório é público, os minutos seriam gratuitos (hipótese); não verificado nesta sessão contra a documentação do GitHub. |
| DNS, domínio, hospedagem do painel, e-mail transacional | Não adotados em DEV; entram só se forem adotados. |
| NAT, WAF e CDN | Não previstos. Exigem recálculo se adotados. |
| PROD e beta | Fora deste documento. |
| Cognito | Já modelado com 10 usuários mensais; tarifa Lite é hipótese, plano não escolhido. |

## Evidência e reprodução

- Tarifas novas: `AWS-PRECOS-EXCLUSOES-SA-EAST-1.json` (CloudWatch, KMS, SNS e restauração do DynamoDB, catálogo público de São Paulo de 04/11/2026, com URL e data de publicação).
- Cálculo: `calcular_orcamento_dev_exclusoes.py` (executar dentro de `PDLC/M4`). Lê as tarifas e o subtotal DEV já modelado e grava `ORCAMENTO-RunPass-DEV-exclusoes.json`.
- Nenhum recurso AWS foi criado e nenhuma cobrança foi gerada. As consultas à AWS foram só leitura (catálogo de preços e o orçamento existente).

## Como interpretar

Os números mostram que o teto não é o risco do DEV: o gasto esperado fica muito abaixo dele. O que muda a conclusão é o que não está medido: custo real por chamada nos testes de carga, tributos da conta e qualquer serviço adotado depois. Antes de repetir testes de carga ou de ampliar DEV, compare o custo observado do primeiro mês com `runpass-dev-mensal` e com este documento. Se a previsão do change set ou o custo observado indicar ultrapassagem do teto, o provisionamento deve parar para nova aprovação, como já registrado no `S09-integracao-dev.md`.
