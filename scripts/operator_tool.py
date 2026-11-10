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
from runpass.catalog_import import import_rows, parse_csv, rows_to_results
from runpass.catalog_sources import ADAPTERS, SourceDisabled, SourceError
from runpass.edition_requests import EditionRequestReview
from runpass.identity import CognitoDirectory, CognitoVerifier, JwksProvider
from runpass.models import ReviewRequestDecision
from runpass.operator_admin import PERMISSIONS, grant_access, load_catalog, retire_catalog
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
    setup_mfa(idp, client_id, pool_id, env, username, auth)


def setup_mfa(idp, client_id, pool_id, env, username, auth):
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
    print(f"\nOperador com MFA pronto. Identificador (sub): {sub}")


def recreate_operator(session, env, username):
    """TOTP verificado nao pode ser removido sem login: apaga o usuario e refaz (novo sub, novo grant)."""
    pool = outputs(session, f"runpass-{env}-identity")
    session.client("cognito-idp").admin_delete_user(
        UserPoolId=pool["OperatorPool"], Username=username
    )
    print("Operador antigo apagado do pool. Cadastrando de novo.")
    enroll(session, env, username)
    print("Agora outro perfil AWS precisa rodar o comando grant com este sub (docs/operadores.md).")


def reset_operator(session, env, username):
    """Esqueceu senha e MFA: nova senha e novo TOTP para o MESMO operador (o sub e o acesso ficam)."""
    pool = outputs(session, f"runpass-{env}-identity")
    client_id, pool_id = pool["OperatorClient"], pool["OperatorPool"]
    idp = session.client("cognito-idp")
    idp.admin_get_user(UserPoolId=pool_id, Username=username)  # falha se nao existir
    password = ask("Nova senha do operador (minimo 12 caracteres): ")
    if password != ask("Repita a senha: "):
        sys.exit("As senhas nao conferem.")
    idp.admin_set_user_password(
        UserPoolId=pool_id, Username=username, Password=password, Permanent=True
    )
    idp.admin_set_user_mfa_preference(
        UserPoolId=pool_id,
        Username=username,
        SoftwareTokenMfaSettings={"Enabled": False, "PreferredMfa": False},
    )
    auth = idp.initiate_auth(
        ClientId=client_id,
        AuthFlow="USER_PASSWORD_AUTH",
        AuthParameters={"USERNAME": username, "PASSWORD": password},
    )
    if auth.get("ChallengeName") == "SOFTWARE_TOKEN_MFA":
        sys.exit(
            "O TOTP antigo continua valendo e o Cognito nao permite remove-lo sem login.\n"
            "Rode: reset-operator --recreate (apaga e recria o operador; exige novo grant)."
        )
    setup_mfa(idp, client_id, pool_id, env, username, auth)


def store_for(session, env):
    tables = exports(session, f"runpass-{env}-data")
    return DynamoStore(
        session.client("dynamodb"),
        {
            "identity": tables["IdentityTable"],
            "operations": tables["OperationsTable"],
            "catalog": tables["CatalogTable"],
            "history": tables["HistoryTable"],
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


def operator_login(session, env, username):
    """Login do operador com MFA; devolve (ator, catalogo) sobre o armazenamento real."""
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
    return actor, CatalogService(identity, Fernet.generate_key())


def load(session, env, username):
    actor, catalog = operator_login(session, env, username)
    ids = load_catalog(catalog, actor, FIXTURE.read_text())
    print(f"{len(ids)} edicoes carregadas pelo importador (idempotente): {', '.join(ids)}")


def retire_synthetic(session, env, username):
    actor, catalog = operator_login(session, env, username)
    r = retire_catalog(catalog, actor, FIXTURE.read_text())
    print(
        f"arquivadas: {r['arquivadas'] or '-'}; tiradas da lista: {r['tiradas_da_lista'] or '-'}; "
        f"nunca carregadas: {r['ausentes'] or '-'}"
    )


def print_report(report):
    c = report["counts"]
    print(
        f"{'SIMULACAO' if report['dryRun'] else 'EXECUCAO'} fonte={report['sourceCode']}: "
        f"criadas={c['created']} atualizadas={c['updated']} iguais={c['unchanged']} "
        f"revisao={c['needs_review']} erros={c['error']}"
    )
    for row in report["rows"]:
        if row["status"] in ("error", "needs_review"):
            print(
                f"  linha {row['row']} [{row['externalId']}] {row['status']}: "
                f"{row.get('errors') or row.get('detail')}"
            )
    if report.get("runId"):
        print(f"Execucao registrada: {report['runId']}")


def import_csv(session, args):
    """CSV autorizado -> catalogo. --offline so valida o arquivo (sem AWS, sem login)."""
    results = parse_csv(Path(args.file).read_text(encoding="utf-8"), args.source_code)
    if args.offline:
        report = {
            "dryRun": True,
            "sourceCode": args.source_code,
            "counts": {"created": 0, "updated": 0, "unchanged": 0, "needs_review": 0, "error": 0},
            "rows": [],
        }
        for r in results:
            status = "error" if r["errors"] else "created"
            report["counts"][status] += 1
            report["rows"].append(
                {
                    "row": r["row"],
                    "externalId": r["externalId"],
                    "status": status,
                    "errors": r["errors"],
                }
            )
        print_report(report)
        return
    actor, catalog = operator_login(session, args.env, args.username)
    print_report(
        import_rows(
            catalog,
            actor,
            results,
            origin=args.origin,
            source_code=args.source_code,
            dry_run=args.dry_run,
        )
    )


def sync_source(session, args):
    """Busca numa fonte externa habilitada (flag + credencial no ambiente) e importa."""
    adapter = ADAPTERS[args.source].from_env()
    try:
        items = adapter.fetch(query=args.query, city=args.city, state=args.state)
    except SourceDisabled:
        sys.exit(
            f"Fonte '{args.source}' desligada ou sem credencial. Veja docs/catalogo-corridas.md."
        )
    except SourceError as error:
        sys.exit(f"Falha na fonte '{args.source}': {error.code}")
    results = rows_to_results(items, args.source)
    actor, catalog = operator_login(session, args.env, args.username)
    print_report(
        import_rows(
            catalog,
            actor,
            results,
            origin=args.origin,
            source_code=args.source,
            dry_run=args.dry_run,
        )
    )


def safe(text):
    """Texto de usuario no terminal: sem caracteres de controle (evita sequencias de escape)."""
    return "".join(c if c.isprintable() else "?" for c in str(text))


def list_requests(session, args):
    """Fila de pedidos de prova ausente aguardando revisao (sem dados de quem pediu)."""
    actor, catalog = operator_login(session, args.env, args.username)
    items, more = EditionRequestReview(catalog).pending(actor, limit=args.limit)
    for item in items:
        d = item["details"]
        print(
            f"{item['id']}  v{item['version']}  {safe(d['name'])} | {d['date']} | "
            f"{safe(d['city'])}/{d.get('state', '-')} | {d['distanceKm']} km | "
            f"{safe(d.get('officialUrl', '-'))} | pedido em {item['createdAt']}"
        )
    print(f"{len(items)} pedido(s) pendente(s){' (ha mais)' if more else ''}.")


def review_request(session, args):
    """Aprova/vincula a uma edicao ja carregada no catalogo, ou rejeita com motivo."""
    decision = ReviewRequestDecision(
        expectedVersion=args.version,
        decision=args.decision,
        editionId=args.edition_id,
        reason=args.reason,
    )
    actor, catalog = operator_login(session, args.env, args.username)
    result = EditionRequestReview(catalog).decide(actor, args.id, decision)
    print(f"Pedido {result['id']}: {result['status']} (versao {result['version']})")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--env", default="dev")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("enroll", "load-catalog"):
        sub.add_parser(name).add_argument("--username", required=True, help="e-mail do operador")
    sub.add_parser("reset-operator", help="esqueceu senha e MFA: refaz os dois do mesmo operador")
    sub.choices["reset-operator"].add_argument("--username", required=True, help="e-mail")
    sub.choices["reset-operator"].add_argument(
        "--recreate", action="store_true", help="apaga e recria o operador (novo sub)"
    )
    sub.add_parser(
        "retire-synthetic", help="arquiva e tira da lista as edicoes sinteticas (nao apaga nada)"
    ).add_argument("--username", required=True, help="e-mail do operador")
    imp = sub.add_parser("import-csv", help="importa provas de um CSV autorizado")
    imp.add_argument("--username", help="e-mail do operador (nao precisa com --offline)")
    imp.add_argument("--file", required=True)
    imp.add_argument("--source-code", required=True, help="ex.: csv-sp")
    imp.add_argument(
        "--origin", default="https://exemplo.invalid/origem", help="URL https da fonte"
    )
    imp.add_argument("--dry-run", action="store_true", help="classifica sem gravar")
    imp.add_argument("--offline", action="store_true", help="so valida o arquivo, sem AWS")
    syn = sub.add_parser("sync-source", help="busca numa fonte externa habilitada")
    syn.add_argument("--username", required=True)
    syn.add_argument("--source", choices=sorted(ADAPTERS), required=True)
    syn.add_argument("--origin", required=True, help="URL https da fonte (termos de uso)")
    syn.add_argument("--state", default="SP")
    syn.add_argument("--city", default="Sao Paulo")
    syn.add_argument("--query", default="corrida")
    syn.add_argument("--dry-run", action="store_true")
    lr = sub.add_parser("list-requests", help="lista pedidos de prova ausente pendentes")
    lr.add_argument("--username", required=True)
    lr.add_argument("--limit", type=int, default=20)
    rr = sub.add_parser("review-request", help="decide um pedido de prova ausente")
    rr.add_argument("--username", required=True)
    rr.add_argument("--id", required=True)
    rr.add_argument("--version", type=int, required=True, help="versao mostrada em list-requests")
    rr.add_argument("--decision", choices=["approve", "link", "reject"], required=True)
    rr.add_argument("--edition-id", help="obrigatorio em approve/link: edicao ja no catalogo")
    rr.add_argument("--reason", help="obrigatorio em reject")
    g = sub.add_parser("grant")
    g.add_argument("--subject", required=True)
    g.add_argument("--permission", action="append", choices=PERMISSIONS, required=True)
    g.add_argument("--operator-iam-user", required=True, help="usuario IAM de quem sera operador")
    args = parser.parse_args()
    session = boto3.Session(region_name=REGION)
    if args.command == "import-csv":
        if not args.offline and not args.username:
            sys.exit("Informe --username (ou use --offline para so validar o arquivo).")
        import_csv(session, args)
    elif args.command == "reset-operator":
        if args.recreate:
            recreate_operator(session, args.env, args.username)
        else:
            reset_operator(session, args.env, args.username)
    elif args.command == "retire-synthetic":
        retire_synthetic(session, args.env, args.username)
    elif args.command == "sync-source":
        sync_source(session, args)
    elif args.command == "list-requests":
        list_requests(session, args)
    elif args.command == "review-request":
        review_request(session, args)
    elif args.command == "enroll":
        enroll(session, args.env, args.username)
    elif args.command == "grant":
        grant(session, args.env, args.subject, args.permission, args.operator_iam_user)
    else:
        load(session, args.env, args.username)


if __name__ == "__main__":
    main()
