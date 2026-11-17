import unittest
from unittest import mock

from runpass import admin_entry


class AdminEntryTests(unittest.TestCase):
    def test_evento_da_regra_horaria_roda_o_importe_e_nao_a_api(self):
        auto = mock.Mock()
        auto.run.return_value = {"created": 2}
        with (
            mock.patch.object(admin_entry, "_auto_import", return_value=auto),
            mock.patch.object(admin_entry, "_admin") as api,
        ):
            self.assertEqual(admin_entry.handler({"autoImport": True}, None), {"created": 2})
        auto.run.assert_called_once_with("schedule")
        api.assert_not_called()

    def test_evento_de_ingestao_da_esteira_grava_descobertas_e_nao_chama_a_api(self):
        disc = mock.Mock()
        disc.ingest.return_value = {"counts": {"created": 1}}
        evento = {"discoveryIngest": {"items": [{"name": "x"}], "batchId": "lote-1"}}
        with (
            mock.patch.object(admin_entry, "_discoveries", return_value=disc),
            mock.patch.object(admin_entry, "_admin") as api,
        ):
            self.assertEqual(admin_entry.handler(evento, None), {"counts": {"created": 1}})
        disc.ingest.assert_called_once_with([{"name": "x"}], "api", "lote-1")
        api.assert_not_called()

    def test_ingestao_so_vale_como_objeto_e_so_no_evento_do_lambda(self):
        for event in ({"discoveryIngest": True}, {"discoveryIngest": "x"}, {"body": "{}"}):
            api = mock.Mock(return_value={"statusCode": 200})
            with (
                mock.patch.object(admin_entry, "_admin", return_value=api),
                mock.patch.object(admin_entry, "_discoveries") as disc,
            ):
                admin_entry.handler(event, None)
            disc.assert_not_called()

    def test_chamada_http_e_qualquer_outro_evento_seguem_para_a_api(self):
        for event in (
            {"requestContext": {}},
            {"autoImport": False},
            {"autoImport": "true"},
            "texto",
        ):
            api = mock.Mock(return_value={"statusCode": 200})
            with (
                mock.patch.object(admin_entry, "_admin", return_value=api),
                mock.patch.object(admin_entry, "_auto_import") as auto,
            ):
                self.assertEqual(admin_entry.handler(event, None), {"statusCode": 200})
            auto.assert_not_called()


if __name__ == "__main__":
    unittest.main()
