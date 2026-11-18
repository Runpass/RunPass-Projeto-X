import unittest

from dynamo_fake import SerializingDynamoStore


class BatchGetTests(unittest.TestCase):
    def test_leitura_em_lote_usa_so_getitem_e_devolve_ausentes(self):
        # O papel da Lambda nao tem BatchGetItem: o fake recusa essa chamada, como a AWS recusou no DEV.
        store = SerializingDynamoStore()
        keys = [("catalog", f"EDITION#e{i}", "HEAD") for i in range(30)]
        store.commit({k: None for k in keys[:20]}, {k: {"version": 1} for k in keys[:20]})
        found = store.batch_get(keys + [("semtabela", "X", "Y")])
        self.assertEqual(sum(1 for k in keys[:20] if found[k]["version"] == 1), 20)
        self.assertTrue(all(found[k] is None for k in keys[20:]))
        self.assertIsNone(found[("semtabela", "X", "Y")])


if __name__ == "__main__":
    unittest.main()
