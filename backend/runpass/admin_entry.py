"""Lambda da API do portal de administracao. Carrega clientes e segredos no primeiro uso, nunca no import."""

import os
from functools import lru_cache

from .composition import create_admin_aws_app
from .lambda_entry import _boto_client, _settings


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
        os.environ["RUNPASS_PORTAL_ORIGIN"],
    )
    return Mangum(app, lifespan="off")


def handler(event, context):
    return _admin()(event, context)
