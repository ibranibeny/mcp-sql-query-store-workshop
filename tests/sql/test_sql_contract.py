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


def sqlcmd_substitute(text: str, variables: dict[str, str]) -> str:
    return re.sub(
        r"\$\((\w+)\)",
        lambda match: variables.get(match.group(1), match.group(0)),
        text,
    )


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


def test_preflight_minimal_sqlcmd_invocation_has_no_unresolved_variables() -> None:
    text = sqlcmd_substitute(
        sql("00-Preflight.sql"),
        {
            "ExpectedServerName": "sql01",
            "DatabaseName": "AdventureWorks2022",
            "ExpectedPhysicalMemoryMB": "65536",
            "PreflightPhase": "Infrastructure",
        },
    )
    assert not re.search(r"\$\(\w+\)", text)
    assert "SESSION_CONTEXT(N'MCP_SQL_PlannedRestorePath')" in text
    assert "SESSION_CONTEXT(N'MCP_SQL_PlannedDataPath')" in text
    assert "SESSION_CONTEXT(N'MCP_SQL_MinimumFreeSpaceMB')" in text


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


def test_resource_governor_ownership_is_pending_before_ddl_and_activated_after_success() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "OWNERSHIPSTATE" in text
    pool_pending = text.index("'POOL', N'MCP_SQL_WORKSHOP_POOL', 'PENDING'")
    pool_create = text.index("CREATE RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]", pool_pending)
    pool_active = text.index("SET OWNERSHIPSTATE = 'ACTIVE'", pool_create)
    group_pending = text.index("'GROUP', N'MCP_SQL_WORKSHOP_GROUP', 'PENDING'")
    group_create = text.index("CREATE WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]", group_pending)
    group_active = text.index("SET OWNERSHIPSTATE = 'ACTIVE'", group_create)
    assert pool_pending < pool_create < pool_active
    assert group_pending < group_create < group_active
    assert "@CREATEDPOOL" in text and "@CREATEDGROUP" in text
    assert "SP_GETAPPLOCK" in text and "SP_RELEASEAPPLOCK" in text


def test_pending_resource_governor_ownership_is_recoverable_and_foreign_objects_are_preserved() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert re.search(r"OWNERSHIPSTATE\s*=\s*'PENDING'.*?MIN_MEMORY_PERCENT\s*=\s*0.*?MAX_MEMORY_PERCENT\s*=\s*50.*?OWNERSHIPSTATE\s*=\s*'ACTIVE'", text)
    assert re.search(r"OWNERSHIPSTATE\s*=\s*'PENDING'.*?REQUEST_MAX_MEMORY_GRANT_PERCENT\s*=\s*40.*?MAX_DOP\s*=\s*4.*?GROUP_MAX_REQUESTS\s*=\s*4.*?OWNERSHIPSTATE\s*=\s*'ACTIVE'", text)
    assert "EXISTS WITHOUT WORKSHOP OWNERSHIP METADATA" in text
    assert "IF @CREATEDGROUP = 1" in text
    assert "DROP WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" in text
    assert "IF @CREATEDPOOL = 1" in text
    assert "DROP RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "PENDING POOL DOES NOT MATCH THE WORKSHOP CONTRACT" in text
    assert "PENDING WORKLOAD GROUP DOES NOT MATCH THE WORKSHOP CONTRACT" in text


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


def test_classifier_requires_exact_normalized_hash_and_dual_ownership_markers() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "HASHBYTES('SHA2_256'" in text
    assert re.search(r"OBJECT_DEFINITION\(@\w*WORKSHOPCLASSIFIERID\)", text)
    assert re.search(r"OBJECTPROPERTYEX\(@\w*WORKSHOPCLASSIFIERID, N'ISSCHEMABOUND'\)", text)
    assert "OBJECTTYPE = 'CLASSIFIER'" in text
    assert "DEFINITIONHASH" in text
    assert re.search(r"SYS\.EXTENDED_PROPERTIES.*?MCP_SQL_WORKSHOP", text)
    assert "UNEXPECTED FUNCTION DEFINITION OR OWNERSHIP" in text
    assert "NOT LIKE N'%APP_NAME" not in text


def test_post_applock_work_is_globally_guarded_and_restores_on_failure() -> None:
    text = normalized("01-ConfigureInstance.sql")
    lock = text.index("SP_GETAPPLOCK")
    guarded_try = text.index("BEGIN TRY", lock)
    guarded_catch = text.index("BEGIN CATCH", guarded_try)
    assert lock < guarded_try < guarded_catch
    assert text.count("SP_RELEASEAPPLOCK") >= 2
    catch = text[guarded_catch:]
    assert "@ORIGINALMAXSERVERMEMORYMB" in catch
    assert "@ORIGINALMINSERVERMEMORYMB" in catch
    assert "SP_CONFIGURE N'MAX SERVER MEMORY (MB)'" in catch
    assert "SP_CONFIGURE N'MIN SERVER MEMORY (MB)'" in catch
    assert "ROW_MODE_MEMORY_GRANT_FEEDBACK" in catch
    assert "BATCH_MODE_MEMORY_GRANT_FEEDBACK" in catch
    assert "CLASSIFIER_FUNCTION" in catch
    assert "ALTER RESOURCE GOVERNOR DISABLE" in catch
    assert "@RESTORATIONERRORS" in catch
    assert re.search(r"THROW\s+@ORIGINALERRORNUMBER\s*,\s*@ORIGINALERRORMESSAGE\s*,\s*@ORIGINALERRORSTATE", catch)


def test_catch_compensation_proves_exact_current_state_before_drop() -> None:
    text = normalized("01-ConfigureInstance.sql")
    catch = text[text.index("BEGIN CATCH", text.index("SP_GETAPPLOCK")):]
    group_cleanup = catch[catch.index("IF @CREATEDGROUP = 1"):catch.index("IF @CREATEDPOOL = 1")]
    pool_cleanup = catch[catch.index("IF @CREATEDPOOL = 1"):catch.index("IF @CREATEDCLASSIFIER = 1")]
    classifier_cleanup = catch[catch.index("IF @CREATEDCLASSIFIER = 1"):]
    assert "SYS.RESOURCE_GOVERNOR_WORKLOAD_GROUPS" in group_cleanup
    assert "REQUEST_MAX_MEMORY_GRANT_PERCENT = 40" in group_cleanup
    assert "MAX_DOP = 4" in group_cleanup and "GROUP_MAX_REQUESTS = 4" in group_cleanup
    assert "SYS.RESOURCE_GOVERNOR_RESOURCE_POOLS" in pool_cleanup
    assert "MIN_MEMORY_PERCENT = 0" in pool_cleanup and "MAX_MEMORY_PERCENT = 50" in pool_cleanup
    assert "OBJECT_DEFINITION" in classifier_cleanup
    assert "@EXPECTEDCLASSIFIERHASH" in classifier_cleanup


def test_resource_governor_ddl_is_outside_user_transactions_and_ordered() -> None:
    text = normalized("01-ConfigureInstance.sql")
    backup = text.index("INSERT INTO WORKSHOPADMIN.DBO.CONFIGURATIONBACKUP")
    pool_pending_commit = text.index("'POOL', N'MCP_SQL_WORKSHOP_POOL', 'PENDING'")
    pool = text.index("CREATE RESOURCE POOL")
    group_pending_commit = text.index("'GROUP', N'MCP_SQL_WORKSHOP_GROUP', 'PENDING'")
    group = text.index("CREATE WORKLOAD GROUP")
    classifier = text.index("ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION")
    reconfigure = text.index("ALTER RESOURCE GOVERNOR RECONFIGURE")
    assert backup < pool_pending_commit < pool < group_pending_commit < group < classifier < reconfigure
    assert re.search(r"'POOL', N'MCP_SQL_WORKSHOP_POOL', 'PENDING'.*?COMMIT TRANSACTION.*?CREATE RESOURCE POOL", text)
    assert re.search(r"'GROUP', N'MCP_SQL_WORKSHOP_GROUP', 'PENDING'.*?COMMIT TRANSACTION.*?CREATE WORKLOAD GROUP", text)


def test_classifier_creation_is_deterministic_dynamic_ddl_after_pending_claim() -> None:
    text = normalized("01-ConfigureInstance.sql")
    claim = text.index("'CLASSIFIER', N'MCP_SQL_WORKSHOP_CLASSIFIER', 'PENDING'")
    execute = text.index("EXEC SYS.SP_EXECUTESQL @CLASSIFIERCREATESQL")
    assert claim < execute
    assert "CREATE OR ALTER FUNCTION" not in text
    assert "EXEC SYS.SP_EXECUTESQL @CLASSIFIERCREATESQL" in text


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
