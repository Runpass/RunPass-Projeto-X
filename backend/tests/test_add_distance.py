import unittest
from decimal import Decimal

from pydantic import ValidationError
from runpass.models import AddDistance


class AddDistanceTest(unittest.TestCase):
    """O corpo chega como dict (como o FastAPI valida): numero ou texto com o km viram Decimal."""

    def test_accepts_number_or_text(self):
        for raw, expected in ((10, "10"), (21.1, "21.1"), ("10", "10"), ("21,1", "21.1")):
            with self.subTest(raw=raw):
                body = AddDistance.model_validate({"kilometers": raw})
                self.assertEqual(body.kilometers, Decimal(expected))

    def test_rejects_invalid(self):
        for raw in (True, "abc", 0, -5, 1001, None, [10]):
            with self.subTest(raw=raw):
                with self.assertRaises(ValidationError):
                    AddDistance.model_validate({"kilometers": raw})


if __name__ == "__main__":
    unittest.main()
