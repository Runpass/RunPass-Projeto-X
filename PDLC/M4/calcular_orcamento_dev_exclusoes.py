"""Itens antes excluídos da estimativa, para o ambiente DEV. Sensibilidade, não orçamento final.

Executar dentro de PDLC/M4. Lê AWS-PRECOS-SA-EAST-1.json e AWS-PRECOS-EXCLUSOES-SA-EAST-1.json
e ORCAMENTO-RunPass-simulacao.json (subtotal DEV já modelado). Grava ORCAMENTO-RunPass-DEV-exclusoes.json.
"""

import json
from pathlib import Path

base = json.loads(Path("AWS-PRECOS-SA-EAST-1.json").read_text(encoding="utf-8"))
extra = json.loads(Path("AWS-PRECOS-EXCLUSOES-SA-EAST-1.json").read_text(encoding="utf-8"))
simulation = json.loads(Path("ORCAMENTO-RunPass-simulacao.json").read_text(encoding="utf-8"))
rates = simulation["rates"]  # tarifas já usadas na estimativa preliminar


def extra_rate(service, usage, begin="0"):
    rows = [r for r in extra[service]["rows"] if r["usage"] == usage and r["begin"] == begin]
    if len(rows) != 1:
        raise ValueError((service, usage, begin, len(rows)))
    return float(rows[0]["USD"])


alarm = extra_rate("AmazonCloudWatch", "SAE1-CW:AlarmMonitorUsage")
log_storage = extra_rate("AmazonCloudWatch", "SAE1-TimedStorage-ByteHrs")  # USD por GB-mês
kms_key = extra_rate("awskms", "sa-east-1-KMS-Keys")
kms_request = extra_rate("awskms", "sa-east-1-KMS-Requests")
sns_email_after_free = extra_rate("AmazonSNS", "SAE1-DeliveryAttempts-SMTP", "1000")
restore_gb = extra_rate("AmazonDynamoDB", "SAE1-RestoreDataSize-Bytes")
usd_brl = extra["_cambio"]["BRL_por_USD"]

dev = simulation["scenarios"]["DEV"]
dev_inputs = dev["inputs"]
modelled = dev["subtotal"]

# --- Hipóteses explícitas (não medidas) ---
alarms_count = 4  # 2 DLQs (data.template) + erros da API e da manutenção (app.template)
alert_emails_per_month = 40  # abaixo da faixa gratuita de 1.000 e-mails
kms_requests_per_month = 1000
log_retention_days = 7
s3_versioning_factor = 2.0  # versões não correntes e temporários duplicam a linha de S3 do DEV
artifact_mb, deploys_per_month = 14, 20  # zip da Lambda, 20 deploys/mês (premissas, seção 8)
api_response_kb = 4  # tráfego de respostas JSON da API
restore_drills, restore_gb_each = 2, dev_inputs["ddb_gb"]
load_rounds = 2
load_calls = (20 * 30 * 60) + (100 * 10 * 60)  # 20 req/s por 30 min + 100 req/s por 10 min
load_calls *= load_rounds

# S3 em GB-mês: a tarifa de storage está por byte-hora no arquivo base; converter como a estimativa.
GB = 1e9
HOURS = 720


def per_call_cost():
    """Custo por chamada de API reutilizando as hipóteses por chamada da estimativa preliminar."""
    events = 0.2
    deliveries = events * 1.05 * 2
    api = rates["api"]
    lambda_cost = (1 + deliveries) * rates["lambda_request"] + (
        0.5 * 0.3 + deliveries * 0.25 * 0.1
    ) * rates["lambda_duration"]
    ddb = 4 * rates["ddb_read"] + 2.4 * rates["ddb_write"]
    sqs = events * 3 * 1.05 * rates["sqs"]
    logs = (dev_inputs["logs"] / dev_inputs["calls"]) * rates["logs"]
    audit_deliveries = events * 1.05
    lake = (
        audit_deliveries
        * (3 * rates["sqs"] + rates["lambda_request"] + 0.25 * 0.1 * rates["lambda_duration"])
        + audit_deliveries * rates["s3_put"]
    )
    return api + lambda_cost + ddb + sqs + logs + lake


lines = {
    "Alarmes CloudWatch (padrão)": alarms_count * alarm,
    "Chave KMS própria do tópico de alertas (1 chave + requisições)": kms_key
    + kms_requests_per_month * kms_request,
    "SNS e-mail (faixa gratuita de 1.000/mês)": max(0, alert_emails_per_month - 1000)
    * sns_email_after_free,
    "Armazenamento de logs (retenção de 7 dias)": dev_inputs["logs"]
    * log_retention_days
    / 30
    * log_storage,
    "S3 versionado e temporários (linha de S3 do DEV x fator)": (s3_versioning_factor - 1)
    * (
        dev_inputs["storage"] * rates["s3_storage"]
        + dev_inputs["images"] * rates["s3_get"]
        + dev_inputs["uploads"] * 2 * rates["s3_put"]
    ),
    "Artefatos de deploy versionados (S3)": artifact_mb
    * deploys_per_month
    / 1000
    * rates["s3_storage"],
    "Tráfego de respostas da API": dev_inputs["calls"] * api_response_kb / 1e6 * rates["transfer"],
    "Restauração DynamoDB (ensaios de restore)": restore_drills * restore_gb_each * restore_gb,
    "Testes de carga (2 rodadas de 20 req/s por 30 min e 100 req/s por 10 min)": load_calls
    * per_call_cost(),
}
excluded_total = sum(lines.values())
total = modelled + excluded_total
contingency = total * 0.30
reserve = 25.0
ceiling_brl = 1000.0
ceiling_usd = ceiling_brl / usd_brl


def stress(rate):
    return ceiling_brl / rate


result = {
    "usd_brl": usd_brl,
    "modelled_dev_subtotal_usd": modelled,
    "excluded_lines_usd": lines,
    "excluded_total_usd": excluded_total,
    "dev_total_usd": total,
    "with_contingency_30pct_usd": total + contingency,
    "with_reserve_and_contingency_usd": total + reserve + (total + reserve) * 0.30,
    "ceiling_brl": ceiling_brl,
    "ceiling_usd_at_ptax": ceiling_usd,
    "ceiling_usd_if_dollar_20pct_higher": stress(usd_brl * 1.2),
    "share_of_ceiling_with_reserve_and_contingency": (total + reserve + (total + reserve) * 0.30)
    / ceiling_usd,
    "budget_runpass_dev_mensal_usd": 150.0,
    "budget_in_brl_at_ptax": 150.0 * usd_brl,
    "hypotheses": {
        "alarms_count": alarms_count,
        "alert_emails_per_month": alert_emails_per_month,
        "kms_requests_per_month": kms_requests_per_month,
        "log_retention_days": log_retention_days,
        "s3_versioning_factor": s3_versioning_factor,
        "artifact_mb": artifact_mb,
        "deploys_per_month": deploys_per_month,
        "api_response_kb": api_response_kb,
        "restore_drills": restore_drills,
        "restore_gb_each": restore_gb_each,
        "load_calls": load_calls,
        "per_call_cost_usd": per_call_cost(),
    },
}
Path("ORCAMENTO-RunPass-DEV-exclusoes.json").write_text(
    json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8"
)
print(f"DEV já modelado          US$ {modelled:7.2f}")
for name, value in lines.items():
    print(f"  + {name[:62]:<62} US$ {value:7.3f}")
print(f"Itens antes excluídos    US$ {excluded_total:7.2f}")
print(f"DEV total                US$ {total:7.2f}  (R$ {total * usd_brl:7.2f})")
print(f"+ reserva US$25 e 30%    US$ {result['with_reserve_and_contingency_usd']:7.2f}")
print(
    f"Teto R$ 1.000            US$ {ceiling_usd:7.2f} (PTAX {usd_brl}); dólar +20%: US$ {stress(usd_brl * 1.2):.2f}"
)
print(
    f"Uso do teto com reserva e contingência: {result['share_of_ceiling_with_reserve_and_contingency']:.1%}"
)
