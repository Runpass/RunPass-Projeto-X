"""Lambda da API do portal de administracao. Carrega clientes e segredos no primeiro uso, nunca no import."""

import os
from functools import lru_cache

from .composition import create_admin_aws_app
from .lambda_entry import _boto_client, _settings


def _number(name):
    value = os.environ.get(name, "").strip()
    return float(value) if value else None


def _costs_config():
    return {
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


def handler(event, context):
    return _admin()(event, context)
