import json
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock

import jwt
from botocore.stub import Stubber
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from jsonschema import RefResolver
from openapi_schema_validator import OAS30Validator
from runpass.api import create_app
from runpass.identity import (
    AuthFailure,
    CognitoDirectory,
    CognitoVerifier,
    Principal,
    require_operator,
)
from runpass.models import PatchProfile
from runpass.service import IdentityService, Problem
from runpass.store import DynamoStore, MemoryStore, Unavailable

NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.now = NOW
        self.service = IdentityService(
            self.store, b"synthetic-erasure-key-not-a-secret!", lambda: self.now
        )
        self.actor = Principal("u1", True)

    def create(self, subject, username=None):
        actor = Principal(subject, True)
        self.service.create_profile(
            actor, "create", {"displayName": subject, "username": username or "run_" + subject}
        )
        return actor

    def seed_count(self, count):
        key = ("identity", "BETA#v1", "CONTROL")
        self.store.commit({key: self.store.get(key)}, {key: {"count": count}})

    def test_bootstrap_is_not_admission_and_birth_date_is_owner_only(self):
        self.create("u1")
        self.assertEqual(self.service.status(self.actor)["myStatus"], "not_admitted")
        with self.assertRaises(Problem) as e:
            self.service.authorize(self.actor, admitted=True)
        self.assertEqual(e.exception.code, "BETA_ADMISSION_REQUIRED")
        self.assertNotIn("birthDate", self.service.profile(self.actor))
        self.service.admit(self.actor, "admit", ADULT)
        # So depois da admissao, e so para o proprio titular via GET /me (decisao 06/11/2026).
        self.assertEqual(self.service.profile(self.actor)["birthDate"], ADULT["birthDate"])
        self.assertNotIn("email", self.service.profile(self.actor))

    def test_same_username_concurrently_casefolds_without_partial_account(self):
        def attempt(i):
            try:
                self.create(str(i), "Same_Name" if i % 2 else "same_name")
                return True
            except Problem as e:
                self.assertEqual(e.code, "USERNAME_TAKEN")
                return False

        with ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(attempt, range(20)))
        self.assertEqual(sum(results), 1)
        accounts = [v for k, v in self.store.items.items() if k[2] == "ACCOUNT"]
        self.assertEqual(len(accounts), 1)

    def test_admission_fiftieth_mark_exactly_once(self):
        self.seed_count(49)
        actors = [self.create(str(i)) for i in range(12)]
        with ThreadPoolExecutor(max_workers=12) as pool:
            list(pool.map(lambda a: self.service.admit(a, "admit", ADULT), actors))
        control = self.store.get(("identity", "BETA#v1", "CONTROL"))
        self.assertEqual(control["count"], 61)
        self.assertEqual(control["startedAt"], "2026-10-28T15:00:00Z")
        self.assertEqual(control["endsAt"], "2026-12-27T15:00:00Z")
        self.now += timedelta(hours=2)
        self.service.admit(actors[0], "another-key", ADULT)
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL")), control)

    def test_thousandth_slot_has_one_winner_no_automatic_waitlist(self):
        self.seed_count(999)
        actors = [self.create(str(i)) for i in range(20)]

        def attempt(actor):
            try:
                self.service.admit(actor, "admit", ADULT)
                return True
            except Problem as e:
                self.assertEqual(e.code, "BETA_FULL")
                return False

        with ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(attempt, actors))
        self.assertEqual(sum(results), 1)
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL"))["count"], 1000)
        self.assertFalse(any(k[2] == "WAITLIST" for k in self.store.items))

    def test_idempotency_and_version_control(self):
        actor = self.create("u1", "Runner")
        same = self.service.create_profile(
            actor, "create", {"displayName": "u1", "username": "Runner"}
        )
        self.assertEqual(same["version"], 1)
        with self.assertRaises(Problem) as e:
            self.service.create_profile(
                actor, "create", {"displayName": "changed", "username": "Runner"}
            )
        self.assertEqual(e.exception.code, "IDEMPOTENCY_CONFLICT")
        self.service.admit(actor, "admit", ADULT)
        changed = self.service.patch_profile(
            actor, "patch", {"expectedVersion": 1, "username": "Next_Name"}
        )
        self.assertEqual(changed["username"], "next_name")
        self.assertIsNone(self.store.get(("identity", "USERNAME#runner", "CLAIM")))
        with self.assertRaises(Problem) as e:
            self.service.patch_profile(actor, "stale", {"expectedVersion": 1, "bio": "old"})
        self.assertEqual(e.exception.code, "VERSION_CONFLICT")

    def test_renaming_to_taken_username_preserves_both(self):
        self.create("u1", "first")
        self.create("u2", "second")
        self.service.admit(self.actor, "admit", ADULT)
        with self.assertRaises(Problem):
            self.service.patch_profile(
                self.actor, "patch", {"expectedVersion": 1, "username": "SECOND"}
            )
        self.assertEqual(self.service.profile(self.actor)["username"], "first")
        self.assertEqual(self.service.profile(Principal("u2", True))["username"], "second")

    def test_deletion_blocks_old_identity_preserves_count_and_durable_job(self):
        self.create("u1")
        self.service.admit(self.actor, "admit", ADULT)
        receipt = self.service.delete_account(self.actor, "delete")
        self.assertTrue(receipt["accessBlocked"])
        for action in (
            lambda: self.service.profile(self.actor),
            lambda: self.service.admit(self.actor, "old", ADULT),
            lambda: self.service.create_profile(
                self.actor, "create", {"displayName": "u1", "username": "run_u1"}
            ),
        ):
            with self.assertRaises(Problem) as e:
                action()
            self.assertEqual(e.exception.status, 403)
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL"))["count"], 1)
        control = self.store.get(self.service.erasure("u1"))
        self.assertEqual(control["expiresAt"], int((NOW + timedelta(days=15)).timestamp()))
        self.assertEqual(set(control), {"acceptedAt", "expiresAt", "expiryPK", "expirySK", "_rev"})
        job = self.store.get(("operations", "USER#u1", "JOB#" + receipt["operationId"]))
        self.assertEqual(job["dueAt"], "2026-11-04T15:00:00Z")

    def test_deletion_frees_the_cognito_identity_right_away_so_the_email_can_sign_up_again(self):
        removed = []
        service = IdentityService(
            self.store,
            b"synthetic-erasure-key-not-a-secret!",
            lambda: self.now,
            account_remover=Mock(delete_owner=lambda owner: removed.append(owner)),
        )
        actor = Principal("u1", True)
        service.create_profile(actor, "create", {"displayName": "u1", "username": "run_u1"})
        service.admit(actor, "admit", ADULT)
        service.delete_account(actor, "delete")
        # Nao espera o job assincrono: o Cognito ja foi chamado na mesma requisicao de exclusao.
        self.assertEqual(removed, ["u1"])

    def test_deletion_still_accepted_even_if_the_immediate_cognito_removal_fails(self):
        remover = Mock()
        remover.delete_owner.side_effect = Unavailable()
        service = IdentityService(
            self.store,
            b"synthetic-erasure-key-not-a-secret!",
            lambda: self.now,
            account_remover=remover,
        )
        actor = Principal("u1", True)
        service.create_profile(actor, "create", {"displayName": "u1", "username": "run_u1"})
        service.admit(actor, "admit", ADULT)
        # A tentativa imediata falha (rede etc.), mas o pedido continua aceito; o job assincrono
        # de erasure ainda remove o usuario do Cognito mais tarde, como ja acontecia antes.
        receipt = service.delete_account(actor, "delete")
        self.assertTrue(receipt["accessBlocked"])

    def test_waitlist_voluntary_unique_and_replay_after_removal_does_not_rejoin(self):
        self.create("u1")
        self.seed_count(1000)
        first = self.service.admit(self.actor, "wait", ADULT, waitlist=True)
        self.assertEqual(self.service.admit(self.actor, "wait-again", ADULT, waitlist=True), first)
        self.service.remove_waitlist(self.actor, "remove")
        replay = self.service.admit(self.actor, "wait", ADULT, waitlist=True)
        self.assertEqual(replay["state"], "removed")
        with self.assertRaises(Problem):
            self.service.waitlist(self.actor)
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL"))["count"], 1000)

    def test_old_remove_command_does_not_remove_new_waitlist_entry(self):
        self.create("u1")
        self.seed_count(1000)
        self.service.admit(self.actor, "wait", ADULT, waitlist=True)
        self.service.remove_waitlist(self.actor, "remove")
        latest = self.service.admit(self.actor, "new-wait", ADULT, waitlist=True)
        self.service.remove_waitlist(self.actor, "remove")
        self.assertEqual(self.service.waitlist(self.actor), latest)

    def test_age_boundary_uses_sao_paulo_day(self):
        self.create("u1")
        self.now = datetime(2026, 10, 29, 1, tzinfo=timezone.utc)  # still 28th in São Paulo
        with self.assertRaises(Problem):
            self.service.admit(
                self.actor, "young", {"birthDate": "2013-10-29", "declaresAdult": True}
            )
        result = self.service.admit(
            self.actor, "adult", {"birthDate": "2013-10-28", "declaresAdult": True}
        )
        self.assertTrue(result["admitted"])

    def test_expired_command_does_not_duplicate_admission(self):
        self.create("u1")
        self.service.admit(self.actor, "admit", ADULT)
        self.now += timedelta(days=8)
        self.service.admit(self.actor, "admit", ADULT)
        self.assertEqual(self.store.get(("identity", "BETA#v1", "CONTROL"))["count"], 1)

    def test_beta_closes_at_end_and_does_not_start_before_fifty(self):
        self.create("u1")
        self.assertNotIn("betaEndsAt", self.service.admit(self.actor, "admit", ADULT))
        key = ("identity", "BETA#v1", "CONTROL")
        self.store.commit(
            {key: self.store.get(key)}, {key: {"count": 50, "endsAt": "2026-10-28T15:00:00Z"}}
        )
        actor = self.create("u2")
        with self.assertRaises(Problem) as e:
            self.service.admit(actor, "admit", ADULT)
        self.assertEqual(e.exception.code, "BETA_CLOSED")

    def test_operator_cannot_consume_runner_slot_and_unverified_cannot_bootstrap(self):
        for actor in (Principal("op", True, "operator"), Principal("u", False)):
            with self.assertRaises(Problem):
                self.service.create_profile(
                    actor, "create", {"displayName": "Name", "username": "name"}
                )
        self.assertFalse(self.store.items)


class JwtTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        cls.other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def setUp(self):
        self.claims = {
            "sub": "u1",
            "iss": "https://issuer.example/pool",
            "client_id": "runner-client",
            "token_use": "access",
            "iat": int(time.time()),
            "exp": int(time.time()) + 300,
        }
        self.directory = Mock(return_value=True)
        self.verifier = CognitoVerifier(
            self.claims["iss"], "runner-client", lambda kid: self.key.public_key(), self.directory
        )

    def token(self, **changes):
        return jwt.encode(
            {**self.claims, **changes}, self.key, algorithm="RS256", headers={"kid": "test"}
        )

    def test_valid_signed_access_token_checks_current_directory(self):
        self.assertEqual(self.verifier(self.token()).subject, "u1")
        self.directory.assert_called_once()

    def test_wrong_client_pool_expiration_or_token_type(self):
        for changes in (
            {"client_id": "other"},
            {"iss": "https://other.example/pool"},
            {"exp": int(time.time()) - 5},
            {"token_use": "id"},
            {"iat": int(time.time()) + 500},
            {"sub": ""},
        ):
            with self.subTest(changes=changes), self.assertRaises(AuthFailure):
                self.verifier(self.token(**changes))
        self.directory.assert_not_called()

    def test_wrong_signature_algorithm_missing_claims_and_malformed(self):
        invalid = [
            jwt.encode(self.claims, self.other_key, algorithm="RS256", headers={"kid": "test"}),
            jwt.encode(self.claims, "x" * 40, algorithm="HS256", headers={"kid": "test"}),
            jwt.encode(
                {k: v for k, v in self.claims.items() if k != "exp"},
                self.key,
                algorithm="RS256",
                headers={"kid": "test"},
            ),
            "broken",
        ]
        for token in invalid:
            with self.subTest(token=token[:12]), self.assertRaises(AuthFailure):
                self.verifier(token)

    def test_directory_must_match_verified_subject_not_token_email_claim(self):
        client = Mock()
        client.get_user.return_value = {
            "UserAttributes": [
                {"Name": "sub", "Value": "someone-else"},
                {"Name": "email_verified", "Value": "true"},
            ]
        }
        with self.assertRaises(AuthFailure):
            CognitoDirectory(client)("token", "u1")

    def test_operator_requires_exact_mfa_session_and_current_access(self):
        store = MemoryStore()
        actor = Principal("op", True, "operator", "digest")
        access = ("identity", "OPERATOR#op", "ACCESS")
        session = ("operations", "OPERATOR#op", "SESSION#digest")
        store.commit(
            {access: None}, {access: {"state": "active", "permissions": ["catalog_admin"]}}
        )
        with self.assertRaises(AuthFailure):
            require_operator(store, actor, "catalog_admin", NOW)
        store.commit(
            {session: None},
            {
                session: {
                    "accessVersion": 1,
                    "factor": "SOFTWARE_TOKEN_MFA",
                    "expiresAt": int(NOW.timestamp()) + 60,
                }
            },
        )
        self.assertTrue(require_operator(store, actor, "catalog_admin", NOW))
        with self.assertRaises(AuthFailure):
            require_operator(store, actor, "lake_read", NOW)
        with self.assertRaises(AuthFailure):
            require_operator(store, actor, "catalog_admin", NOW + timedelta(minutes=2))
        store.commit(
            {access: store.get(access)},
            {access: {"state": "suspended", "permissions": ["catalog_admin"]}},
        )
        with self.assertRaises(AuthFailure):
            require_operator(store, actor, "catalog_admin", NOW)


class OperatorSessionTests(unittest.TestCase):
    def test_only_completed_totp_challenge_creates_bound_session(self):
        from runpass.operators import establish_session

        store = MemoryStore()
        access = ("identity", "OPERATOR#op", "ACCESS")
        store.commit(
            {access: None}, {access: {"state": "active", "permissions": ["catalog_admin"]}}
        )
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        token = jwt.encode(
            {
                "sub": "op",
                "iss": "https://operator.example",
                "client_id": "ops",
                "token_use": "access",
                "iat": int(time.time()),
                "exp": int(time.time()) + 300,
            },
            key,
            algorithm="RS256",
            headers={"kid": "test"},
        )
        verifier = CognitoVerifier(
            "https://operator.example",
            "ops",
            lambda kid: key.public_key(),
            lambda token, sub: True,
            audience="operator",
        )
        client = Mock()
        client.initiate_auth.return_value = {
            "ChallengeName": "SOFTWARE_TOKEN_MFA",
            "Session": "challenge",
        }
        client.respond_to_auth_challenge.return_value = {
            "AuthenticationResult": {"AccessToken": token}
        }
        self.assertEqual(
            establish_session(
                client, "ops", verifier, store, "op@example.test", "synthetic-password", "123456"
            ),
            token,
        )
        self.assertTrue(require_operator(store, verifier(token), "catalog_admin"))
        for state in (
            {"AuthenticationResult": {"AccessToken": token}},
            {"ChallengeName": "MFA_SETUP", "Session": "enrollment"},
        ):
            client.initiate_auth.return_value = state
            with self.assertRaises(AuthFailure):
                establish_session(
                    client,
                    "ops",
                    verifier,
                    store,
                    "op@example.test",
                    "synthetic-password",
                    "123456",
                )
        self.assertFalse(
            any("synthetic-password" in str(v) or token in str(v) for v in store.items.values())
        )


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.service = IdentityService(
            self.store, b"synthetic-erasure-key-not-a-secret!", lambda: NOW
        )
        self.actor = Principal("u1", True)

        def verifier(token):
            if token != "synthetic-token":
                raise AuthFailure()
            return self.actor

        self.client = TestClient(create_app(self.service, verifier))
        self.headers = {"Authorization": "Bearer synthetic-token", "Idempotency-Key": "command"}
        contract = Path(__file__).resolve().parents[2] / "PDLC/M4/API-RunPass-v1.openapi.json"
        self.contract = json.loads(contract.read_text())

    def schema(self, name, value):
        OAS30Validator(
            self.contract["components"]["schemas"][name],
            resolver=RefResolver.from_schema(self.contract),
        ).validate(value)

    def test_http_workflow_matches_contract_and_old_token_blocked(self):
        response = self.client.put(
            "/me", json={"displayName": "Thiago", "username": "Thiago_Run"}, headers=self.headers
        )
        self.assertEqual(response.status_code, 201)
        self.schema("OwnProfile", response.json())
        response = self.client.get("/beta/status", headers=self.headers)
        self.schema("BetaStatus", response.json())
        self.assertEqual(response.json()["myStatus"], "not_admitted")
        response = self.client.patch(
            "/me", json={"expectedVersion": 1, "bio": "Hi"}, headers=self.headers
        )
        self.assertEqual(response.status_code, 403)
        response = self.client.post("/beta/admissions", json=ADULT, headers=self.headers)
        self.assertEqual(response.status_code, 201)
        self.schema("BetaAdmission", response.json())
        response = self.client.patch(
            "/me", json={"expectedVersion": 1, "bio": "Hi"}, headers=self.headers
        )
        self.assertEqual(response.status_code, 200)
        self.schema("OwnProfile", response.json())
        response = self.client.delete("/me", headers=self.headers)
        self.assertEqual(response.status_code, 202)
        self.schema("AccountDeletionReceipt", response.json())
        self.assertEqual(self.client.get("/me", headers=self.headers).status_code, 403)

    def test_sensitive_invalid_input_never_echoed(self):
        for body in (
            {"birthDate": "private-invalid-date", "declaresAdult": True},
            {"birthDate": "19900101", "declaresAdult": True},
            {"birthDate": "1990-01-01", "declaresAdult": 1},
            {**ADULT, "roles": ["admin"]},
        ):
            response = self.client.post("/beta/admissions", json=body, headers=self.headers)
            self.assertEqual(response.status_code, 422)
            self.assertNotIn(body["birthDate"], response.text)
            self.assertEqual(set(response.json()), {"code", "message", "correlationId"})

    def test_unknown_fields_blank_names_keys_and_missing_identity_rejected(self):
        for body in (
            {"displayName": "   ", "username": "runner"},
            {"displayName": "Name", "username": "runner", "admitted": True},
        ):
            self.assertEqual(
                self.client.put("/me", json=body, headers=self.headers).status_code, 422
            )
        self.assertEqual(self.client.get("/me").status_code, 401)
        self.assertEqual(
            self.client.get("/me", headers={"Authorization": "Bearer bad"}).status_code, 401
        )
        self.assertEqual(TestClient(create_app()).get("/beta/status").status_code, 503)

    def test_state_accepts_only_a_two_letter_uf_code(self):
        self.client.put(
            "/me", json={"displayName": "Thiago", "username": "thiago"}, headers=self.headers
        )
        self.client.post("/beta/admissions", json=ADULT, headers=self.headers)
        for bad in ("sp", "SPX", "S", ""):
            response = self.client.patch(
                "/me",
                json={"expectedVersion": 1, "state": bad, "city": "Taboão da Serra"},
                headers=self.headers,
            )
            self.assertEqual(response.status_code, 422)
        response = self.client.patch(
            "/me",
            json={"expectedVersion": 1, "state": "SP", "city": "Taboão da Serra"},
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200)
        self.schema("OwnProfile", response.json())
        self.assertEqual(
            (response.json()["state"], response.json()["city"]), ("SP", "Taboão da Serra")
        )

    def test_latitude_and_longitude_accompany_state_and_city(self):
        self.client.put(
            "/me", json={"displayName": "Thiago", "username": "thiago"}, headers=self.headers
        )
        self.client.post("/beta/admissions", json=ADULT, headers=self.headers)
        response = self.client.patch(
            "/me",
            json={
                "expectedVersion": 1,
                "state": "SP",
                "city": "Taboão da Serra",
                "latitude": -23.6028,
                "longitude": -46.7922,
            },
            headers=self.headers,
        )
        self.assertEqual(response.status_code, 200)
        self.schema("OwnProfile", response.json())
        self.assertEqual(
            (response.json()["latitude"], response.json()["longitude"]), (-23.6028, -46.7922)
        )
        for bad in ({"latitude": 91}, {"longitude": -181}):
            response = self.client.patch(
                "/me", json={"expectedVersion": 2, **bad}, headers=self.headers
            )
            self.assertEqual(response.status_code, 422)

    def test_other_subject_cannot_read_or_patch_owner(self):
        self.client.put(
            "/me", json={"displayName": "Name", "username": "runner"}, headers=self.headers
        )
        self.actor = Principal("u2", True)
        self.assertEqual(self.client.get("/me", headers=self.headers).status_code, 404)
        self.assertEqual(
            self.client.patch(
                "/me", json={"expectedVersion": 1, "bio": "bad"}, headers=self.headers
            ).status_code,
            403,
        )


class DynamoAdapterTests(unittest.TestCase):
    def test_patch_profile_coordinates_encode_for_real_dynamodb_not_only_memorystore(self):
        """Regressao: MemoryStore (usado no resto dos testes) nunca serializa para o DynamoDB,
        entao um campo gravado como `float` em vez de `Decimal` passa limpo nos testes e so
        quebra (TypeError: Float types are not supported) contra o DynamoDB de verdade. Visto
        em producao no DEV em 08/11/2026: PATCH /me com latitude/longitude (a maioria das
        cidades da lista do IBGE tem coordenada) sempre retornava 500."""
        import boto3

        patch = PatchProfile(
            expectedVersion=1,
            state="SP",
            city="Taboão da Serra",
            latitude=-23.6028,
            longitude=-46.7922,
        )
        profile = {"id": "u1", "username": "u1", "displayName": "U1", "version": 1}
        for name, value in patch.model_dump(exclude_unset=True).items():
            if name != "expectedVersion":
                profile[name] = value

        client = boto3.client(
            "dynamodb",
            region_name="sa-east-1",
            aws_access_key_id="synthetic",
            aws_secret_access_key="synthetic",
        )
        adapter = DynamoStore(client, {"identity": "test-identity"})
        encoded = adapter.encode(profile)
        self.assertIn("N", encoded["latitude"])
        self.assertIn("N", encoded["longitude"])

    def test_dynamo_reads_strongly_and_writes_expected_version_in_single_action(self):
        import boto3

        client = boto3.client(
            "dynamodb",
            region_name="sa-east-1",
            aws_access_key_id="synthetic",
            aws_secret_access_key="synthetic",
        )
        adapter = DynamoStore(client, {"identity": "test-identity"})
        key = ("identity", "USER#u", "ACCOUNT")
        encoded_key = {"PK": {"S": "USER#u"}, "SK": {"S": "ACCOUNT"}}
        previous = {"state": "active", "_rev": 1}
        with Stubber(client) as stub:
            stub.add_response(
                "get_item",
                {"Item": {**encoded_key, "state": {"S": "active"}, "_rev": {"N": "1"}}},
                {"TableName": "test-identity", "Key": encoded_key, "ConsistentRead": True},
            )
            stub.add_response(
                "transact_write_items",
                {},
                {
                    "TransactItems": [
                        {
                            "Put": {
                                "TableName": "test-identity",
                                "ConditionExpression": "#r = :r",
                                "ExpressionAttributeNames": {"#r": "_rev"},
                                "ExpressionAttributeValues": {":r": {"N": "1"}},
                                "Item": {
                                    **encoded_key,
                                    "state": {"S": "deleting"},
                                    "_rev": {"N": "2"},
                                },
                            }
                        }
                    ]
                },
            )
            self.assertEqual(adapter.get(key), previous)
            adapter.commit({key: previous}, {key: {"state": "deleting"}})
            stub.assert_no_pending_responses()

    def test_conditional_conflict_is_atomic_and_no_credentials_needed(self):
        import boto3

        client = boto3.client(
            "dynamodb",
            region_name="sa-east-1",
            aws_access_key_id="synthetic",
            aws_secret_access_key="synthetic",
        )
        adapter = DynamoStore(client, {"identity": "test-identity"})
        with Stubber(client) as stub:
            stub.add_client_error(
                "transact_write_items",
                service_error_code="TransactionCanceledException",
                modeled_fields={"CancellationReasons": [{"Code": "ConditionalCheckFailed"}]},
            )
            from runpass.store import Conflict

            with self.assertRaises(Conflict):
                adapter.commit(
                    {("identity", "USER#u", "ACCOUNT"): None},
                    {("identity", "USER#u", "ACCOUNT"): {"state": "active"}},
                )
            stub.assert_no_pending_responses()


if __name__ == "__main__":
    unittest.main()
