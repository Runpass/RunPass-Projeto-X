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
