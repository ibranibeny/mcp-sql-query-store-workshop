import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DAB_CONFIG = ROOT / "mcp" / "dab-config.json"
MCP_CONFIG = ROOT / ".vscode" / "mcp.json"
EXTENSIONS_CONFIG = ROOT / ".vscode" / "extensions.json"
ENV_EXAMPLE = ROOT / "mcp" / ".env.example"
README = ROOT / "mcp" / "README.md"
COPILOT_INSTRUCTIONS = ROOT / ".github" / "copilot-instructions.md"

VIEW_ENTITIES = {
    "WorkshopRunSummary": "lab.vw_WorkshopRunSummary",
    "WorkshopSampleSummary": "lab.vw_WorkshopSampleSummary",
}
PROCEDURE_ENTITIES = {
    "GetMemorySnapshot": "lab.usp_GetMemorySnapshot",
    "GetActiveWorkshopGrants": "lab.usp_GetActiveWorkshopGrants",
    "GetQueryStoreTopQueries": "lab.usp_GetQueryStoreTopQueries",
    "GetQueryStoreWaits": "lab.usp_GetQueryStoreWaits",
    "GetProcedurePlanSummary": "lab.usp_GetProcedurePlanSummary",
    "CompareWorkshopRuns": "lab.usp_CompareWorkshopRuns",
}
CUSTOM_TOOL_NAMES = {
    "get_memory_snapshot",
    "get_active_workshop_grants",
    "get_query_store_top_queries",
    "get_query_store_waits",
    "get_procedure_plan_summary",
    "compare_workshop_runs",
}
RECOMMENDED_EXTENSIONS = {
    "ms-mssql.mssql",
    "GitHub.copilot",
    "GitHub.copilot-chat",
    "ms-vscode.powershell",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def actions(entity: dict) -> list:
    return [
        action["action"] if isinstance(action, dict) else action
        for permission in entity["permissions"]
        for action in permission["actions"]
    ]


def test_dab_config_has_only_documented_top_level_and_runtime_properties():
    config = load_json(DAB_CONFIG)
    assert set(config) == {"$schema", "data-source", "runtime", "entities"}
    assert re.fullmatch(
        r"https://github\.com/Azure/data-api-builder/releases/download/v2\.[^/]+/dab\.draft\.schema\.json",
        config["$schema"],
    )
    assert set(config["data-source"]) <= {"database-type", "connection-string", "options"}
    assert set(config["runtime"]) == {"rest", "graphql", "mcp"}
    assert set(config["runtime"]["mcp"]) == {"enabled", "path", "description", "dml-tools"}


def test_dab_runtime_is_mssql_mcp_only_and_read_only():
    config = load_json(DAB_CONFIG)
    assert config["data-source"]["database-type"] == "mssql"
    assert config["data-source"]["connection-string"] == "@env('MSSQL_CONNECTION_STRING')"
    assert config["runtime"]["rest"] == {"enabled": False}
    assert config["runtime"]["graphql"] == {"enabled": False}

    mcp = config["runtime"]["mcp"]
    assert mcp["enabled"] is True
    assert mcp["path"] == "/mcp"
    assert mcp["description"].strip()
    assert mcp["dml-tools"] == {
        "describe-entities": True,
        "create-record": False,
        "read-records": True,
        "update-record": False,
        "delete-record": False,
        "execute-entity": True,
        "aggregate-records": {"enabled": True, "query-timeout": 30},
    }


def test_exact_entity_allowlist_sources_and_types():
    entities = load_json(DAB_CONFIG)["entities"]
    expected = VIEW_ENTITIES | PROCEDURE_ENTITIES
    assert set(entities) == set(expected)
    for name, source_object in expected.items():
        entity = entities[name]
        assert entity["source"]["object"] == source_object
        assert entity["source"]["type"] == (
            "view" if name in VIEW_ENTITIES else "stored-procedure"
        )
        assert set(entity) <= {
            "description", "source", "fields", "permissions", "mcp", "rest", "graphql"
        }
        assert entity["rest"] == {"enabled": False}
        assert entity["graphql"] == {"enabled": False}


def test_views_are_explicit_read_only_entities_with_primary_keys_and_fields():
    entities = load_json(DAB_CONFIG)["entities"]
    expected_keys = {
        "WorkshopRunSummary": {"RunID"},
        "WorkshopSampleSummary": {"RunID", "SampleSequence"},
    }
    for name in VIEW_ENTITIES:
        entity = entities[name]
        assert actions(entity) == ["read"]
        assert entity["permissions"] == [
            {
                "role": "workshop-reader",
                "actions": [
                    {
                        "action": "read",
                        "fields": {"include": [field["name"] for field in entity["fields"]]},
                    }
                ],
            }
        ]
        assert entity["mcp"] == {"dml-tools": True, "custom-tool": False}
        assert {field["name"] for field in entity["fields"] if field.get("primary-key")} == expected_keys[name]
        assert "key-fields" not in entity["source"]


def test_procedures_are_execute_only_custom_tools_with_documented_parameters():
    entities = load_json(DAB_CONFIG)["entities"]
    for name in PROCEDURE_ENTITIES:
        entity = entities[name]
        assert actions(entity) == ["execute"]
        assert entity["permissions"] == [
            {"role": "workshop-reader", "actions": ["execute"]}
        ]
        assert entity["mcp"] == {"dml-tools": True, "custom-tool": True}
        assert "bounds" in entity["description"].lower() or "no parameters" in entity["description"].lower()
        for parameter in entity["source"].get("parameters", []):
            assert set(parameter) <= {"name", "required", "default", "description"}
            assert parameter["name"].strip()
            assert parameter["description"].strip()
            assert isinstance(parameter["required"], bool)

    derived_names = {
        re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower() for name in PROCEDURE_ENTITIES
    }
    assert derived_names == CUSTOM_TOOL_NAMES


def test_every_entity_and_configured_field_has_a_description():
    for entity in load_json(DAB_CONFIG)["entities"].values():
        assert entity["description"].strip()
        assert entity["source"]["object-description"].strip()
        assert entity["fields"]
        names = [field["name"] for field in entity["fields"]]
        assert len(names) == len(set(names))
        for field in entity["fields"]:
            assert set(field) <= {"name", "alias", "description", "primary-key"}
            assert field["name"].strip()
            assert field["description"].strip()


def test_no_anonymous_or_write_permissions_exist():
    config = load_json(DAB_CONFIG)
    serialized = json.dumps(config).lower()
    assert '"anonymous"' not in serialized
    for entity in config["entities"].values():
        roles = [permission["role"] for permission in entity["permissions"]]
        assert roles == ["workshop-reader"]
        assert not {"create", "update", "delete", "*"}.intersection(actions(entity))


def test_vscode_uses_exact_local_stdio_invocation():
    config = load_json(MCP_CONFIG)
    assert set(config) == {"servers"}
    assert set(config["servers"]) == {"mcp-sql-query-store-workshop"}
    server = config["servers"]["mcp-sql-query-store-workshop"]
    assert server == {
        "type": "stdio",
        "command": "dab",
        "args": [
            "start",
            "--mcp-stdio",
            "role:workshop-reader",
            "--config",
            "${workspaceFolder}/mcp/dab-config.json",
            "--LogLevel",
            "error",
        ],
    }
    assert server["args"].index("role:workshop-reader") == server["args"].index("--mcp-stdio") + 1
    assert not any("port" in argument.lower() or "://" in argument for argument in server["args"])


def test_environment_example_is_explicit_noncredential_private_dns_placeholder():
    lines = [line for line in ENV_EXAMPLE.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert lines == [
        "MSSQL_CONNECTION_STRING=Server=sql01.mcpworkshop.internal,1433;Database=AdventureWorks2022;"
        "User ID=mcp_workshop_reader;Password=SET_LOCALLY_ON_ADMIN_VM;Encrypt=True;"
        "TrustServerCertificate=False;HostNameInCertificate=sql01.mcpworkshop.internal;"
        "Application Name=MCP-SQL-Workshop-MCP"
    ]
    assert "SET_LOCALLY_ON_ADMIN_VM" in lines[0]
    assert not re.search(r"Password=(?!SET_LOCALLY_ON_ADMIN_VM(?:;|$))[^;]+", lines[0], re.I)


def test_no_embedded_secret_or_http_server_configuration():
    config_text = DAB_CONFIG.read_text(encoding="utf-8")
    vscode_text = MCP_CONFIG.read_text(encoding="utf-8")
    assert not re.search(r"(?i)(password|pwd)\s*=", config_text)
    assert not re.search(r"(?i)\"(url|uri|port)\"\s*:", config_text + vscode_text)
    assert "--port" not in vscode_text.lower()
    assert "http://localhost" not in vscode_text.lower()


def test_extensions_are_exactly_the_supported_recommendations():
    assert load_json(EXTENSIONS_CONFIG) == {"recommendations": sorted(RECOMMENDED_EXTENSIONS)}


def test_readme_documents_local_secret_and_validation_workflow():
    text = README.read_text(encoding="utf-8")
    for required in (
        "DAB 2.0",
        "MCP protocol 2025-06-18",
        "dab validate --config mcp/dab-config.json",
        "MCP: List Servers",
        "root `.env`",
        "current directory",
        "SET_LOCALLY_ON_ADMIN_VM",
        "ACL",
        "no HTTP listener",
        "describe_entities",
    ):
        assert required in text
    assert "envFile" not in MCP_CONFIG.read_text(encoding="utf-8")


def test_copilot_instructions_enforce_evidence_and_safety_policy():
    text = COPILOT_INSTRUCTIONS.read_text(encoding="utf-8")
    headings = (
        "Observations",
        "Missing evidence",
        "Hypotheses (ranked)",
        "Experiments",
        "Candidate changes",
        "Risks and rollback",
        "Validation",
    )
    for heading in headings:
        assert heading in text
    lower = text.lower()
    for required in (
        "primary goal",
        "optimize",
        "query store",
        "dmv",
        "never claim target",
        "never execute ddl",
        "never execute write",
        "correctness",
        "no public endpoint",
    ):
        assert required in lower
