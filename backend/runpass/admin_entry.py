"""Lambda da API do portal de administracao. Carrega clientes e segredos no primeiro uso, nunca no import."""

import os
from functools import lru_cache

from .composition import create_admin_aws_app, create_auto_import_aws
from .lambda_entry import _boto_client, _settings


def _number(name):
    value = os.environ.get(name, "").strip()
    return float(value) if value else None


def _openai_key_loader():
    """Chave de administrador da OpenAI (opcional): le do SSM so quando o painel precisa e a guarda em memoria."""
    name = os.environ.get("RUNPASS_OPENAI_ADMIN_KEY_PARAM", "").strip()
    if not name:
        return None
    cache = {}

    def load():
        if "key" not in cache:
            ssm = _boto_client("ssm")
            cache["key"] = ssm.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]
        return cache["key"]

    return load


def _costs_config():
    return {
        "openai_key_loader": _openai_key_loader(),
        # Agendamentos do catalogo: funcao e papel do agendador (vazio = o portal so le os agendamentos).
        "catalog_function_arn": os.environ.get("RUNPASS_CATALOG_FUNCTION_ARN", "").strip(),
        "scheduler_role_arn": os.environ.get("RUNPASS_CATALOG_SCHEDULER_ROLE_ARN", "").strip(),
        "openai_project": os.environ.get("RUNPASS_OPENAI_PROJECT_ID", "").strip(),
        # O Cost Explorer so existe em us-east-1, qualquer que seja a regiao da conta.
        "ce": _boto_client("ce", region_name="us-east-1"),
        "budget": _number("RUNPASS_AWS_BUDGET_USD"),
        "limit": _number("RUNPASS_OPENAI_LIMIT_USD"),
        "prices": {
            "in": _number("RUNPASS_OPENAI_PRICE_IN_PER_MTOK"),
            "out": _number("RUNPASS_OPENAI_PRICE_OUT_PER_MTOK"),
            "search": _number("RUNPASS_OPENAI_PRICE_PER_SEARCH"),
        },
    }


@lru_cache(maxsize=1)
def _admin():
    from mangum import Mangum

    app = create_admin_aws_app(
        _settings(with_cursor_key=True),
        _boto_client("dynamodb"),
        _boto_client("cognito-idp"),
        os.environ["RUNPASS_OPERATOR_ISSUER"],
        os.environ["RUNPASS_OPERATOR_CLIENT_ID"],
        os.environ["RUNPASS_OPERATOR_POOL_ID"],
        os.environ.get("RUNPASS_PORTAL_ORIGIN", ""),
        os.environ["RUNPASS_RUNNER_USER_POOL_ID"],
        _boto_client("lambda"),
        os.environ.get("RUNPASS_CATALOG_FUNCTION", ""),
        _boto_client("logs"),
        _boto_client("scheduler"),
        _costs_config(),
        {
            "s3": _boto_client("s3"),
            "medal_bucket": os.environ["RUNPASS_MEDAL_BUCKET"],
            "report_bucket": os.environ.get("RUNPASS_CATALOG_REPORT_BUCKET", ""),
        },
    )
    return Mangum(app, lifespan="off")


@lru_cache(maxsize=1)
def _auto_import():
    return create_auto_import_aws(
        _settings(with_cursor_key=True),
        _boto_client("dynamodb"),
        _boto_client("s3"),
        os.environ.get("RUNPASS_CATALOG_REPORT_BUCKET", ""),
    )


def handler(event, context):
    # Evento da regra horaria (nao e uma chamada HTTP): importe automatico das corridas achadas pela rotina.
    if isinstance(event, dict) and event.get("autoImport") is True:
        return _auto_import().run("schedule")
    return _admin()(event, context)
