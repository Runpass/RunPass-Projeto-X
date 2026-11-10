"""Busca em linguagem natural: a Lambda do catalogo e SEMPRE simulada; nenhum teste toca a AWS."""

import io
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import Mock

from botocore.exceptions import ClientError
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient
from jsonschema import RefResolver
from openapi_schema_validator import OAS30Validator
from runpass.api import create_app
from runpass.aws_adapters import LambdaSearchInvoker
from runpass.catalog import CatalogService, seed_synthetic
from runpass.identity import AuthFailure, Principal
from runpass.nl_search import NaturalSearch
from runpass.service import IdentityService
from runpass.store import MemoryStore, Unavailable

ROOT = Path(__file__).resolve().parents[2]
NOW = datetime(2026, 10, 28, 15, tzinfo=timezone.utc)
ADULT = {"birthDate": "1990-01-01", "declaresAdult": True}


def answer(params=None, source="llm", applied=(), not_applied=(), empty=False):
    return {
        "origem": source,
        "params": params or {},
        "aplicados": list(applied),
        "nao_aplicados": list(not_applied),
        "vazia": empty,
    }


class FakeLambda:
    """Guarda o que recebeu, para provar que so a frase (e a localizacao pedida) sai do backend."""

    def __init__(self, result):
        self.result, self.payloads = result, []

    def __call__(self, payload):
        self.payloads.append(payload)
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


class TranslatorTests(unittest.TestCase):
    def test_accepts_contract_answer_and_drops_unknown_filters(self):
        fake = FakeLambda(
            answer({"state": "SP", "distanceKm": 10.0, "usuario": "x", "preco": 5}, "llm", ["uf"])
        )
        t = NaturalSearch(fake).translate("10k em sp")
        self.assertEqual((t.source, t.filters), ("llm", {"state": "SP", "distanceKm": 10.0}))
        self.assertEqual(fake.payloads, [{"frase": "10k em sp"}])

    def test_text_origin_and_cache_are_reported(self):
        self.assertEqual(
            NaturalSearch(FakeLambda(answer(source="texto"))).translate("x").source, "text"
        )
        self.assertEqual(
            NaturalSearch(FakeLambda(answer(source="cache"))).translate("x").source, "cache"
        )

    def test_location_is_sent_only_when_both_coordinates_exist(self):
        fake = FakeLambda(answer())
        search = NaturalSearch(fake)
        search.translate("a", -23.5, None)
        search.translate("b", -23.5, -46.6)
        self.assertEqual(
            fake.payloads, [{"frase": "a"}, {"frase": "b", "lat": -23.5, "lng": -46.6}]
        )

    def test_any_failure_or_broken_answer_falls_back_to_name_search(self):
        broken = [
            Unavailable(),
            ValueError("x"),
            None,
            [],
            {"erro": "FRASE_INVALIDA"},
            {"origem": "outra", "params": {}, "aplicados": [], "nao_aplicados": []},
            {"origem": "llm", "params": "x", "aplicados": [], "nao_aplicados": []},
            {"origem": "llm", "params": {}},
            answer(applied=[1]),
        ]
        for result in broken:
            t = NaturalSearch(FakeLambda(result)).translate("sao silvestre")
            self.assertEqual(
                (t.source, t.filters, t.applied),
                ("text", {"q": "sao silvestre"}, ("texto",)),
                result,
            )

    def test_empty_period_is_reported_without_filters(self):
        t = NaturalSearch(FakeLambda(answer(empty=True, applied=["periodo_inicio"]))).translate("x")
        self.assertTrue(t.empty)


class InvokerTests(unittest.TestCase):
    def client(self, **result):
        client = Mock()
        client.invoke.return_value = {
            "StatusCode": 200,
            "Payload": io.BytesIO(json.dumps(answer({"state": "SP"})).encode()),
            **result,
        }
        return client

    def test_invokes_the_named_function_synchronously(self):
        client = self.client()
        out = LambdaSearchInvoker(client, "fn-ficticia")({"frase": "x"})
        self.assertEqual(out["params"], {"state": "SP"})
        kwargs = client.invoke.call_args.kwargs
        self.assertEqual(kwargs["FunctionName"], "fn-ficticia")
        self.assertEqual(kwargs["InvocationType"], "RequestResponse")
        self.assertEqual(json.loads(kwargs["Payload"]), {"frase": "x"})

    def test_function_error_status_aws_error_and_bad_payload_become_unavailable(self):
        bad = [
            self.client(FunctionError="Unhandled"),
            self.client(StatusCode=500),
            self.client(Payload=io.BytesIO(b"nao e json")),
        ]
        denied = Mock()
        denied.invoke.side_effect = ClientError({"Error": {"Code": "AccessDenied"}}, "Invoke")
        for client in [*bad, denied]:
            with self.assertRaises(Unavailable):
                LambdaSearchInvoker(client, "fn")({"frase": "x"})


class SearchRouteTests(unittest.TestCase):
    def setUp(self):
        self.identity = IdentityService(
            MemoryStore(), b"synthetic-only-hmac-key-32-bytes!!", lambda: NOW
        )
        self.actor = Principal("runner", True)
        self.catalog = CatalogService(self.identity, Fernet.generate_key())
        seed_synthetic(self.catalog, ROOT / "backend/fixtures/catalog.synthetic.json")
        self.contract = json.loads((ROOT / "PDLC/M4/API-RunPass-v1.openapi.json").read_text())
        self.headers = {"Authorization": "Bearer synthetic"}
        self.identity.create_profile(
            self.actor, "create", {"displayName": "Runner", "username": "runner"}
        )

    def client(self, result="semfn"):
        def verify(token):
            if token != "synthetic":
                raise AuthFailure()
            return self.actor

        self.fake = None if result == "semfn" else FakeLambda(result)
        search = NaturalSearch(self.fake) if self.fake else None
        return TestClient(create_app(self.identity, verify, self.catalog, natural_search=search))

    def valid(self, body):
        OAS30Validator(
            self.contract["components"]["schemas"]["EditionSearchPage"],
            resolver=RefResolver.from_schema(self.contract),
        ).validate(body)

    def search(self, client, **params):
        return client.get("/editions/search", params=params, headers=self.headers)

    def test_needs_login_and_admission(self):
        client = self.client(answer())
        self.assertEqual(client.get("/editions/search?phrase=x").status_code, 401)
        self.assertEqual(self.search(client, phrase="x").status_code, 403)

    def test_phrase_becomes_filters_and_response_matches_the_contract(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(
            answer(
                {"state": "SP", "distanceKm": 21.0975},
                applied=["uf", "distancia_km"],
                not_applied=["altimetria"],
            )
        )
        response = self.search(client, phrase="meia maratona plana em SP")
        self.assertEqual(response.status_code, 200, response.text)
        body = response.json()
        self.valid(body)
        self.assertEqual([e["id"] for e in body["items"]], ["synthetic-sp-2026"])
        self.assertEqual(body["search"]["source"], "llm")
        self.assertEqual(body["search"]["notApplied"], ["altimetria"])
        self.assertEqual(body["search"]["applied"], ["uf", "distancia_km"])
        self.assertNotIn("limit", body["search"]["filters"])

    def test_only_the_phrase_leaves_the_backend(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer())
        self.search(client, phrase="  10k   perto  de mim ", lat=-23.5, lon=-46.6)
        self.assertEqual(
            self.fake.payloads, [{"frase": "10k perto de mim", "lat": -23.5, "lng": -46.6}]
        )

    def test_lambda_down_or_unconfigured_falls_back_to_name_search(self):
        self.identity.admit(self.actor, "admit", ADULT)
        for client in (self.client(Unavailable()), self.client("semfn")):
            response = self.search(client, phrase="Sintética Arquivada")
            self.assertEqual(response.status_code, 200, response.text)
            body = response.json()
            self.valid(body)
            self.assertEqual(body["search"]["source"], "text")
            self.assertEqual(body["search"]["filters"], {"q": "sintetica arquivada"})
            self.assertEqual([e["id"] for e in body["items"]], ["synthetic-archived"])

    def test_filters_from_the_ai_outside_catalog_limits_fall_back_instead_of_failing(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer({"state": "BAD", "distanceKm": -5}))
        response = self.search(client, phrase="sintetica")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["search"]["source"], "text")

    def test_contradictory_phrase_returns_an_empty_page_without_querying_the_catalog(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer(empty=True, applied=["periodo_inicio"]))
        body = self.search(client, phrase="futuras de 2020").json()
        self.valid(body)
        self.assertEqual((body["items"], body["search"]["filters"]), ([], {}))

    def test_invalid_input_is_rejected(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer())
        for params in (
            {},
            {"phrase": ""},
            {"phrase": "   "},
            {"phrase": "a" * 201},
            {"phrase": "x", "lat": -23.5},
            {"phrase": "x", "lon": -46.6},
            {"phrase": "x", "lat": 999, "lon": 0},
            {"phrase": "x", "limit": 101},
        ):
            self.assertEqual(self.search(client, **params).status_code, 422, params)
        self.assertEqual(self.fake.payloads, [])

    def test_next_pages_use_the_regular_list_with_the_returned_filters(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer({"state": "SP"}))
        first = self.search(client, phrase="corridas em sp", limit=2).json()
        self.assertEqual(len(first["items"]), 2)
        self.assertIn("nextCursor", first)
        second = client.get(
            "/editions",
            params={**first["search"]["filters"], "limit": 2, "cursor": first["nextCursor"]},
            headers=self.headers,
        )
        self.assertEqual(second.status_code, 200, second.text)
        seen = [e["id"] for e in first["items"]] + [e["id"] for e in second.json()["items"]]
        self.assertEqual(len(seen), len(set(seen)))

    def test_search_route_is_not_swallowed_by_the_edition_detail_route(self):
        self.identity.admit(self.actor, "admit", ADULT)
        client = self.client(answer())
        self.assertEqual(self.search(client, phrase="x").status_code, 200)
        self.assertEqual(
            client.get("/editions/synthetic-sp-2024", headers=self.headers).status_code, 200
        )
