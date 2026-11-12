import json
import re
import stat
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from fastapi.testclient import TestClient
from runpass.api import create_app
from runpass.local_api import ROOT, create_runtime, private_file, write_environments


class LocalApiTests(unittest.TestCase):
    def test_local_server_exercises_saved_bruno_workflow_against_actual_services(self):
        runtime = create_runtime()
        with TestClient(runtime.app) as client:
            # Execute the actual saved request definitions; no mock responses.
            for path in sorted((ROOT / "api/bruno").glob("*.bru")):
                text = path.read_text()
                method = re.search(r"^(get|post|put|patch|delete) \{", text, re.M)[1]
                url = re.search(r"^  url: (.+)$", text, re.M)[1].replace("{{baseUrl}}", "")
                token = re.search(r"Authorization: Bearer {{(\w+)}}", text)[1]
                headers = {"Authorization": "Bearer " + runtime.tokens[token]}
                command = re.search(r"Idempotency-Key: (.+)", text)
                if command:
                    headers["Idempotency-Key"] = command[1]
                body = re.search(r"body:json {\n(.*?)\n}", text, re.S)
                payload = json.loads(body[1]) if body else None
                status = int(re.search(r"res.getStatus\(\)\).to.equal\((\d+)\)", text)[1])
                with self.subTest(request=path.name):
                    response = client.request(method, url, headers=headers, json=payload)
                    self.assertEqual(response.status_code, status, response.text)
            admitted = {"Authorization": "Bearer " + runtime.tokens["runnerToken"]}
            page = client.get("/editions", headers=admitted).json()
            self.assertEqual(len(page["items"]), 5)
            # So no GET /me do proprio titular, depois da admissao gravar a data.
            self.assertEqual(client.get("/me", headers=admitted).json()["birthDate"], "1990-01-01")

    def test_tokens_are_ephemeral_and_default_application_has_no_bypass(self):
        first, second = create_runtime(), create_runtime()
        headers = {"Authorization": "Bearer " + first.tokens["runnerToken"]}
        self.assertEqual(TestClient(second.app).get("/me", headers=headers).status_code, 401)
        self.assertEqual(TestClient(create_app()).get("/me", headers=headers).status_code, 503)

    def test_generated_environments_are_private_and_not_source_credentials(self):
        runtime = create_runtime()
        with TemporaryDirectory() as directory, patch("runpass.local_api.ROOT", Path(directory)):
            bruno, insomnia = write_environments(runtime, 8001)
            spec = json.loads(
                (Path(directory) / ".local/runpass-api/RunPass-local.openapi.json").read_text()
            )
            self.assertEqual(sum(len(v) for v in spec["paths"].values()), 70)
            self.assertEqual(spec["servers"][0]["url"], "http://127.0.0.1:8001")
            self.assertEqual(stat.S_IMODE(bruno.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(insomnia.stat().st_mode), 0o600)
            self.assertEqual(json.loads(insomnia.read_text())["baseUrl"], "http://127.0.0.1:8001")
            private_file(insomnia, "{}")
            self.assertEqual(stat.S_IMODE(insomnia.stat().st_mode), 0o600)

    def test_protected_requests_still_reject_missing_or_malformed_auth(self):
        client = TestClient(create_runtime().app)
        self.assertEqual(client.get("/editions").status_code, 401)
        self.assertEqual(
            client.get("/editions", headers={"Authorization": "Bearer invalid"}).status_code, 401
        )
