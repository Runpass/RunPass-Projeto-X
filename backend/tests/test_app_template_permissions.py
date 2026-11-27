"""O papel da Lambda da API precisa das acoes que o codigo usa de verdade no DynamoDB (o MemoryStore dos
testes nao tem IAM, entao a falta de permissao so aparecia no DEV como 503)."""

import pathlib
import unittest

import yaml

TEMPLATE = pathlib.Path(__file__).resolve().parents[2] / "infra" / "app.template.yaml"


class _CfnLoader(yaml.SafeLoader):
    pass


def _tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return {suffix: loader.construct_sequence(node, deep=True)}
    return {suffix: loader.construct_mapping(node, deep=True)}


_CfnLoader.add_multi_constructor("!", _tag)


def _actions_on(statements, table_export):
    actions = set()
    for statement in statements:
        if not isinstance(statement, dict) or statement.get("Effect") != "Allow":
            continue
        if table_export not in repr(statement.get("Resource")):
            continue
        action = statement["Action"]
        actions.update([action] if isinstance(action, str) else action)
    return actions


class ApiRoleTests(unittest.TestCase):
    def setUp(self):
        template = yaml.load(TEMPLATE.read_text(), Loader=_CfnLoader)
        policy = template["Resources"]["ApiFunctionRole"]["Properties"]["Policies"][0]
        self.statements = policy["PolicyDocument"]["Statement"]

    def test_runner_distance_can_write_catalog_without_delete(self):
        actions = _actions_on(self.statements, "-CatalogTable")
        # add_runner_distance -> CatalogImporter.put: GetItem/Query para ler, transacao com Put e
        # ConditionCheck para gravar.
        self.assertLessEqual(
            {
                "dynamodb:GetItem",
                "dynamodb:Query",
                "dynamodb:PutItem",
                "dynamodb:ConditionCheckItem",
            },
            actions,
        )
        self.assertNotIn("dynamodb:DeleteItem", actions)


if __name__ == "__main__":
    unittest.main()
