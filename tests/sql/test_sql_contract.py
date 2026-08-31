from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "sql"
GO_LINE = re.compile(r"(?im)^\s*GO(?:\s+\d+)?\s*(?:--.*)?$")


def sql(name: str) -> str:
    return (SQL_DIR / name).read_text(encoding="utf-8")


def batches(name: str) -> list[str]:
    return [batch.strip() for batch in GO_LINE.split(sql(name)) if batch.strip()]


def normalized(name: str) -> str:
    text = sql(name)
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    text = re.sub(r"--[^\r\n]*", " ", text)
    return re.sub(r"\s+", " ", text).upper()


def batch_index(name: str, pattern: str) -> int:
    expression = re.compile(pattern, re.IGNORECASE | re.DOTALL)
    return next(index for index, batch in enumerate(batches(name)) if expression.search(batch))


def test_preflight_is_sqlcmd_parameterized() -> None:
    text = sql("00-Preflight.sql")
    assert ":on error exit" in text.lower()
    required = {
        "ExpectedServerName",
        "DatabaseName",
        "ExpectedPhysicalMemoryMB",
        "PreflightPhase",
    }
    assert required.issubset(set(re.findall(r"\$\((\w+)\)", text)))


def test_preflight_rejects_wrong_phase_before_phase_specific_checks() -> None:
    text = normalized("00-Preflight.sql")
    assert "N'INFRASTRUCTURE'" in text and "N'LAB'" in text
    assert re.search(r"NOT\s+IN\s*\(\s*N'INFRASTRUCTURE'\s*,\s*N'LAB'\s*\).*?THROW", text)
    phase_guard = text.index("NOT IN")
    assert phase_guard < text.index("DB_ID")


def test_preflight_requires_exact_sql_2022_enterprise_contract() -> None:
    text = normalized("00-Preflight.sql")
    assert "SERVERPROPERTY('PRODUCTMAJORVERSION')" in text
    assert re.search(r"PRODUCTMAJORVERSION.*?<>\s*16.*?THROW", text)
    assert "SERVERPROPERTY('EDITION')" in text
    assert re.search(r"EDITION.*?NOT LIKE.*?ENTERPRISE.*?THROW", text)


def test_preflight_validates_physical_memory_bounds_and_expected_value() -> None:
    text = normalized("00-Preflight.sql")
    assert "SYS.DM_OS_SYS_INFO" in text and "PHYSICAL_MEMORY_KB" in text
    assert "63000" in text and "66000" in text
    assert "EXPECTEDPHYSICALMEMORYMB" in text
    assert len(re.findall(r"\bTHROW\b", text)) >= 10


def test_preflight_normalizes_expected_machine_or_server_name() -> None:
    text = normalized("00-Preflight.sql")
    assert "SERVERPROPERTY('MACHINENAME')" in text
    assert "SERVERPROPERTY('SERVERNAME')" in text
    assert "LOWER(" in text and "LTRIM(" in text and "RTRIM(" in text
    assert "CHARINDEX(N'.'" in text and "CHARINDEX(N'\\'" in text
    assert re.search(r"EXPECTEDSERVERNAME.*?(MACHINENAME|SERVERNAME).*?THROW", text)


def test_preflight_has_explicit_infrastructure_and_lab_paths() -> None:
    text = normalized("00-Preflight.sql")
    assert re.search(r"PREFLIGHTPHASE.*?=\s*N'LAB'.*?DB_ID.*?THROW", text)
    assert "LAB.WORKSHOPMARKER" in text
    assert "MCP_SQL_WORKSHOP" in text
    assert "EXTENDED_PROPERTIES" in text
    assert re.search(r"PREFLIGHTPHASE.*?=\s*N'INFRASTRUCTURE'", text)


def test_preflight_checks_optional_restore_and_data_path_free_space() -> None:
    text = normalized("00-Preflight.sql")
    assert "PLANNEDRESTOREPATH" in text and "PLANNEDDATAPATH" in text
    assert "XP_FIXEDDRIVES" in text
    assert "MINIMUMFREESPACEMB" in text
    assert "SUBSTRING(@PLANNEDRESTOREPATH, 3, 1)" in text
    assert "SUBSTRING(@PLANNEDDATAPATH, 3, 1)" in text
    assert re.search(r"FREE_MB.*?MINIMUMFREESPACEMB.*?THROW", text)


def test_preflight_is_read_only_rerunnable_and_returns_one_bounded_result() -> None:
    text = normalized("00-Preflight.sql")
    forbidden = (
        "CREATE DATABASE",
        "CREATE TABLE",
        "INSERT INTO",
        "UPDATE ",
        "DELETE ",
        "MERGE ",
        "DROP ",
        "SP_ADDEXTENDEDPROPERTY",
        "SP_UPDATEEXTENDEDPROPERTY",
    )
    assert not any(token in text for token in forbidden)
    assert text.count("SELECT N'PREFLIGHTPASSED'") == 1
    assert "TOP (" not in text


def test_configuration_is_sqlcmd_parameterized_and_uses_owned_utility_database() -> None:
    text = sql("01-ConfigureInstance.sql")
    assert ":on error exit" in text.lower()
    assert {"DatabaseName", "ExpectedServerName"}.issubset(set(re.findall(r"\$\((\w+)\)", text)))
    upper = normalized("01-ConfigureInstance.sql")
    assert "CREATE DATABASE [WORKSHOPADMIN]" in upper
    assert "MCP_SQL_WORKSHOP" in upper and "EXTENDED_PROPERTIES" in upper
    assert re.search(r"IF.*?WORKSHOPADMIN.*?EXISTS.*?THROW", upper)


def test_configuration_backup_is_versioned_and_first_capture_wins() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "WORKSHOPADMIN.DBO.CONFIGURATIONBACKUP" in text
    assert "MARKERID" in text and "SCHEMAVERSION" in text
    assert "MAX SERVER MEMORY (MB)" in text and "MIN SERVER MEMORY (MB)" in text
    assert "CLASSIFIER_FUNCTION_ID" in text and "IS_ENABLED" in text
    insert = re.search(
        r"IF\s+NOT\s+EXISTS.*?CONFIGURATIONBACKUP.*?INSERT\s+INTO\s+WORKSHOPADMIN\.DBO\.CONFIGURATIONBACKUP",
        text,
    )
    assert insert, "the initial backup must be insert-once, never an overwrite"
    assert not re.search(r"UPDATE\s+WORKSHOPADMIN\.DBO\.CONFIGURATIONBACKUP", text)


def test_database_backup_captures_query_store_and_memory_grant_feedback_once() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "DATABASECONFIGURATIONBACKUP" in text
    assert "SYS.DATABASE_QUERY_STORE_OPTIONS" in text
    for setting in (
        "ROW_MODE_MEMORY_GRANT_FEEDBACK",
        "BATCH_MODE_MEMORY_GRANT_FEEDBACK",
        "MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT",
        "MEMORY_GRANT_FEEDBACK_PERSISTENCE",
    ):
        assert setting in text
    assert re.search(r"DB_ID\(@DATABASENAME\)\s+IS NOT NULL.*?(?:AND\s+)?NOT\s+EXISTS.*?DATABASECONFIGURATIONBACKUP", text)
    assert not re.search(r"UPDATE\s+WORKSHOPADMIN\.DBO\.DATABASECONFIGURATIONBACKUP", text)


def test_memory_grant_feedback_is_disabled_only_in_existing_target_database() -> None:
    text = normalized("01-ConfigureInstance.sql")
    guarded_bodies = re.findall(
        r"IF\s+DB_ID\s*\(.*?\)\s+IS\s+NOT\s+NULL(?P<body>.*?)END",
        text,
    )
    disabling_body = next(body for body in guarded_bodies if "ALTER DATABASE SCOPED CONFIGURATION" in body)
    assert "ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = OFF" in disabling_body
    assert "ALTER DATABASE SCOPED CONFIGURATION SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = OFF" in disabling_body


def test_server_memory_is_configured_and_effectively_read_back() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "SP_CONFIGURE N'SHOW ADVANCED OPTIONS', 1" in text
    assert "SP_CONFIGURE N'MAX SERVER MEMORY (MB)', 49152" in text
    assert "SP_CONFIGURE N'MIN SERVER MEMORY (MB)', 0" in text
    assert text.count("RECONFIGURE") >= 3
    assert re.search(r"SYS\.CONFIGURATIONS.*?VALUE_IN_USE.*?49152.*?THROW", text)
    assert re.search(r"SYS\.CONFIGURATIONS.*?VALUE_IN_USE.*?0.*?THROW", text)


def test_resource_governor_objects_have_exact_limits_and_idempotency_guards() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "RESOURCEGOVERNOROBJECTOWNERSHIP" in text
    assert re.search(r"RESOURCE_GOVERNOR_RESOURCE_POOLS.*?NOT EXISTS.*?RESOURCEGOVERNOROBJECTOWNERSHIP.*?THROW", text)
    assert re.search(r"RESOURCE_GOVERNOR_WORKLOAD_GROUPS.*?NOT EXISTS.*?RESOURCEGOVERNOROBJECTOWNERSHIP.*?THROW", text)
    assert "CREATE RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "ALTER RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "MIN_MEMORY_PERCENT = 0" in text and "MAX_MEMORY_PERCENT = 50" in text
    assert "CREATE WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" in text
    assert "ALTER WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" in text
    assert "REQUEST_MAX_MEMORY_GRANT_PERCENT = 40" in text
    assert "MAX_DOP = 4" in text and "GROUP_MAX_REQUESTS = 4" in text
    assert "SYS.RESOURCE_GOVERNOR_RESOURCE_POOLS" in text
    assert "SYS.RESOURCE_GOVERNOR_WORKLOAD_GROUPS" in text


def test_resource_governor_collisions_are_rejected_before_mutating_configuration() -> None:
    text = normalized("01-ConfigureInstance.sql")
    pool_collision = text.index("A RESOURCE GOVERNOR POOL WITH THE WORKSHOP NAME EXISTS")
    group_collision = text.index("A RESOURCE GOVERNOR WORKLOAD GROUP WITH THE WORKSHOP NAME EXISTS")
    server_memory_change = text.index("SP_CONFIGURE N'MAX SERVER MEMORY (MB)', 49152")
    feedback_change = text.index("ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = OFF")
    assert pool_collision < server_memory_change
    assert group_collision < server_memory_change
    assert pool_collision < feedback_change
    assert group_collision < feedback_change


def test_resource_governor_ownership_is_recorded_only_after_successful_create() -> None:
    text = normalized("01-ConfigureInstance.sql")
    pool_create = text.index("CREATE RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]")
    pool_claim = text.index("(@WORKSHOPMARKER, @WORKSHOPSCHEMAVERSION, 'POOL'")
    group_create = text.index("CREATE WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]")
    group_claim = text.index("(@WORKSHOPMARKER, @WORKSHOPSCHEMAVERSION, 'GROUP'")
    assert pool_create < pool_claim < group_create < group_claim
    assert "SP_GETAPPLOCK" in text and "SP_RELEASEAPPLOCK" in text


def test_classifier_is_schema_bound_exact_and_preserves_non_workshop_classifier() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "CREATE FUNCTION DBO.MCP_SQL_WORKSHOP_CLASSIFIER" in text
    assert "WITH SCHEMABINDING" in text
    assert re.search(r"APP_NAME\(\)\s+LIKE\s+N''?MCP-SQL-WORKSHOP%''?", text)
    assert re.search(r"THEN\s+N''?MCP_SQL_WORKSHOP_GROUP''?", text)
    assert "SYS.RESOURCE_GOVERNOR_CONFIGURATION" in text
    assert "CLASSIFIER_FUNCTION_ID" in text
    assert re.search(r"CLASSIFIER_FUNCTION_ID.*?(<>|!=).*?OBJECT_ID.*?THROW", text)
    assert "ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = DBO.MCP_SQL_WORKSHOP_CLASSIFIER)" in text


def test_resource_governor_ddl_is_outside_user_transactions_and_ordered() -> None:
    parsed = batches("01-ConfigureInstance.sql")
    rg_batches = [
        batch
        for batch in parsed
        if re.search(r"\b(?:CREATE|ALTER)\s+(?:RESOURCE\s+POOL|WORKLOAD\s+GROUP|RESOURCE\s+GOVERNOR)\b", batch, re.I)
    ]
    assert rg_batches
    assert all("BEGIN TRAN" not in batch.upper() for batch in rg_batches)
    backup_index = batch_index("01-ConfigureInstance.sql", r"INSERT\s+INTO\s+WorkshopAdmin\.dbo\.ConfigurationBackup")
    pool_index = batch_index("01-ConfigureInstance.sql", r"CREATE\s+RESOURCE\s+POOL")
    group_index = batch_index("01-ConfigureInstance.sql", r"CREATE\s+WORKLOAD\s+GROUP")
    classifier_index = batch_index("01-ConfigureInstance.sql", r"ALTER\s+RESOURCE\s+GOVERNOR\s+WITH\s*\(\s*CLASSIFIER_FUNCTION")
    reconfigure_index = batch_index("01-ConfigureInstance.sql", r"ALTER\s+RESOURCE\s+GOVERNOR\s+RECONFIGURE")
    assert backup_index < pool_index < group_index < classifier_index < reconfigure_index


def test_classifier_creation_occupies_its_own_batch() -> None:
    function_batches = [batch for batch in batches("01-ConfigureInstance.sql") if "CREATE FUNCTION dbo.mcp_sql_workshop_classifier" in batch]
    assert len(function_batches) == 1
    function_batch = function_batches[0].upper()
    assert "CREATE OR ALTER FUNCTION" not in function_batch
    assert re.search(r"IF\s+OBJECT_ID\s*\(.*?MCP_SQL_WORKSHOP_CLASSIFIER.*?\)\s+IS\s+NULL", function_batch)
    assert "BEGIN TRAN" not in function_batch


def test_effective_resource_governor_values_are_verified_after_reconfigure() -> None:
    text = normalized("01-ConfigureInstance.sql")
    reconfigure = text.index("ALTER RESOURCE GOVERNOR RECONFIGURE")
    effective = text[reconfigure:]
    assert "SYS.DM_RESOURCE_GOVERNOR_RESOURCE_POOLS" in effective
    assert "SYS.DM_RESOURCE_GOVERNOR_WORKLOAD_GROUPS" in effective
    for value in ("MIN_MEMORY_PERCENT", "MAX_MEMORY_PERCENT", "REQUEST_MAX_MEMORY_GRANT_PERCENT", "MAX_DOP", "GROUP_MAX_REQUESTS"):
        assert value in effective
    assert "THROW" in effective


def test_official_microsoft_learn_sources_are_cited() -> None:
    combined = sql("00-Preflight.sql") + sql("01-ConfigureInstance.sql")
    assert "https://learn.microsoft.com/sql/database-engine/configure-windows/server-memory-server-configuration-options" in combined
    assert "https://learn.microsoft.com/sql/relational-databases/resource-governor/resource-governor" in combined


def test_all_sql_is_bounded_and_avoids_destructive_or_public_network_commands() -> None:
    combined = "\n".join(normalized(path.name) for path in SQL_DIR.glob("*.sql"))
    forbidden = (
        r"\bDBCC\s+DROPCLEANBUFFERS\b",
        r"\bDBCC\s+FREEPROCCACHE\b",
        r"\bWHILE\s+1\s*=\s*1\b",
        r"\bDROP\s+(?:DATABASE|LOGIN|ENDPOINT)\b",
        r"\bSHUTDOWN\b",
        r"\bXP_CMDSHELL\b",
        r"\bSP_CONFIGURE\s+N?'REMOTE\s+ACCESS'",
        r"\b(?:CREATE|ALTER)\s+ENDPOINT\b",
        r"\bOPENROWSET\b",
        r"\bOPENDATASOURCE\b",
    )
    assert not any(re.search(pattern, combined) for pattern in forbidden)


@pytest.mark.parametrize("name", ["00-Preflight.sql", "01-ConfigureInstance.sql"])
def test_scripts_use_explicit_throw_numbers_and_no_raiserror(name: str) -> None:
    text = normalized(name)
    assert "RAISERROR" not in text
    throw_numbers = [int(value) for value in re.findall(r"\bTHROW\s+(\d{5}),", text)]
    assert throw_numbers
    assert all(50000 <= value <= 59999 for value in throw_numbers)
