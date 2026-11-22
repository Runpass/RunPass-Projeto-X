import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "load_test", Path(__file__).resolve().parents[2] / "scripts" / "load_test.py"
)
load_test = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(load_test)


class PercentileTests(unittest.TestCase):
    def test_nearest_rank(self):
        values = list(range(1, 101))
        self.assertEqual(load_test.percentile(values, 50), 50)
        self.assertEqual(load_test.percentile(values, 95), 95)
        self.assertEqual(load_test.percentile(values, 99), 99)
        self.assertEqual(load_test.percentile(values, 100), 100)

    def test_small_and_empty(self):
        self.assertEqual(load_test.percentile([], 95), 0)
        self.assertEqual(load_test.percentile([7], 95), 7)
        self.assertEqual(load_test.percentile([3, 1, 2], 50), 2)


class AbortTests(unittest.TestCase):
    def test_no_decision_with_few_responses(self):
        self.assertIsNone(load_test.should_abort(["servidor"] * 10, 0.05, 0.5))

    def test_server_failures_stop_the_run(self):
        recent = ["ok"] * 90 + ["servidor"] * 10
        self.assertIn("falhas", load_test.should_abort(recent, 0.05, 0.5))
        self.assertIsNone(load_test.should_abort(recent, 0.2, 0.5))

    def test_throttling_is_not_a_server_failure_but_can_stop(self):
        recent = ["ok"] * 40 + ["limite"] * 60
        reason = load_test.should_abort(recent, 0.05, 0.5)
        self.assertIn("429", reason)
        self.assertIsNone(load_test.should_abort(["ok"] * 80 + ["limite"] * 20, 0.05, 0.5))

    def test_rejected_token_stops_even_early(self):
        self.assertIn("token", load_test.should_abort(["auth"] * 10, 0.05, 0.5))
        self.assertIsNone(load_test.should_abort(["auth"] * 9, 0.05, 0.5))


class SummaryTests(unittest.TestCase):
    def records(self, status=200, ms=100, n=100, route="Inicio"):
        return [(route, status, ms, 0.0) for _ in range(n)]

    def test_all_good_is_approved(self):
        summary = load_test.summarize(self.records(), 10)
        self.assertEqual(summary["achievedPerSecond"], 10)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 10, None)}
        self.assertEqual(set(states.values()), {"APROVADO"})

    def test_slow_route_fails_the_spec_goal(self):
        summary = load_test.summarize(self.records(ms=1500), 10)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 10, None)}
        self.assertEqual(states["Rota Inicio"], "FALHA")

    def test_throttled_requests_fail_capacity_and_do_not_count_as_fast(self):
        records = self.records(n=50) + self.records(status=429, ms=5, n=50)
        summary = load_test.summarize(records, 10)
        self.assertEqual(summary["total"]["limite429"], 50)
        self.assertEqual(summary["total"]["servidor5xx"], 0)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 10, None)}
        self.assertEqual(states["Limite de taxa (429)"], "FALHA")
        self.assertEqual(states["Erros de servidor e rede"], "APROVADO")
        self.assertEqual(summary["total"]["p50Ms"], 100)  # so respostas 2xx entram nos tempos

    def test_route_without_success_is_not_run_and_empty_run_is_not_approved(self):
        summary = load_test.summarize(self.records(status=500, n=10), 5)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 2, None)}
        self.assertEqual(states["Rota Inicio"], "NAO EXECUTADO")
        self.assertEqual(states["Erros de servidor e rede"], "FALHA")
        empty = load_test.summarize([], 5)
        self.assertEqual(load_test.verdicts(empty, 2, None)[0][1], "NAO EXECUTADO")

    def test_aborted_run_fails(self):
        summary = load_test.summarize(self.records(), 10)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 10, "parou")}
        self.assertEqual(states["Execucao"], "FALHA")

    def test_saturated_generator_is_flagged(self):
        records = [("Inicio", 200, 100, 900.0) for _ in range(100)]
        summary = load_test.summarize(records, 10)
        states = {name: state for name, state, _ in load_test.verdicts(summary, 10, None)}
        self.assertEqual(states["Gerador de carga"], "FALHA")


class TargetTests(unittest.TestCase):
    def test_loopback_needs_no_authorization(self):
        self.assertIsNone(load_test.check_target("http://127.0.0.1:8000", False))
        self.assertIsNone(load_test.check_target("http://localhost:8000", False))

    def test_real_service_needs_https_and_authorization(self):
        self.assertIn("autorizado", load_test.check_target("https://api.exemplo", False))
        self.assertIn("HTTPS", load_test.check_target("http://api.exemplo", True))
        self.assertIsNone(load_test.check_target("https://api.exemplo", True))
        self.assertIsNotNone(load_test.check_target("api.exemplo", True))

    def test_plan_cycles_routes_and_fills_the_edition(self):
        plan = load_test.build_plan("ed-1", 30)
        self.assertEqual(len(plan), 30)
        self.assertTrue(any(path == "/editions/ed-1" for _, path in plan))
        self.assertFalse(any("{edition}" in path for _, path in plan))
        self.assertFalse(any(path.startswith("/editions/search") for _, path in plan))
        self.assertTrue(all(path.startswith("/") for _, path in plan))


if __name__ == "__main__":
    unittest.main()
