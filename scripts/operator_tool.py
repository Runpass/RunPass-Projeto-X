#!/usr/bin/env python3
"""Ferramenta interna de operadores do RunPass para DEV autorizado (nunca exposta por HTTP).

Subcomandos (cada um e executado por uma pessoa, no proprio terminal):
  enroll        cria o operador no pool exclusivo e cadastra o TOTP (senha e segredo so no terminal)
  grant         outro responsavel ativa OPERATOR#sub/ACCESS com permissoes minimas
  load-catalog  login do operador com MFA e carga da fixture pelo importador real

Senhas e codigos TOTP sao lidos sem eco. Nenhum token, senha ou segredo e gravado em arquivo.
Uso: AWS_PROFILE=runpass-dev-sa PYTHONPATH=backend python3 scripts/operator_tool.py <comando> ...
"""

import argparse
import getpass
import sys
from pathlib import Path

import boto3
from cryptography.fernet import Fernet
from runpass.catalog import CatalogService
from runpass.identity import CognitoDirectory, CognitoVerifier, JwksProvider
from runpass.operator_admin import PERMISSIONS, grant_access, load_catalog
from runpass.operators import establish_session
from runpass.service import IdentityService
from runpass.store import DynamoStore

REGION = "sa-east-1"
FIXTURE = Path(__file__).resolve().parents[1] / "backend/fixtures/catalog.synthetic.json"


def outputs(session, stack):
    cf = session.client("cloudformation")
    return {
        o["OutputKey"]: o["OutputValue"]
        for o in cf.describe_stacks(StackName=stack)["Stacks"][0].get("Outputs", [])
    }


def exports(session, prefix):
    cf = session.client("cloudformation")
    found = {}
    for page in cf.get_paginator("list_exports").paginate():
        for item in page["Exports"]:
            if item["Name"].startswith(prefix + "-"):
                found[item["Name"][len(prefix) + 1 :]] = item["Value"]
    return found


def ask(prompt):
    return getpass.getpass(prompt)


def enroll(session, env, username):
    pool = outputs(session, f"runpass-{env}-identity")
    client_id, pool_id = pool["OperatorClient"], pool["OperatorPool"]
    idp = session.client("cognito-idp")
    password = ask("Nova senha do operador (minimo 12 caracteres): ")
    if password != ask("Repita a senha: "):
        sys.exit("As senhas nao conferem.")
    idp.admin_create_user(
        UserPoolId=pool_id,
        Username=username,
        UserAttributes=[
            {"Name": "email", "Value": username},
            {"Name": "email_verified", "Value": "true"},
        ],
        MessageAction="SUPPRESS",
    )
    idp.admin_set_user_password(
        UserPoolId=pool_id, Username=username, Password=password, Permanent=True
    )
    auth = idp.initiate_auth(
        ClientId=client_id,
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": username, "PASSWORD": password},
    )
    if auth.get("ChallengeName") != "MFA_SETUP":
        sys.exit(f"Desafio inesperado: {auth.get('ChallengeName')}")
    token = idp.associate_software_token(Session=auth["Session"])
    print("\nCadastre este segredo no aplicativo autenticador do seu celular (so neste terminal):")
    print("  Segredo:", token["SecretCode"])
    print(
        f"  URI: otpauth://totp/RunPass-{env}:{username}?secret={token['SecretCode']}&issuer=RunPass"
    )
    code = input("\nDigite o codigo de 6 digitos exibido no aplicativo: ").strip()
    verified = idp.verify_software_token(
        Session=token["Session"], UserCode=code, FriendlyDeviceName="runpass-operador"
    )
    if verified.get("Status") != "SUCCESS":
        sys.exit("Codigo TOTP nao verificado. Rode de novo.")
    idp.respond_to_auth_challenge(
        ClientId=client_id,
        ChallengeName="MFA_SETUP",
        Session=verified["Session"],
        ChallengeResponses={"USERNAME": username},
    )
    sub = next(
        a["Value"]
        for a in idp.admin_get_user(UserPoolId=pool_id, Username=username)["UserAttributes"]
        if a["Name"] == "sub"
    )
    print(f"\nOperador criado com MFA. Identificador (sub) para o passo grant: {sub}")


def store_for(session, env):
    tables = exports(session, f"runpass-{env}-data")
    return DynamoStore(
        session.client("dynamodb"),
        {
            "identity": tables["IdentityTable"],
            "operations": tables["OperationsTable"],
            "catalog": tables["CatalogTable"],
        },
    )


def grant(session, env, subject, permissions, operator_iam_user):
    caller = session.client("sts").get_caller_identity()["Arn"].rsplit("/", 1)[-1]
    if caller == operator_iam_user:
        sys.exit("Outro responsavel precisa ativar o acesso: use o perfil da outra pessoa.")
    access = grant_access(store_for(session, env), subject, permissions, caller)
    print(
        f"ACCESS ativo, versao {access['_rev']}, permissoes {access['permissions']}, por {caller}"
    )


def load(session, env, username):
    pool = outputs(session, f"runpass-{env}-identity")
    issuer = f"https://cognito-idp.{REGION}.amazonaws.com/{pool['OperatorPool']}"
    idp = session.client("cognito-idp")
    verifier = CognitoVerifier(
        issuer,
        pool["OperatorClient"],
        JwksProvider(issuer, REGION),
        CognitoDirectory(idp),
        audience="operator",
    )
    store = store_for(session, env)
    password = ask("Senha do operador: ")
    totp = ask("Codigo TOTP atual (6 digitos): ")
    token = establish_session(
        idp, pool["OperatorClient"], verifier, store, username, password, totp
    )
    actor = verifier(token)
    identity = IdentityService(
        store,
        b"loader-nao-usa-o-segredo-de-apagamento-32b",
        environment=env,
        identity_namespace=issuer,
    )
    catalog = CatalogService(identity, Fernet.generate_key())
    ids = load_catalog(catalog, actor, FIXTURE.read_text())
    print(f"{len(ids)} edicoes carregadas pelo importador (idempotente): {', '.join(ids)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--env", default="dev")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("enroll", "load-catalog"):
        sub.add_parser(name).add_argument("--username", required=True, help="e-mail do operador")
    g = sub.add_parser("grant")
    g.add_argument("--subject", required=True)
    g.add_argument("--permission", action="append", choices=PERMISSIONS, required=True)
    g.add_argument("--operator-iam-user", required=True, help="usuario IAM de quem sera operador")
    args = parser.parse_args()
    session = boto3.Session(region_name=REGION)
    if args.command == "enroll":
        enroll(session, args.env, args.username)
    elif args.command == "grant":
        grant(session, args.env, args.subject, args.permission, args.operator_iam_user)
    else:
        load(session, args.env, args.username)


if __name__ == "__main__":
    main()
