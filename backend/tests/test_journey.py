"""Jornada completa de uso (criar usuario ... excluir conta) com banco no formato do DynamoDB e as
permissoes do papel da Lambda da API lidas do template: uma operacao que o papel real negaria vira falha
aqui. A mesma jornada, com relatorio, roda por `scripts/journey_probe.py`."""

import importlib.util
import unittest
from pathlib import Path

PROBE = Path(__file__).resolve().parents[2] / "scripts" / "journey_probe.py"


def load_probe():
    spec = importlib.util.spec_from_file_location("journey_probe", PROBE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class JourneyTests(unittest.TestCase):
    def test_every_step_works_and_the_api_role_denies_nothing(self):
        journey = load_probe().Journey()
        journey.run()
        failed = [(name, status, detail) for name, status, ok, detail in journey.steps if not ok]
        self.assertEqual(failed, [])
        self.assertEqual(journey.client_db.denied, [])
        self.assertGreater(len(journey.steps), 90)  # a jornada nao encolheu em silencio

    def test_role_permissions_come_from_the_template(self):
        allowed = load_probe().role_permissions()
        self.assertIn("dynamodb:PutItem", allowed["catalog"])  # km informado pelo corredor
        self.assertNotIn("dynamodb:DeleteItem", allowed["catalog"])  # a API nunca apaga do catalogo
        self.assertEqual(allowed["projections"], {"dynamodb:GetItem"})


if __name__ == "__main__":
    unittest.main()
