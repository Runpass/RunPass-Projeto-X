"""Explicit loopback-only HTTP harness. Never imported by the AWS composition root."""

import argparse
import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
import uvicorn
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.asymmetric import rsa

from .api import create_app
from .catalog import CatalogService, seed_synthetic
from .edition_requests import EditionRequestService
from .identity import CognitoVerifier, Principal
from .participation import ParticipationService
from .service import IdentityService
from .social import SocialService
from .store import MemoryStore
from .upload import MemoryBlobStore, UploadService

ISSUER = "https://runpass.local.invalid"
CLIENT_ID = "runpass-local-only"
ROOT = Path(__file__).resolve().parents[2]
CONTRACT = ROOT / "PDLC/M4/API-RunPass-v1.openapi.json"


@dataclass
class LocalRuntime:
    app: object
    tokens: dict[str, str]
    expires_at: str


def create_runtime():
    """Actual services, synthetic verified directory and ephemeral signing key; no AWS SDK client."""
    now = datetime.now(timezone.utc)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subjects = {"runnerToken": "local-admitted-runner", "newRunnerToken": "local-new-runner"}
    tokens = {
        name: jwt.encode(
            {
                "iss": ISSUER,
                "client_id": CLIENT_ID,
                "sub": subject,
                "iat": now,
                "exp": now + timedelta(hours=1),
                "token_use": "access",
            },
            key,
            algorithm="RS256",
            headers={"kid": "ephemeral-local"},
        )
        for name, subject in subjects.items()
    }
    verifier = CognitoVerifier(
        ISSUER, CLIENT_ID, lambda kid: key.public_key(), lambda token, sub: sub in subjects.values()
    )
    identity = IdentityService(
        MemoryStore(), os.urandom(32), environment="local-http", identity_namespace=ISSUER
    )
    catalog = CatalogService(identity, Fernet.generate_key())
    participations = ParticipationService(identity, catalog, Fernet.generate_key())
    uploads = UploadService(identity, MemoryBlobStore())
    seed_synthetic(catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
    admitted = Principal(subjects["runnerToken"], True)
    identity.create_profile(
        admitted,
        "seed-profile",
        {"displayName": "Corredor Sintético", "username": "synthetic_admitted"},
    )
    identity.admit(admitted, "seed-admission", {"birthDate": "1990-01-01", "declaresAdult": True})
    return LocalRuntime(
        create_app(
            identity,
            verifier,
            catalog,
            participations,
            uploads,
            SocialService(identity),
            edition_requests=EditionRequestService(identity, Fernet.generate_key()),
        ),
        tokens,
        (now + timedelta(hours=1)).isoformat(),
    )


def private_file(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_environments(runtime, port):
    variables = {"baseUrl": f"http://127.0.0.1:{port}", **runtime.tokens}
    bruno = ROOT / "api/bruno/environments/Local.bru"
    private_file(bruno, "vars {\n" + "".join(f"  {k}: {v}\n" for k, v in variables.items()) + "}\n")
    # Remove the legacy generated name so Bruno exposes one unambiguous local environment.
    (ROOT / "api/bruno/environments/Local.generated.bru").unlink(missing_ok=True)
    insomnia = ROOT / ".local/runpass-api/insomnia-environment.json"
    private_file(insomnia, json.dumps(variables, indent=2) + "\n")
    spec = json.loads(CONTRACT.read_text())
    implemented = {
        (route.path, method.lower())
        for route in runtime.app.routes
        for method in getattr(route, "methods", set())
    }
    spec["paths"] = {
        path: {
            method: operation
            for method, operation in operations.items()
            if (path, method) in implemented
        }
        for path, operations in spec["paths"].items()
        if any((path, method) in implemented for method in operations)
    }
    spec["servers"] = [
        {"url": variables["baseUrl"], "description": "Local, dados sinteticos, memoria"}
    ]
    spec["info"]["description"] = (
        "Harness HTTP local de S02-S05; sem Cognito/S3/AWS real ou persistencia duravel."
    )
    private_file(
        ROOT / ".local/runpass-api/RunPass-local.openapi.json",
        json.dumps(spec, ensure_ascii=False, indent=2) + "\n",
    )
    return bruno, insomnia


def main():
    parser = argparse.ArgumentParser(
        description="RunPass: dados sintéticos, memória, somente localhost"
    )
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Escolha porta entre 1024 e 65535")
    if os.environ.get("RUNPASS_ENV", "").lower() in {"prod", "production", "dev", "staging"}:
        parser.error("Harness permitido somente em ambiente local explícito")
    runtime = create_runtime()
    bruno, insomnia = write_environments(runtime, args.port)
    print(f"API LOCAL SINTÉTICA: http://127.0.0.1:{args.port}", flush=True)
    print(f"Bruno: {bruno}\nInsomnia (copiar variáveis): {insomnia}", flush=True)
    print(
        f"Tokens locais expiram em {runtime.expires_at}. Reiniciar apaga dados e troca tokens.",
        flush=True,
    )
    # Fixed loopback; no flag or environment fallback can expose this harness externally.
    uvicorn.run(
        runtime.app, host="127.0.0.1", port=args.port, access_log=False, log_level="warning"
    )


if __name__ == "__main__":
    main()
