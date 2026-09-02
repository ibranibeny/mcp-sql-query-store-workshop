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


def test_administrative_scripts_use_session_context_not_sqlcmd_substitution() -> None:
    combined = "\n".join(sql(name) for name in ("00-Preflight.sql", "01-ConfigureInstance.sql"))
    assert not re.search(r"N?'\$\([^)]*\)'", combined, re.IGNORECASE)
    assert not re.search(r"\$\(\w+\)", combined)


def test_preflight_requires_session_context_inputs() -> None:
    text = sql("00-Preflight.sql")
    assert ":on error exit" in text.lower()
    for key in (
        "ExpectedServerName",
        "DatabaseName",
        "ExpectedPhysicalMemoryMB",
        "PreflightPhase",
        "PlannedRestorePath",
        "PlannedDataPath",
        "MinimumFreeSpaceMB",
    ):
        assert f"SESSION_CONTEXT(N'{key}')" in text
    for required in ("ExpectedServerName", "DatabaseName", "ExpectedPhysicalMemoryMB", "PreflightPhase"):
        assert re.search(rf"IF @{required.upper()} IS NULL.*?THROW", normalized("00-Preflight.sql"))


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


def test_preflight_requires_the_complete_database_and_server_marker_contract() -> None:
    text = normalized("00-Preflight.sql")
    for constant in (
        "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C",
        "MCP SQL QUERY STORE WORKSHOP",
        "ADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B",
    ):
        assert constant in text
    comparisons = {
        "MARKERID": "WORKSHOPMARKER",
        "SCHEMAVERSION": "WORKSHOPSCHEMAVERSION",
        "SETUPNAME": "WORKSHOPSETUPNAME",
        "SETUPHASH": "WORKSHOPSETUPHASH",
    }
    for field, expected in comparisons.items():
        assert re.search(rf"@DATABASE{field}\s*<>\s*@{expected}", text)
    assert "@SERVERMARKERID" in text
    assert re.search(r"@SERVERMARKERID\s*<>\s*@WORKSHOPMARKER", text)


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


def test_configuration_requires_session_context_and_uses_owned_utility_database() -> None:
    text = sql("01-ConfigureInstance.sql")
    assert ":on error exit" in text.lower()
    assert "SESSION_CONTEXT(N'ExpectedServerName')" in text
    assert "SESSION_CONTEXT(N'DatabaseName')" in text
    upper = normalized("01-ConfigureInstance.sql")
    assert re.search(r"@DATABASENAME.*?IS NULL.*?THROW", upper)
    assert re.search(r"@EXPECTEDSERVERNAME.*?IS NULL.*?THROW", upper)
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


def test_memory_grant_feedback_capture_maps_primary_and_secondary_values_to_int_flags() -> None:
    text = normalized("01-ConfigureInstance.sql")
    table = text[text.index("CREATE TABLE DBO.DATABASECONFIGURATIONBACKUP"):text.index("CONSTRAINT PK_DATABASECONFIGURATIONBACKUP")]
    for column in (
        "ROWMODEMEMORYGRANTFEEDBACK INT",
        "ROWMODEMEMORYGRANTFEEDBACKFORSECONDARY INT",
        "BATCHMODEMEMORYGRANTFEEDBACK INT",
        "BATCHMODEMEMORYGRANTFEEDBACKFORSECONDARY INT",
    ):
        assert column in table
    capture = text[text.index("DECLARE @CAPTUREDATABASESQL"):text.index("EXEC SYS.SP_EXECUTESQL", text.index("DECLARE @CAPTUREDATABASESQL"))]
    assert capture.count("VALUE_FOR_SECONDARY") >= 2
    assert capture.count("WHEN TRY_CONVERT(INT, D.VALUE) = 0 THEN 0") >= 2
    assert capture.count("WHEN TRY_CONVERT(INT, D.VALUE) = 1 THEN 1") >= 2
    assert capture.count("WHEN TRY_CONVERT(INT, D.VALUE_FOR_SECONDARY) = 0 THEN 0") >= 2
    assert capture.count("WHEN TRY_CONVERT(INT, D.VALUE_FOR_SECONDARY) = 1 THEN 1") >= 2


def test_existing_text_memory_grant_feedback_backups_are_migrated_to_int() -> None:
    text = normalized("01-ConfigureInstance.sql")
    for column in (
        "ROWMODEMEMORYGRANTFEEDBACK",
        "BATCHMODEMEMORYGRANTFEEDBACK",
        "MEMORYGRANTFEEDBACKPERCENTILEGRANT",
        "MEMORYGRANTFEEDBACKPERSISTENCE",
    ):
        assert f"ALTER TABLE DBO.DATABASECONFIGURATIONBACKUP ALTER COLUMN {column} INT NULL" in text
    assert "CANNOT MIGRATE NON-NUMERIC MEMORY GRANT FEEDBACK BACKUP VALUES" in text


def test_memory_grant_feedback_compensation_maps_zero_to_off_and_one_to_on() -> None:
    text = normalized("01-ConfigureInstance.sql")
    catch = text[text.index("BEGIN CATCH", text.index("SP_GETAPPLOCK")):]
    assert "@ORIGINALROWMODEMEMORYGRANTFEEDBACK INT" in text
    assert "@ORIGINALBATCHMODEMEMORYGRANTFEEDBACK INT" in text
    assert "CASE @ORIGINALROWMODEMEMORYGRANTFEEDBACK WHEN 0 THEN N'OFF' WHEN 1 THEN N'ON' END" in catch
    assert "CASE @ORIGINALBATCHMODEMEMORYGRANTFEEDBACK WHEN 0 THEN N'OFF' WHEN 1 THEN N'ON' END" in catch
    assert "@ORIGINALROWMODEMEMORYGRANTFEEDBACK IN (0, 1)" in catch
    assert "@ORIGINALBATCHMODEMEMORYGRANTFEEDBACK IN (0, 1)" in catch


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


def test_server_memory_lowers_min_before_setting_workshop_max() -> None:
    text = normalized("01-ConfigureInstance.sql")
    configure = text[text.index("SP_CONFIGURE N'SHOW ADVANCED OPTIONS', 1"):text.index("IF EXISTS ( SELECT 1 FROM SYS.CONFIGURATIONS")]
    lower_min = configure.index("SP_CONFIGURE N'MIN SERVER MEMORY (MB)', 0")
    max_memory = configure.index("SP_CONFIGURE N'MAX SERVER MEMORY (MB)', 49152")
    assert lower_min < max_memory
    assert "SP_CONFIGURE N'MIN SERVER MEMORY (MB)', 0; RECONFIGURE;" in configure
    assert "SP_CONFIGURE N'MAX SERVER MEMORY (MB)', 49152; RECONFIGURE;" in configure


def test_server_memory_compensation_uses_relationship_safe_restore_order() -> None:
    text = normalized("01-ConfigureInstance.sql")
    catch = text[text.index("BEGIN CATCH", text.index("SP_GETAPPLOCK")):]
    restore = catch[catch.index("SERVER MEMORY (ERROR") - 2000:catch.index("SERVER MEMORY (ERROR")]
    assert "IF @COMPENSATIONCURRENTMINSERVERMEMORYMB > @ORIGINALMAXSERVERMEMORYMB" in restore
    assert restore.index("SP_CONFIGURE N'MIN SERVER MEMORY (MB)', 0") < restore.index("SP_CONFIGURE N'MAX SERVER MEMORY (MB)', @ORIGINALMAXSERVERMEMORYMB")
    assert restore.index("SP_CONFIGURE N'MAX SERVER MEMORY (MB)', @ORIGINALMAXSERVERMEMORYMB") < restore.index("SP_CONFIGURE N'MIN SERVER MEMORY (MB)', @ORIGINALMINSERVERMEMORYMB")


def test_resource_governor_objects_have_exact_limits_and_idempotency_guards() -> None:
    text = normalized("01-ConfigureInstance.sql")
    assert "RESOURCEGOVERNOROBJECTOWNERSHIP" in text
    assert re.search(r"RESOURCE_GOVERNOR_RESOURCE_POOLS.*?NOT EXISTS.*?RESOURCEGOVERNOROBJECTOWNERSHIP.*?THROW", text)
    assert re.search(r"RESOURCE_GOVERNOR_WORKLOAD_GROUPS.*?NOT EXISTS.*?RESOURCEGOVERNOROBJECTOWNERSHIP.*?THROW", text)
    assert "CREATE RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "ALTER RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" not in text
    assert "MIN_MEMORY_PERCENT = 0" in text and "MAX_MEMORY_PERCENT = 50" in text
    assert "CREATE WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" in text
    assert "ALTER WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" not in text
    assert "REQUEST_MAX_MEMORY_GRANT_PERCENT = 40" in text
    assert "MAX_DOP = 4" in text and "GROUP_MAX_REQUESTS = 4" in text
    assert "SYS.RESOURCE_GOVERNOR_RESOURCE_POOLS" in text
    assert "SYS.RESOURCE_GOVERNOR_WORKLOAD_GROUPS" in text


def test_resource_governor_collisions_are_rejected_before_mutating_configuration() -> None:
    text = normalized("01-ConfigureInstance.sql")
    pool_collision = text.index("A RESOURCE GOVERNOR POOL WITH THE WORKSHOP NAME EXISTS")
    group_collision = text.index("A RESOURCE GOVERNOR WORKLOAD GROUP WITH THE WORKSHOP NAME EXISTS")
    pool_drift = text.index("EXISTING WORKSHOP POOL DOES NOT MATCH THE OWNED ACTIVE CONTRACT")
    group_drift = text.index("EXISTING WORKSHOP WORKLOAD GROUP DOES NOT MATCH THE OWNED ACTIVE CONTRACT")
    server_memory_change = text.index("SP_CONFIGURE N'MAX SERVER MEMORY (MB)', 49152")
    feedback_change = text.index("ALTER DATABASE SCOPED CONFIGURATION SET ROW_MODE_MEMORY_GRANT_FEEDBACK = OFF")
    for guard in (pool_collision, group_collision, pool_drift, group_drift):
        assert guard < server_memory_change
        assert guard < feedback_change


def test_existing_resource_governor_objects_require_exact_owned_state_before_mutation() -> None:
    text = normalized("01-ConfigureInstance.sql")
    preflight = text[:text.index("SP_CONFIGURE N'SHOW ADVANCED OPTIONS', 1")]
    assert re.search(
        r"RESOURCE_GOVERNOR_RESOURCE_POOLS.*?OWNERSHIPSTATE\s*=\s*'ACTIVE'.*?"
        r"MIN_MEMORY_PERCENT\s*=\s*0.*?MAX_MEMORY_PERCENT\s*=\s*50.*?THROW",
        preflight,
    )
    assert re.search(
        r"RESOURCE_GOVERNOR_WORKLOAD_GROUPS.*?OWNERSHIPSTATE\s*=\s*'ACTIVE'.*?"
        r"REQUEST_MAX_MEMORY_GRANT_PERCENT\s*=\s*40.*?MAX_DOP\s*=\s*4.*?"
        r"GROUP_MAX_REQUESTS\s*=\s*4.*?RESOURCE_POOL\.NAME\s*=\s*N'MCP_SQL_WORKSHOP_POOL'.*?THROW",
        preflight,
    )
    assert "ALTER RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" not in text
    assert "ALTER WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" not in text


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
    assert "EXISTING WORKSHOP POOL DOES NOT MATCH THE OWNED ACTIVE CONTRACT" in text
    assert "EXISTING WORKSHOP WORKLOAD GROUP DOES NOT MATCH THE OWNED ACTIVE CONTRACT" in text


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


def test_existing_classifier_recovers_only_exact_pending_ownership() -> None:
    text = normalized("01-ConfigureInstance.sql")
    start = text.index("IF @LOCKEDWORKSHOPCLASSIFIERID IS NOT NULL")
    existing = text[
        start:
        text.index("IF EXISTS ( SELECT 1 FROM SYS.RESOURCE_GOVERNOR_RESOURCE_POOLS", start)
    ]
    for required_guard in (
        "@LOCKEDDEFINITION IS NULL",
        "@LOCKEDHASH IS NULL",
        "@LOCKEDSTOREDHASH IS NULL",
        "@LOCKEDOWNERSHIPSTATE IS NULL",
    ):
        assert required_guard in existing
    assert "@LOCKEDOWNERSHIPSTATE = 'PENDING'" in existing
    assert re.search(r"@LOCKEDOWNERSHIPSTATE = 'PENDING'.*?@LOCKEDHASH = @EXPECTEDCLASSIFIERHASH.*?@LOCKEDSTOREDHASH = @EXPECTEDCLASSIFIERHASH", existing)
    assert "SP_ADDEXTENDEDPROPERTY" in existing
    assert re.search(r"SET OWNERSHIPSTATE = 'ACTIVE'.*?COMMIT TRANSACTION", existing)
    assert re.search(r"@LOCKEDOWNERSHIPSTATE <> 'ACTIVE'.*?THROW", existing)
    assert re.search(r"@LOCKEDMARKERVALID <> 1.*?THROW", existing)


def test_new_classifier_creation_and_ownership_activation_are_one_transaction() -> None:
    text = normalized("01-ConfigureInstance.sql")
    start = text.index("IF OBJECT_ID(N'DBO.MCP_SQL_WORKSHOP_CLASSIFIER', N'FN') IS NULL")
    end = text.index("DECLARE @CURRENTCLASSIFIERID", start)
    creation = text[start:end]
    assert re.search(
        r"BEGIN TRANSACTION.*?'CLASSIFIER', N'MCP_SQL_WORKSHOP_CLASSIFIER', 'PENDING'.*?"
        r"EXEC SYS.SP_EXECUTESQL @CLASSIFIERCREATESQL.*?SP_ADDEXTENDEDPROPERTY.*?"
        r"SET OWNERSHIPSTATE = 'ACTIVE'.*?COMMIT TRANSACTION",
        creation,
    )


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
    assert "THROW @ORIGINALERRORNUMBER" not in catch
    assert re.search(r"PRINT\s+N'RESTORATION WARNINGS.*?THROW\s*;\s*END CATCH", catch)


def test_outer_catch_prints_sanitized_restoration_diagnostics_and_bare_rethrows() -> None:
    text = normalized("01-ConfigureInstance.sql")
    catch = text[text.index("BEGIN CATCH", text.index("SP_GETAPPLOCK")):]
    assert "ERROR_NUMBER()" in catch
    assert "ERROR_MESSAGE()" not in catch
    assert "REPLACE(@RESTORATIONERRORS, NCHAR(13), N' ')" in catch
    assert "REPLACE(" in catch and "NCHAR(10), N' ')" in catch
    assert re.search(r"PRINT\s+N'RESTORATION WARNINGS.*?THROW\s*;\s*END CATCH", catch)


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


def test_restore_uses_session_context_and_strict_input_guards() -> None:
    text = sql("02-RestoreAndConfigureDatabase.sql")
    upper = normalized("02-RestoreAndConfigureDatabase.sql")
    assert ":on error exit" in text.lower()
    assert not re.search(r"\$\(\w+\)", text)
    for key in ("BackupPath", "DataPath", "LogPath", "DatabaseName"):
        assert f"SESSION_CONTEXT(N'{key}')" in text
        assert re.search(rf"@{key.upper()}\s+IS\s+NULL.*?THROW", upper)
    assert "N'ADVENTUREWORKS2022'" in upper
    assert re.search(r"@DATABASENAME\s*<>\s*N'ADVENTUREWORKS2022'.*?THROW", upper)
    assert "QUOTENAME(@DATABASENAME)" in upper
    assert "SP_EXECUTESQL" in upper
    assert not re.search(r"N?'\$\([^)]*\)'", text, re.IGNORECASE)


def test_restore_validates_safe_local_windows_paths_and_extensions() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    for variable, extension in (("BACKUPPATH", ".BAK"), ("DATAPATH", ".MDF"), ("LOGPATH", ".LDF")):
        assert f"@{variable}" in text
        assert extension in text
    assert "SUBSTRING(@BACKUPPATH, 2, 2) <> N':\\'" in text
    assert "SUBSTRING(@DATAPATH, 2, 2) <> N':\\'" in text
    assert "SUBSTRING(@LOGPATH, 2, 2) <> N':\\'" in text
    for variable in ("BACKUPPATH", "DATAPATH", "LOGPATH"):
        assert f"LEN(@{variable}) > 260" in text
        assert f"LEFT(@{variable}, 1) COLLATE LATIN1_GENERAL_100_BIN2 NOT LIKE N'[A-ZA-Z]'" in text
    for unsafe in ("N'%..%'", "N'%[%]%'", "N'%[_]%'", "N'%[[]%'", "N'%]%'", "N'%*%'", "N'%?%'", "N'%;%'", "NCHAR(0)"):
        assert unsafe in text
    assert not re.search(r"QUOTENAME\s*\(\s*@(BACKUPPATH|DATAPATH|LOGPATH)\b", text)
    assert "LIKE N'%''%'" not in text
    for variable in ("BACKUPPATH", "DATAPATH", "LOGPATH"):
        assert re.search(
            rf"N'N'''\s*\+\s*REPLACE\s*\(\s*@{variable}\s*,\s*N''''\s*,\s*N''''''\s*\)\s*\+\s*N''''",
            text,
        )


def test_restore_verifies_backup_and_filelist_before_restore() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    verify = text.index("RESTORE VERIFYONLY")
    filelist = text.index("RESTORE FILELISTONLY")
    restore = text.index("RESTORE DATABASE")
    assert verify < filelist < restore
    assert "INSERT @FILELIST" in text
    assert re.search(r"COUNT\(\*\).*?TYPE\]\s*=\s*'D'.*?<>\s*1.*?THROW", text)
    assert re.search(r"COUNT\(\*\).*?TYPE\]\s*=\s*'L'.*?<>\s*1.*?THROW", text)
    assert "WITH MOVE" in text
    assert text.count("MOVE") >= 2
    assert "RECOVERY" in text and "STATS = 5" in text


def test_restore_never_overwrites_and_existing_database_requires_exact_marker() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    assert "DROP DATABASE" not in text
    assert "WITH REPLACE" not in text
    assert re.search(r"IF DB_ID\(@DATABASENAME\) IS NULL.*?RESTORE DATABASE", text)
    existing = text[text.index("IF DB_ID(@DATABASENAME) IS NOT NULL"):text.index("IF DB_ID(@DATABASENAME) IS NULL")]
    assert "LAB.WORKSHOPMARKER" in existing
    assert "MARKERID" in existing and "SCHEMAVERSION" in existing
    assert "THROW" in existing
    fresh = text[text.index("IF DB_ID(@DATABASENAME) IS NULL"):]
    assert "CREATE SCHEMA LAB AUTHORIZATION DBO" in fresh
    assert "CREATE TABLE LAB.WORKSHOPMARKER" in fresh
    assert "@MARKERID" in fresh and "@WORKSHOPMARKER" in text


def test_restore_creates_schema_as_first_statement_in_nested_target_database_batch() -> None:
    raw = sql("02-RestoreAndConfigureDatabase.sql")
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    schema_batch = re.search(
        r"DECLARE\s+@CreateSchemaSql\s+nvarchar\(max\)\s*=\s*N'(?P<body>.*?)';",
        raw,
        re.IGNORECASE | re.DOTALL,
    )
    assert schema_batch, "schema creation must have a dedicated dynamic batch"
    assert re.match(r"\s*CREATE\s+SCHEMA\s+lab\s+AUTHORIZATION\s+dbo\s*;", schema_batch.group("body"), re.IGNORECASE)
    assert re.search(
        r"N'USE '\s*\+\s*QUOTENAME\(@DATABASENAME\).*?"
        r"EXEC\s+SYS\.SP_EXECUTESQL\s+@CREATESCHEMASQL",
        text,
    )
    marker_batch = re.search(
        r"DECLARE\s+@CreateMarkerSql\s+nvarchar\(max\)\s*=\s*N'(?P<body>.*?)';",
        raw,
        re.IGNORECASE | re.DOTALL,
    )
    assert marker_batch
    assert not re.search(r"CREATE\s+SCHEMA", marker_batch.group("body"), re.IGNORECASE)


def test_restore_marker_contract_is_complete_and_exact() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    assert "N'MCP SQL QUERY STORE WORKSHOP'" in text
    assert "HASHBYTES('SHA2_256'" in text
    assert "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B" in text
    assert "SETUPHASH VARBINARY(32) NOT NULL" in text
    assert "SETUPDEFINITIONHASH" not in text
    for section in (
        text[text.index("IF DB_ID(@DATABASENAME) IS NOT NULL"):text.index("IF DB_ID(@DATABASENAME) IS NULL")],
        text[text.index("DECLARE @VERIFYSTATESQL"):],
    ):
        for exact_match in (
            "MARKERID = @MARKERID",
            "SCHEMAVERSION = @SCHEMAVERSION",
            "SETUPNAME = @SETUPNAME",
            "SETUPHASH = @SETUPHASH",
        ):
            assert exact_match in section


def test_restore_configures_and_verifies_exact_query_store_state() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    assert "COMPATIBILITY_LEVEL = 160" in text
    for setting in (
        "MAX_STORAGE_SIZE_MB = 2048",
        "STALE_QUERY_THRESHOLD_DAYS = 7",
        "DATA_FLUSH_INTERVAL_SECONDS = 60",
        "INTERVAL_LENGTH_MINUTES = 5",
        "QUERY_CAPTURE_MODE = AUTO",
        "SIZE_BASED_CLEANUP_MODE = AUTO",
        "WAIT_STATS_CAPTURE_MODE = ON",
    ):
        assert setting in text
    assert "SYS.DATABASE_QUERY_STORE_OPTIONS" in text
    assert re.search(r"ACTUAL_STATE_DESC\s*=\s*N''?READ_WRITE''?", text)
    assert re.search(r"DESIRED_STATE_DESC\s*=\s*N''?READ_WRITE''?", text)
    assert "MCP SQL QUERY STORE WORKSHOP" in text and "HASHBYTES('SHA2_256'" in text
    assert "SYSUTCDATETIME()" in text


def test_generator_has_bounded_defaults_and_validated_session_overrides() -> None:
    text = sql("03-CreateScaledLabData.sql")
    upper = normalized("03-CreateScaledLabData.sql")
    assert ":on error exit" in text.lower()
    assert not re.search(r"\$\(\w+\)", text)
    defaults = {
        "TargetRows": "8000000",
        "BatchSize": "100000",
        "MinimumFreeSpaceMB": "65536",
        "MaximumDataFileSizeMB": "65536",
    }
    for key, default in defaults.items():
        assert f"SESSION_CONTEXT(N'{key}')" in text
        assert re.search(rf"DECLARE @{key.upper()} .*?= COALESCE\(.*?, {default}\)", upper)
    assert re.search(r"@TARGETROWS NOT BETWEEN 100000 AND 8000000.*?THROW", upper)
    assert re.search(r"@BATCHSIZE NOT BETWEEN 10000 AND 100000.*?THROW", upper)
    assert re.search(r"@MINIMUMFREESPACEMB < 16384.*?THROW", upper)
    assert re.search(r"@MAXIMUMDATAFILESIZEMB.*?> 65536.*?THROW", upper)
    assert "TRY_CONVERT(INT" in upper


def test_generator_requires_marker_database_and_query_store_before_changes() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    first_create = text.index("CREATE SCHEMA LAB")
    guards = text[:first_create]
    assert "DB_NAME() <> N'ADVENTUREWORKS2022'" in guards
    assert "LAB.WORKSHOPMARKER" in guards
    assert "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C" in guards
    assert "@WORKSHOPSCHEMAVERSION INT = 1" in guards
    assert "SCHEMAVERSION = @WORKSHOPSCHEMAVERSION" in guards
    assert "SYS.DATABASE_QUERY_STORE_OPTIONS" in guards
    assert "ACTUAL_STATE_DESC <> N'READ_WRITE'" in guards
    assert guards.count("THROW") >= 3


def test_generator_validates_complete_marker_contract_initially_and_in_every_batch() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    assert "N'MCP SQL QUERY STORE WORKSHOP'" in text
    assert "HASHBYTES('SHA2_256'" in text
    assert "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B" in text
    initial = text[:text.index("IF EXISTS (SELECT 1 FROM SYS.DATABASE_QUERY_STORE_OPTIONS")]
    loop = text[text.index("WHILE @NEXTID <= @TARGETROWS"):]
    first_capacity_read = loop.index("SYS.DM_OS_VOLUME_STATS")
    first_insert = loop.index("INSERT LAB.FACTSALES")
    for section in (initial, loop):
        for exact_match in (
            "MARKERID = @WORKSHOPMARKER",
            "SCHEMAVERSION = @WORKSHOPSCHEMAVERSION",
            "SETUPNAME = @WORKSHOPSETUPNAME",
            "SETUPHASH = @WORKSHOPSETUPHASH",
        ):
            assert exact_match in section
    marker_match = re.search(r"IF NOT EXISTS\s*\(\s*SELECT 1 FROM LAB\.WORKSHOPMARKER", loop)
    assert marker_match
    assert len(re.findall(r"IF NOT EXISTS\s*\(\s*SELECT 1 FROM LAB\.WORKSHOPMARKER", loop)) == 1
    for field in ("MARKERID", "SCHEMAVERSION", "SETUPNAME", "SETUPHASH"):
        assert len(re.findall(rf"\b{field}\s*=", loop[marker_match.start():first_capacity_read])) == 1
    marker_recheck = marker_match.start()
    assert marker_recheck < first_capacity_read < first_insert
    assert re.search(r"IF NOT EXISTS\s*\(\s*SELECT 1 FROM LAB\.WORKSHOPMARKER.*?THROW", loop)


def test_numbers_generation_uses_bounded_top_cross_joins() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    assert "CREATE TABLE LAB.NUMBERS" in text
    assert "PRIMARY KEY" in text
    assert "TOP (@NEEDED)" in text
    assert "CROSS JOIN" in text
    assert "@NEEDED <= 8000000" in text
    assert "MAXRECURSION" not in text
    assert not re.search(r"INSERT\s+.*?LAB\.NUMBERS.*?SELECT(?!\s+TOP).*?CROSS JOIN", text)


def test_numbers_growth_is_guarded_before_setup_population_and_indexes() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    numbers_create = text.index("CREATE TABLE LAB.NUMBERS")
    numbers_insert = text.index("INSERT LAB.NUMBERS")
    batch_loop = text.index("WHILE @NEXTID <= @TARGETROWS")
    setup = text[:batch_loop]

    capacity_read = setup.index("SYS.DM_OS_VOLUME_STATS", setup.index("@ESTIMATEDNUMBERSMB"))
    guard_start = setup.rfind("SELECT TOP (1)", 0, capacity_read)
    assert capacity_read < numbers_create < numbers_insert
    assert "@NUMBERSWORSTCASEBYTESPERROW INT = 64" in setup[:capacity_read]
    assert re.search(
        r"@ESTIMATEDNUMBERSMB\s+DECIMAL\(19,4\)\s*=\s*CEILING\s*\(\s*"
        r"CONVERT\(DECIMAL\(19,4\),\s*@TARGETROWS\)\s*\*\s*"
        r"@NUMBERSWORSTCASEBYTESPERROW\s*/\s*1048576\.0\s*\)",
        setup[:capacity_read],
    )
    guarded_region = setup[guard_start:numbers_insert]
    assert "FILEPROPERTY(F.NAME, 'SPACEUSED')" in guarded_region
    assert "F.GROWTH * 8.0 / 1024" in guarded_region
    assert "F.IS_PERCENT_GROWTH" in guarded_region
    assert "F.AVAILABLE_BYTES" not in guarded_region
    assert "V.AVAILABLE_BYTES" in guarded_region
    assert re.search(r"@SETUPISPERCENTGROWTH\s*=\s*1.*?THROW", guarded_region)
    assert re.search(r"@SETUPUNALLOCATEDMB\s*=\s*@SETUPALLOCATEDMB\s*-\s*@SETUPUSEDMB", guarded_region)
    assert re.search(
        r"@SETUPREQUIREDPHYSICALGROWTHMB\s*=\s*CASE\s+WHEN\s+"
        r"@ESTIMATEDNUMBERSMB\s*>\s*@SETUPUNALLOCATEDMB",
        guarded_region,
    )
    assert re.search(
        r"CEILING\s*\(\s*@SETUPREQUIREDPHYSICALGROWTHMB\s*/\s*"
        r"@SETUPGROWTHINCREMENTMB\s*\)",
        guarded_region,
    )
    assert re.search(
        r"@SETUPAVAILABLESPACEMB\s*-\s*@SETUPROUNDEDGROWTHMB\s*<\s*"
        r"@MINIMUMFREESPACEMB.*?THROW",
        guarded_region,
    )
    assert re.search(
        r"@SETUPALLOCATEDMB\s*\+\s*@SETUPROUNDEDGROWTHMB\s*>\s*"
        r"@MAXIMUMDATAFILESIZEMB.*?THROW",
        guarded_region,
    )
    assert "METADATA IS UNAVAILABLE" in guarded_region

    for index_match in re.finditer(r"CREATE\s+(?:UNIQUE\s+)?(?:CLUSTERED\s+|NONCLUSTERED\s+)?INDEX\b", setup):
        assert capacity_read < index_match.start()


def test_fact_sales_schema_and_generation_are_deterministic() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    for contract in (
        "SYNTHETICSALESID BIGINT NOT NULL",
        "ORDERDATE DATETIME2",
        "TERRITORYID INT NULL",
        "CUSTOMERID INT NOT NULL",
        "PRODUCTID INT NOT NULL",
        "ORDERQTY SMALLINT NOT NULL",
        "UNITPRICE DECIMAL(19,4) NOT NULL",
        "SALESAMOUNT DECIMAL(19,4) NOT NULL",
        "WIDEPAYLOAD CHAR(400) NOT NULL",
        "SOURCECUSTOMERID INT NOT NULL",
        "SOURCEPRODUCTID INT NOT NULL",
        "SOURCECHECKSUM INT NOT NULL",
    ):
        assert contract in text
    assert "PRIMARY KEY CLUSTERED" in text
    assert "ROW_NUMBER()" in text and "% @CUSTOMERCOUNT" in text and "% @PRODUCTCOUNT" in text
    assert "CHECKSUM(" in text
    assert "RAND(" not in text and "NEWID(" not in text


def test_generator_batches_resume_and_log_idempotently() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    assert "MAX(SYNTHETICSALESID)" in text
    assert "WHILE @NEXTID <= @TARGETROWS" in text
    assert "TOP (@THISBATCHSIZE)" in text
    assert "BEGIN TRANSACTION" in text and "COMMIT TRANSACTION" in text
    assert "CREATE TABLE LAB.DATAGENERATIONLOG" in text
    assert "ROWSINSERTED" in text and "COMPLETEDATUTC" in text
    assert "NOT EXISTS" in text
    assert re.search(r"COUNT_BIG\(\*\).*?>\s*@TARGETROWS.*?THROW", text)
    assert "ACTUALROWCOUNT" in text and "GENERATEDTHROUGHSYNTHETICSALESID" in text


def test_generator_checks_estimated_and_per_batch_capacity() -> None:
    text = normalized("03-CreateScaledLabData.sql")
    loop = text[text.index("WHILE @NEXTID <= @TARGETROWS"):]
    assert "SYS.DM_OS_VOLUME_STATS" in text
    assert "AVAILABLE_BYTES" in text
    assert "SIZE * 8.0 / 1024" in text
    assert "@MINIMUMFREESPACEMB" in text and "@MAXIMUMDATAFILESIZEMB" in text
    assert "FILEPROPERTY(F.NAME, 'SPACEUSED')" in loop
    assert "F.IS_PERCENT_GROWTH" in loop and re.search(r"@BATCHISPERCENTGROWTH\s*=\s*1.*?THROW", loop)
    assert "F.GROWTH * 8.0 / 1024" in loop
    assert re.search(r"@BATCHUNALLOCATEDMB\s*=\s*@BATCHALLOCATEDMB\s*-\s*@BATCHUSEDMB", loop)
    assert re.search(r"@REQUIREDPHYSICALGROWTHMB\s*=\s*CASE\s+WHEN\s+@ESTIMATEDBATCHMB\s*>\s*@BATCHUNALLOCATEDMB", loop)
    assert re.search(r"CEILING\s*\(\s*@REQUIREDPHYSICALGROWTHMB\s*/\s*@BATCHGROWTHINCREMENTMB\s*\)", loop)
    assert re.search(r"@BATCHAVAILABLESPACEMB\s*-\s*@ROUNDEDGROWTHMB\s*<\s*@MINIMUMFREESPACEMB.*?THROW", loop)
    assert re.search(r"@BATCHALLOCATEDMB\s*\+\s*@ROUNDEDGROWTHMB\s*>\s*@MAXIMUMDATAFILESIZEMB.*?THROW", loop)
    assert "SYS.DM_OS_VOLUME_STATS" in loop
    transaction = loop.index("BEGIN TRANSACTION")
    capacity_read = loop.index("SYS.DM_OS_VOLUME_STATS", transaction)
    insert = loop.index("INSERT LAB.FACTSALES")
    assert transaction < capacity_read < insert
    assert "METADATA" in loop[capacity_read:insert] and "THROW" in loop[capacity_read:insert]
    assert "FILEGROWTH" in text and "MAXSIZE" in text


def test_generator_defers_optimized_index_and_avoids_destructive_commands() -> None:
    raw = sql("03-CreateScaledLabData.sql")
    text = normalized("03-CreateScaledLabData.sql")
    assert re.search(r"optimized index (?:is )?deferred to task 9", raw, re.IGNORECASE)
    assert not re.search(r"CREATE\s+(?:UNIQUE\s+)?(?:NONCLUSTERED\s+)?INDEX\s+.*?(ORDERDATE|TERRITORYID)", text)
    assert "DBCC DROPCLEANBUFFERS" not in text
    assert "DBCC FREEPROCCACHE" not in text
    assert "WHILE 1 = 1" not in text


def test_candidate_and_equivalence_scripts_require_the_explicit_approval_context() -> None:
    for name in ("06-CreateOptimizedProcedure.sql", "07-ValidateEquivalence.sql"):
        text = normalized(name)
        assert "SESSION_CONTEXT(N'CANDIDATEAPPROVALID')" in text
        assert "SESSION_CONTEXT(N'CANDIDATEAPPROVALGRANTED')" in text
        assert re.search(r"CANDIDATEAPPROVALID.*?IS NULL.*?THROW", text)
        assert re.search(r"CANDIDATEAPPROVALGRANTED.*?<>\s*1.*?THROW", text)


def procedure_signature(name: str, procedure: str) -> list[tuple[str, str, str | None]]:
    text = sql(name)
    match = re.search(
        rf"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+{re.escape(procedure)}\s+(?P<header>.*?)\s+AS\s+BEGIN",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    assert match, f"missing procedure header for {procedure}"
    signature: list[tuple[str, str, str | None]] = []
    for declaration in match.group("header").split(","):
        parsed = re.fullmatch(
            r"\s*(@\w+)\s+(date|int)(?:\s*=\s*(NULL|\d+))?\s*",
            declaration,
            re.IGNORECASE,
        )
        assert parsed, f"unsupported or malformed parameter declaration: {declaration!r}"
        parameter, data_type, default = parsed.groups()
        signature.append((parameter.lower(), data_type.lower(), default.upper() if default else None))
    return signature


def procedure_body(name: str, procedure: str) -> str:
    text = sql(name)
    match = re.search(
        rf"CREATE\s+OR\s+ALTER\s+PROCEDURE\s+{re.escape(procedure)}\b(?P<body>.*)",
        text,
        re.IGNORECASE | re.DOTALL,
    )
    assert match
    body = re.sub(r"/\*.*?\*/", " ", match.group("body"), flags=re.DOTALL)
    body = re.sub(r"--[^\r\n]*", " ", body)
    return re.sub(r"\s+", " ", body).upper()


def test_month_end_procedures_have_the_exact_same_signature() -> None:
    expected = [
        ("@startdate", "date", None),
        ("@enddateexclusive", "date", None),
        ("@territoryid", "int", "NULL"),
        ("@topcount", "int", "100"),
    ]
    baseline = procedure_signature("04-CreateBaselineProcedure.sql", "lab.usp_MonthEndSalesBaseline")
    optimized = procedure_signature("06-CreateOptimizedProcedure.sql", "lab.usp_MonthEndSalesOptimized")
    assert baseline == optimized == expected


@pytest.mark.parametrize("name", ["04-CreateBaselineProcedure.sql", "06-CreateOptimizedProcedure.sql"])
def test_month_end_procedures_use_exact_marker_session_and_validation_contract(name: str) -> None:
    text = normalized(name)
    for contract in (
        "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C",
        "N'MCP SQL QUERY STORE WORKSHOP'",
        "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B",
        "SESSION_CONTEXT(N'WORKSHOPRUNID')",
        "SESSION_CONTEXT(N'WORKSHOPMANUALEXECUTION')",
        "APP_NAME() LIKE N'MCP-SQL-WORKSHOP%'",
        "@STARTDATE IS NULL",
        "@ENDDATEEXCLUSIVE IS NULL",
        "@ENDDATEEXCLUSIVE <= @STARTDATE",
        "DATEDIFF(DAY, @STARTDATE, @ENDDATEEXCLUSIVE) > 366",
        "@TOPCOUNT NOT BETWEEN 1 AND 1000",
        "SALES.SALESTERRITORY",
        "LAB.FACTSALES",
    ):
        assert contract in text
    procedure = "lab.usp_MonthEndSalesBaseline" if name.startswith("04") else "lab.usp_MonthEndSalesOptimized"
    errors = re.findall(r"THROW\s+(514\d{2}),\s*'([^']+)'", procedure_body(name, procedure))
    assert errors[:8] == [
        ("51400", "THE WORKSHOP MARKER CONTRACT IS INVALID."),
        ("51401", "WORKSHOPRUNID SESSION CONTEXT IS REQUIRED."),
        ("51402", "THE SESSION MUST USE A WORKSHOP APPLICATION NAME OR EXPLICIT MANUAL EXECUTION CONTEXT."),
        ("51403", "STARTDATE IS REQUIRED."),
        ("51404", "ENDDATEEXCLUSIVE IS REQUIRED."),
        ("51405", "ENDDATEEXCLUSIVE MUST BE GREATER THAN STARTDATE."),
        ("51406", "THE DATE RANGE MUST NOT EXCEED 366 DAYS."),
        ("51407", "TOPCOUNT MUST BE BETWEEN 1 AND 1000."),
    ]
    assert ("51408", "TERRITORYID DOES NOT EXIST IN THE SOURCE OR SYNTHETIC DOMAIN.") in errors


def test_baseline_contains_bounded_natural_antipatterns() -> None:
    body = procedure_body("04-CreateBaselineProcedure.sql", "lab.usp_MonthEndSalesBaseline")
    assert "CONVERT(DATE, FS.ORDERDATE) >= @STARTDATE" in body
    assert "CONVERT(DATE, FS.ORDERDATE) < @ENDDATEEXCLUSIVE" in body
    assert body.count("LAB.FACTSALES AS FS") == 2
    assert "WIDEPAYLOAD" in body
    assert "GROUP BY" in body and "ORDER BY" in body
    assert "OPTION (HASH JOIN" not in body and "OPTION (HASH GROUP" not in body
    assert "CROSS JOIN" not in body


def test_baseline_defers_optional_territory_filter_until_after_wide_materialization() -> None:
    body = procedure_body("04-CreateBaselineProcedure.sql", "lab.usp_MonthEndSalesBaseline")
    materialization = body[body.index("INSERT @WIDEWORK"):body.index("DECLARE @ORDERSTATS")]
    assert "CONVERT(DATE, FS.ORDERDATE) >= @STARTDATE" in materialization
    assert "CONVERT(DATE, FS.ORDERDATE) < @ENDDATEEXCLUSIVE" in materialization
    assert "@TERRITORYID IS NULL OR FS.TERRITORYID = @TERRITORYID" not in materialization

    aggregation = body[body.index("INSERT @ORDERSTATS"):body.index("DECLARE @PRICESTATS")]
    assert "FROM @WIDEWORK AS W" in aggregation
    assert "WHERE (@TERRITORYID IS NULL OR W.TERRITORYID = @TERRITORYID)" in aggregation
    assert body.index("INSERT @WIDEWORK") < body.index("WHERE (@TERRITORYID IS NULL OR W.TERRITORYID = @TERRITORYID)")


def test_baseline_carries_wide_payload_through_the_ranking_sort() -> None:
    body = procedure_body("04-CreateBaselineProcedure.sql", "lab.usp_MonthEndSalesBaseline")
    ranked = body[body.index(";WITH RANKED AS"):body.index("INSERT @RESULTS")]
    ranking_order = re.search(r"ROW_NUMBER\(\)\s+OVER\s*\(\s*ORDER BY(?P<order>.*?)\)\s+AS SALESRANK", ranked)
    assert ranking_order
    assert "ORDERS.CARRIEDPAYLOAD" in ranked
    assert "ORDERS.CARRIEDPAYLOAD" in ranking_order.group("order")
    assert ranking_order.group("order").index("ORDERS.PRODUCTID") < ranking_order.group("order").index("ORDERS.CARRIEDPAYLOAD")


def test_optimized_has_one_narrow_sargable_fact_access_and_exact_index() -> None:
    text = normalized("06-CreateOptimizedProcedure.sql")
    body = procedure_body("06-CreateOptimizedProcedure.sql", "lab.usp_MonthEndSalesOptimized")
    assert "CREATE INDEX IX_FACTSALES_ORDERDATE_TERRITORY" in text
    assert "(ORDERDATE, TERRITORYID)" in text
    assert "INCLUDE (CUSTOMERID, PRODUCTID, ORDERQTY, UNITPRICE, SALESAMOUNT)" in text
    assert "SYS.INDEX_COLUMNS" in text and "EXISTING IX_FACTSALES_ORDERDATE_TERRITORY DEFINITION DOES NOT MATCH" in text
    assert "IS_DESCENDING_KEY" in text and "IS_HYPOTHETICAL" in text
    assert body.count("LAB.FACTSALES AS FS") == 1
    assert "FS.ORDERDATE >= @STARTDATE" in body
    assert "FS.ORDERDATE < @ENDDATEEXCLUSIVE" in body
    assert "WIDEPAYLOAD" not in body
    assert body.count("GROUP BY") == 1
    assert "OPTION (" not in body


@pytest.mark.parametrize("name", ["04-CreateBaselineProcedure.sql", "06-CreateOptimizedProcedure.sql"])
def test_average_unit_price_is_the_same_quantity_weighted_formula(name: str) -> None:
    procedure = "lab.usp_MonthEndSalesBaseline" if name.startswith("04") else "lab.usp_MonthEndSalesOptimized"
    body = procedure_body(name, procedure)
    assert re.search(
        r"SUM\(CONVERT\(DECIMAL\(38,4\), FS\.SALESAMOUNT\)\)\s*/\s*"
        r"NULLIF\(SUM\(CONVERT\(DECIMAL\(38,4\), FS\.ORDERQTY\)\), 0\)",
        body,
    )


@pytest.mark.parametrize("name", ["04-CreateBaselineProcedure.sql", "06-CreateOptimizedProcedure.sql"])
def test_procedure_output_contract_and_order_are_explicit(name: str) -> None:
    body = procedure_body(
        name,
        "lab.usp_MonthEndSalesBaseline" if name.startswith("04") else "lab.usp_MonthEndSalesOptimized",
    )
    for contract in (
        "TERRITORYID INT",
        "CUSTOMERID INT",
        "PRODUCTID INT",
        "ORDERCOUNT BIGINT",
        "TOTALQUANTITY BIGINT",
        "TOTALSALES DECIMAL(38,4)",
        "AVERAGEUNITPRICE DECIMAL(19,4)",
        "SALESRANK BIGINT",
        "ORDER BY SALESRANK, CASE WHEN TERRITORYID IS NULL THEN 0 ELSE 1 END, TERRITORYID, CUSTOMERID, PRODUCTID",
    ):
        assert contract in body


def test_equivalence_harness_checks_metadata_rows_sets_hashes_order_and_errors() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    assert "SYS.DM_EXEC_DESCRIBE_FIRST_RESULT_SET_FOR_OBJECT" in text
    for token in ("COLUMN_ORDINAL", "NAME", "SYSTEM_TYPE_NAME", "IS_NULLABLE"):
        assert token in text
    assert "#BASELINE" in text and "#OPTIMIZED" in text
    assert text.count("EXCEPT") >= 4
    assert "COUNT_BIG(*)" in text
    assert "HASHBYTES('SHA2_256'" in text
    assert "CONCAT_WS" in text and "STRING_AGG" in text
    assert "BASELINEEXCEPTOPTIMIZED" in text and "OPTIMIZEDEXCEPTBASELINE" in text
    assert "IDENTITY" in text and "SALESRANK" in text
    assert "INVALIDINPUTCASES" in text and "ERROR_NUMBER()" in text and "ERROR_MESSAGE()" in text
    assert "LAB.VALIDATIONRUN" in text


def test_workload_trial_metrics_are_correlated_to_the_exact_trial_interval() -> None:
    text = (ROOT / "workload" / "Workshop.Workload.psm1").read_text(encoding="utf-8").upper()
    assert "LAST_EXECUTION_TIME >= @STARTED" in text
    assert "LAST_EXECUTION_TIME <= @COMPLETED" in text


def test_equivalence_harness_rejects_an_existing_transaction_before_side_effects() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    guard = re.search(r"IF\s+@@TRANCOUNT\s*<>\s*0\s+THROW\s+51515,\s*'[^']*TRANSACTION[^']*'", text)
    assert guard
    for side_effect in (
        "SET NOCOUNT ON",
        "SET XACT_ABORT ON",
        "SP_SET_SESSION_CONTEXT",
        "CREATE TABLE LAB.VALIDATIONRUN",
        "INSERT LAB.VALIDATIONRUN",
    ):
        assert guard.start() < text.index(side_effect)


def test_equivalence_harness_protects_and_restores_exact_session_context_values() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    raw_text = sql("07-ValidateEquivalence.sql").upper()
    first_try = text.index("BEGIN TRY")
    set_run_id = text.index(
        "EXEC SYS.SP_SET_SESSION_CONTEXT @KEY = N'WORKSHOPRUNID', @VALUE = @VALIDATIONRUNIDCONTEXT"
    )
    set_manual = text.index(
        "EXEC SYS.SP_SET_SESSION_CONTEXT @KEY = N'WORKSHOPMANUALEXECUTION', "
        "@VALUE = @VALIDATIONMANUALEXECUTIONCONTEXT"
    )
    assert first_try < set_run_id < set_manual < text.index("CREATE TABLE LAB.VALIDATIONRUN")
    assert "DECLARE @ORIGINALRUNID SQL_VARIANT = SESSION_CONTEXT(N'WORKSHOPRUNID')" in text
    assert "DECLARE @ORIGINALMANUALEXECUTION SQL_VARIANT = SESSION_CONTEXT(N'WORKSHOPMANUALEXECUTION')" in text
    assert "DECLARE @VALIDATIONBATCHID UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER, SESSION_CONTEXT(N'CANDIDATEAPPROVALID'))" in text
    assert "DECLARE @VALIDATIONRUNIDCONTEXT SQL_VARIANT = CONVERT(SQL_VARIANT, @VALIDATIONBATCHID)" in text
    assert "DECLARE @VALIDATIONMANUALEXECUTIONCONTEXT SQL_VARIANT = CONVERT(SQL_VARIANT, CONVERT(INT, 1))" in text
    assert "@VALUE = @ORIGINALRUNID" in text
    assert "@VALUE = @ORIGINALMANUALEXECUTION" in text
    assert "@READ_ONLY = 1" not in text
    assert text.count("EXEC SYS.SP_SET_SESSION_CONTEXT @KEY = N'WORKSHOPRUNID', @VALUE = @ORIGINALRUNID") >= 2
    assert text.count(
        "EXEC SYS.SP_SET_SESSION_CONTEXT @KEY = N'WORKSHOPMANUALEXECUTION', "
        "@VALUE = @ORIGINALMANUALEXECUTION"
    ) >= 2
    assert "SESSION SHOULD BE DISCARDED" in raw_text
    assert text.index("INSERT LAB.VALIDATIONRUN") > set_manual


def test_equivalence_failures_have_bounded_case_specific_count_diagnostics() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    for case_name in ("VALIDATIONRUN-METADATA", "PROCEDURE-METADATA", "TERRITORY-CARDINALITY"):
        assert case_name in text
    for label in ("EXPECTEDCOUNT=", "ACTUALCOUNT=", "DIFFERENCECOUNT="):
        assert label in text
    for message in (
        "@ROWCOUNTMESSAGE",
        "@DIFFERENCEMESSAGE",
        "@HASHMESSAGE",
        "@ORDERMESSAGE",
        "@ERRORMESSAGE",
    ):
        assert f"THROW 515" in text
        assert re.search(rf"SET\s+{re.escape(message)}\s*=\s*LEFT\(", text)
    assert "EXPECTEDHASH=" in text and "ACTUALHASH=" in text
    assert re.search(r"@HASHMESSAGE.*?EXPECTEDCOUNT=.*?@BASELINEROWCOUNT.*?ACTUALCOUNT=.*?@OPTIMIZEDROWCOUNT", text)
    assert "EXPECTEDERRORNUMBER=" in text and "BASELINEERRORNUMBER=" in text
    assert "OPTIMIZEDERRORNUMBER=" in text and "EXPECTEDERRORMESSAGE=" in text
    assert "BASELINEERRORMESSAGE=" in text and "OPTIMIZEDERRORMESSAGE=" in text
    assert re.search(r"@ERRORMESSAGE.*?EXPECTEDCOUNT=1.*?ACTUALCOUNT=.*?@INVALIDCASEMATCHED.*?DIFFERENCECOUNT=1", text)


def test_cardinality_matrix_uses_fact_row_counts_not_territory_id_proxies() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    assert "FROM LAB.FACTSALES" in text
    assert "GROUP BY TERRITORYID" in text
    assert "COUNT_BIG(*) AS EXPECTEDROWCOUNT" in text
    assert "ROW_NUMBER() OVER (ORDER BY EXPECTEDROWCOUNT, TERRITORYID)" in text
    assert "LOW" in text and "MEDIUM" in text and "HIGH" in text
    assert "@LOWEXPECTEDROWCOUNT" in text
    assert "@MEDIUMEXPECTEDROWCOUNT" in text
    assert "@HIGHEXPECTEDROWCOUNT" in text
    assert "@DISTINCTTERRITORYCOUNT < 3" in text
    assert "@SELECTEDTERRITORYCOUNT <> 3" in text
    assert "CARDINALITYLABEL" in text and "EXPECTEDTERRITORYROWCOUNT" in text
    assert "ACTUALTERRITORYROWCOUNT" in text
    assert "PRINT" in text and "TERRITORY CARDINALITY" in text
    assert "MIN(TERRITORYID)" not in text and "MAX(TERRITORYID)" not in text


def test_equivalence_matrix_has_at_least_eight_deterministic_cases() -> None:
    text = normalized("07-ValidateEquivalence.sql")
    values = re.search(r"INSERT\s+@CASES.*?VALUES(?P<values>.*?);", text)
    assert values
    case_names = re.findall(r"\(N'([^']+)'", values.group("values"))
    assert len(case_names) >= 8
    for required in (
        "NARROW-NULL-TERRITORY",
        "BROAD-NULL-TERRITORY",
        "LOW-TERRITORY",
        "MEDIUM-TERRITORY",
        "HIGH-TERRITORY",
        "TOP-MINIMUM",
        "TOP-MAXIMUM",
        "NO-MATCH",
        "DATE-BOUNDARY",
    ):
        assert required in case_names
    assert "2018-01-01" in text and "2024-01-01" in text


def test_task9_scripts_avoid_sqlcmd_injection_and_unbounded_or_destructive_operations() -> None:
    combined = "\n".join(sql(name) for name in (
        "04-CreateBaselineProcedure.sql",
        "06-CreateOptimizedProcedure.sql",
        "07-ValidateEquivalence.sql",
    ))
    upper = combined.upper()
    assert not re.search(r"\$\(\w+\)", combined)
    assert "DBCC DROPCLEANBUFFERS" not in upper
    assert "DBCC FREEPROCCACHE" not in upper
    assert "WHILE 1 = 1" not in upper
    assert "DROP DATABASE" not in upper


DIAGNOSTIC_PROCEDURES = (
    "lab.usp_GetMemorySnapshot",
    "lab.usp_GetActiveWorkshopGrants",
    "lab.usp_GetQueryStoreTopQueries",
    "lab.usp_GetQueryStoreWaits",
    "lab.usp_GetProcedurePlanSummary",
    "lab.usp_CompareWorkshopRuns",
)


def diagnostic_batch(procedure: str) -> str:
    expression = re.compile(
        rf"^CREATE\s+OR\s+ALTER\s+PROCEDURE\s+{re.escape(procedure)}\b",
        re.IGNORECASE,
    )
    return next(batch for batch in batches("05-CreateDiagnostics.sql") if expression.search(batch))


def test_diagnostics_require_exact_database_marker_and_no_user_transaction() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    transaction_guard = re.search(
        r"IF\s+@@TRANCOUNT\s*<>\s*0\s+THROW\s+51600,\s*'[^']*TRANSACTION[^']*'",
        text,
    )
    assert transaction_guard
    for contract in (
        "DB_NAME() <> N'ADVENTUREWORKS2022'",
        "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C",
        "N'MCP SQL QUERY STORE WORKSHOP'",
        "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B",
        "SESSION_CONTEXT(N'DIAGNOSTICSSETUPAUTHORIZED')",
    ):
        assert contract in text
    first_side_effect = min(
        text.index("SET NOCOUNT ON"),
        text.index("CREATE TABLE LAB.WORKSHOPRUN"),
    )
    assert transaction_guard.start() < first_side_effect
    assert not re.search(r"\$\(\w+\)", sql("05-CreateDiagnostics.sql"))


def test_evidence_tables_are_exact_idempotent_and_constrained() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for table in ("WORKSHOPRUN", "WORKSHOPSAMPLE", "WORKSHOPREQUESTSAMPLE"):
        assert f"IF OBJECT_ID(N'LAB.{table}', N'U') IS NULL" in text
        assert f"CREATE TABLE LAB.{table}" in text
    for contract in (
        "RUNID UNIQUEIDENTIFIER NOT NULL",
        "CONSTRAINT PK_WORKSHOPRUN PRIMARY KEY",
        "EVIDENCECLASSIFICATION",
        "FROZENSETTINGSHASH VARBINARY(32)",
        "FROZENSETTINGSJSON NVARCHAR(4000)",
        "BASELINEQUERYID BIGINT",
        "OPTIMIZEDQUERYID BIGINT",
        "CONSTRAINT FK_WORKSHOPSAMPLE_WORKSHOPRUN FOREIGN KEY",
        "CONSTRAINT FK_WORKSHOPREQUESTSAMPLE_WORKSHOPSAMPLE FOREIGN KEY",
        "POOLTOTALMEMORYKB BIGINT",
        "POOLGRANTEDMEMORYKB BIGINT",
        "POOLUSEDMEMORYKB BIGINT",
        "POOLAVAILABLEMEMORYKB BIGINT",
        "GRANTUTILIZATIONPERCENT DECIMAL(9,6)",
        "REQUESTEDMEMORYKB BIGINT",
        "GRANTEDMEMORYKB BIGINT",
        "REQUIREDMEMORYKB BIGINT",
        "IDEALMEMORYKB BIGINT",
        "USEDMEMORYKB BIGINT",
        "MAXUSEDMEMORYKB BIGINT",
        "QUERYID BIGINT",
        "PLANID BIGINT",
    ):
        assert contract in text
    assert "CHECK (GRANTUTILIZATIONPERCENT BETWEEN 0 AND 100)" in text
    assert text.count("CHECK (") >= 12
    assert "EXISTING EVIDENCE TABLE" in text and "CONTRACT IS INCOMPATIBLE" in text
    assert text.count("FROM SYS.COLUMNS") >= 2
    assert "SQLTEXT" not in text and "QUERYSQLTEXT" not in text


def test_workshop_sample_decimal_contract_migrates_legacy_rows_before_metadata_verification() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    migration = text.index("ALTER TABLE LAB.WORKSHOPSAMPLE ALTER COLUMN GRANTUTILIZATIONPERCENT DECIMAL(9,6) NOT NULL")
    metadata = text.index("DECLARE @EXPECTEDCOLUMNS TABLE")
    assert migration < metadata
    assert "C.PRECISION = 6" in text[:metadata]
    assert "C.SCALE = 2" in text[:metadata]
    assert "(N'WORKSHOPSAMPLE', 9, N'GRANTUTILIZATIONPERCENT', N'DECIMAL', 5, 9, 6, 0, 0)" in text


def test_legacy_precision_migration_validates_and_rebuilds_the_exact_check_contract() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    alter_marker = text.index(
        "ALTER COLUMN GRANTUTILIZATIONPERCENT DECIMAL(9,6) NOT NULL"
    )
    migration = text[
        text.rfind("IF EXISTS", 0, alter_marker):
        text.index("IF OBJECT_ID(N'LAB.WORKSHOPREQUESTSAMPLE', N'U') IS NULL")
    ]
    validation = migration.index("EXISTING LEGACY WORKSHOPSAMPLE UTILIZATION CHECK CONTRACT IS INCOMPATIBLE")
    drop_constraint = migration.index("DROP CONSTRAINT CK_WORKSHOPSAMPLE_UTILIZATION")
    alter_column = migration.index(
        "ALTER COLUMN GRANTUTILIZATIONPERCENT DECIMAL(9,6) NOT NULL"
    )
    recreate = migration.index(
        "WITH CHECK ADD CONSTRAINT CK_WORKSHOPSAMPLE_UTILIZATION CHECK (GRANTUTILIZATIONPERCENT BETWEEN 0 AND 100)"
    )
    trust = migration.index("WITH CHECK CHECK CONSTRAINT CK_WORKSHOPSAMPLE_UTILIZATION")

    assert "TEMPDB.SYS.CHECK_CONSTRAINTS" in migration
    assert "CC.DEFINITION COLLATE LATIN1_GENERAL_100_BIN2" in migration
    assert "SYS.SQL_EXPRESSION_DEPENDENCIES" in migration
    assert validation < drop_constraint < alter_column < recreate < trust
    assert "BEGIN TRY BEGIN TRANSACTION" in migration
    assert "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION" in migration
    assert "THROW;" in migration


def test_validation_run_contract_is_task9_compatible_and_verified() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for contract in (
        "VALIDATIONRUNID BIGINT IDENTITY(1,1)",
        "VALIDATIONBATCHID UNIQUEIDENTIFIER NOT NULL",
        "BASELINERUNID UNIQUEIDENTIFIER NULL",
        "OPTIMIZEDRUNID UNIQUEIDENTIFIER NULL",
        "VALIDATIONCASENAME SYSNAME NOT NULL",
        "BASELINEHASH VARBINARY(32) NOT NULL",
        "OPTIMIZEDHASH VARBINARY(32) NOT NULL",
        "VALIDATEDATUTC DATETIME2(0) NOT NULL",
        "@EXPECTEDCOLUMNS",
        "OBJECT_ID(N'LAB.VALIDATIONRUN')",
        "EXCEPT",
        "EXISTING EVIDENCE TABLE COLUMN CONTRACT IS INCOMPATIBLE",
    ):
        assert contract in text
    assert "RUNID NVARCHAR(128)" not in text

    task9 = normalized("07-ValidateEquivalence.sql")
    assert (
        "DECLARE @VALIDATIONBATCHID UNIQUEIDENTIFIER = TRY_CONVERT(UNIQUEIDENTIFIER, "
        "SESSION_CONTEXT(N'CANDIDATEAPPROVALID'))"
    ) in task9
    assert "VALIDATIONBATCHID UNIQUEIDENTIFIER NOT NULL" in task9
    assert "BASELINERUNID UNIQUEIDENTIFIER NULL" in task9
    assert "OPTIMIZEDRUNID UNIQUEIDENTIFIER NULL" in task9
    assert "INSERT LAB.VALIDATIONRUN" in task9
    assert "(VALIDATIONBATCHID, BASELINERUNID, OPTIMIZEDRUNID, VALIDATIONCASENAME" in task9


def test_workshop_trial_has_exact_ordered_persistence_contract() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    assert "IF OBJECT_ID(N'LAB.WORKSHOPTRIAL', N'U') IS NULL" in text
    assert "CREATE TABLE LAB.WORKSHOPTRIAL" in text
    expected_columns = (
        (1, "RUNID", "UNIQUEIDENTIFIER", 16, 0, 0, 0, 0),
        (2, "TRIALSEQUENCE", "INT", 4, 10, 0, 0, 0),
        (3, "PARAMETERSLOT", "INT", 4, 10, 0, 0, 0),
        (4, "PHASE", "VARCHAR", 16, 0, 0, 0, 0),
        (5, "DURATIONMS", "BIGINT", 8, 19, 0, 0, 0),
        (6, "CPUMS", "BIGINT", 8, 19, 0, 0, 0),
        (7, "LOGICALREADS", "BIGINT", 8, 19, 0, 0, 0),
        (8, "GRANTEDKB", "BIGINT", 8, 19, 0, 0, 0),
        (9, "USEDKB", "BIGINT", 8, 19, 0, 0, 0),
        (10, "SPILLKB", "BIGINT", 8, 19, 0, 0, 0),
        (11, "WAITMS", "BIGINT", 8, 19, 0, 0, 0),
        (12, "RESULTROWCOUNT", "BIGINT", 8, 19, 0, 0, 0),
        (13, "RESULTHASH", "VARBINARY", 32, 0, 0, 0, 0),
        (14, "EXPECTEDROWCOUNT", "BIGINT", 8, 19, 0, 0, 0),
        (15, "ACTUALROWCOUNT", "BIGINT", 8, 19, 0, 0, 0),
        (16, "DIFFERENCECOUNT", "BIGINT", 8, 19, 0, 0, 0),
        (17, "CORRECT", "BIT", 1, 1, 0, 0, 0),
        (18, "VALIDATIONBATCHID", "UNIQUEIDENTIFIER", 16, 0, 0, 0, 0),
        (19, "STARTEDATUTC", "DATETIME2", 7, 23, 3, 0, 0),
        (20, "COMPLETEDATUTC", "DATETIME2", 7, 23, 3, 0, 0),
    )
    for column_id, name, type_name, max_length, precision, scale, nullable, identity in expected_columns:
        assert (
            f"(N'WORKSHOPTRIAL', {column_id}, N'{name}', N'{type_name}', "
            f"{max_length}, {precision}, {scale}, {nullable}, {identity})"
        ) in text


def test_workshop_trial_has_exact_keys_checks_and_validation_index() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for contract in (
        "CONSTRAINT PK_WORKSHOPTRIAL PRIMARY KEY (RUNID, TRIALSEQUENCE)",
        "CONSTRAINT FK_WORKSHOPTRIAL_WORKSHOPRUN FOREIGN KEY (RUNID) REFERENCES LAB.WORKSHOPRUN (RUNID)",
        "CONSTRAINT CK_WORKSHOPTRIAL_SEQUENCE CHECK (TRIALSEQUENCE BETWEEN 1 AND 12)",
        "CONSTRAINT CK_WORKSHOPTRIAL_PARAMETERSLOT CHECK (PARAMETERSLOT BETWEEN 1 AND 6)",
        "CONSTRAINT CK_WORKSHOPTRIAL_PHASE CHECK (PHASE IN ('BASELINE', 'OPTIMIZED'))",
        "CONSTRAINT CK_WORKSHOPTRIAL_SCHEDULE CHECK",
        "CONSTRAINT CK_WORKSHOPTRIAL_METRICS CHECK",
        "CONSTRAINT CK_WORKSHOPTRIAL_VALIDATION CHECK",
        "CONSTRAINT CK_WORKSHOPTRIAL_TIMESTAMPS CHECK (COMPLETEDATUTC >= STARTEDATUTC)",
        "CREATE INDEX IX_WORKSHOPTRIAL_VALIDATIONBATCHID ON LAB.WORKSHOPTRIAL (VALIDATIONBATCHID, RUNID)",
    ):
        assert contract in text
    for metric in (
        "DURATIONMS", "CPUMS", "LOGICALREADS", "GRANTEDKB", "USEDKB", "SPILLKB", "WAITMS",
        "RESULTROWCOUNT", "EXPECTEDROWCOUNT", "ACTUALROWCOUNT", "DIFFERENCECOUNT",
    ):
        assert f"{metric} >= 0" in text
    assert "DATALENGTH(RESULTHASH) = 32" in text
    assert "CORRECT = 1 AND DIFFERENCECOUNT = 0" in text
    assert "CORRECT = 0 AND DIFFERENCECOUNT > 0" in text
    for metadata in (
        "PK_WORKSHOPTRIAL", "FK_WORKSHOPTRIAL_WORKSHOPRUN", "IX_WORKSHOPTRIAL_VALIDATIONBATCHID",
        "CK_WORKSHOPTRIAL_SEQUENCE", "CK_WORKSHOPTRIAL_PARAMETERSLOT", "CK_WORKSHOPTRIAL_PHASE",
        "CK_WORKSHOPTRIAL_SCHEDULE", "CK_WORKSHOPTRIAL_METRICS", "CK_WORKSHOPTRIAL_VALIDATION",
        "CK_WORKSHOPTRIAL_TIMESTAMPS",
        "#EXPECTEDWORKSHOPTRIALCHECKSHAPE",
    ):
        assert metadata in text
    assert "OBJECT_ID(N'LAB.WORKSHOPTRIAL') IS NOT NULL AND OBJECT_ID(N'LAB.WORKSHOPTRIAL', N'U') IS NULL" in text
    assert "REFERENCED_SCHEMA" in text
    assert "OBJECT_SCHEMA_NAME(FK.REFERENCED_OBJECT_ID)" in text
    assert "@EXPECTEDWORKSHOPTRIALINDEXCOLUMNS" in text
    assert "INDEX_COLUMN_ID" in text and "IS_INCLUDED_COLUMN" in text
    assert "@EXPECTEDWORKSHOPTRIALCHECKDEFINITIONS" in text
    exact_check_region = text[
        text.index("DECLARE @EXPECTEDWORKSHOPTRIALCHECKDEFINITIONS"):
        text.index("THROW 51604, 'EXISTING WORKSHOPTRIAL CHECK DEFINITION CONTRACT IS INCOMPATIBLE.'")
    ]
    assert "CC.DEFINITION COLLATE LATIN1_GENERAL_100_BIN2" in exact_check_region
    assert "REPLACE(" not in exact_check_region


def test_workshop_trial_schedule_constraint_enforces_exact_mapping_and_metadata() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    expected_pairs = (
        (1, 1, "BASELINE"),
        (2, 1, "OPTIMIZED"),
        (3, 2, "OPTIMIZED"),
        (4, 2, "BASELINE"),
        (5, 3, "OPTIMIZED"),
        (6, 3, "BASELINE"),
        (7, 4, "BASELINE"),
        (8, 4, "OPTIMIZED"),
        (9, 5, "BASELINE"),
        (10, 5, "OPTIMIZED"),
        (11, 6, "OPTIMIZED"),
        (12, 6, "BASELINE"),
    )
    for sequence, slot, phase in expected_pairs:
        mapping = (
            f"TRIALSEQUENCE = {sequence} AND PARAMETERSLOT = {slot} AND PHASE = '{phase}'"
        )
        assert text.count(mapping) == 4

    assert "ALTER TABLE LAB.WORKSHOPTRIAL WITH CHECK ADD CONSTRAINT CK_WORKSHOPTRIAL_SCHEDULE CHECK" in text
    assert "ALTER TABLE LAB.WORKSHOPTRIAL WITH CHECK CHECK CONSTRAINT CK_WORKSHOPTRIAL_SCHEDULE" in text
    assert "(N'WORKSHOPTRIAL', N'CK_WORKSHOPTRIAL_SCHEDULE', 0, 0, 0)" in text
    for column in ("TRIALSEQUENCE", "PARAMETERSLOT", "PHASE"):
        assert f"(N'CK_WORKSHOPTRIAL_SCHEDULE', N'{column}')" in text

    invariant_marker = text.index("#EXPECTEDWORKSHOPTRIALSCHEDULEINVARIANT")
    migration_start = text.rfind("BEGIN TRY", 0, invariant_marker)
    migration_end = text.index("DECLARE @EXPECTEDCOLUMNS TABLE")
    migration = text[migration_start:migration_end]
    assert "TEMPDB.SYS.CHECK_CONSTRAINTS" in migration
    assert "CC.DEFINITION COLLATE LATIN1_GENERAL_100_BIN2" in migration
    assert "CC.IS_DISABLED = 0" in migration
    assert "CC.IS_NOT_TRUSTED = 0" in migration
    assert "CC.IS_NOT_FOR_REPLICATION = 0" in migration
    assert "EXISTING WORKSHOPTRIAL SCHEDULE CHECK CONTRACT IS INCOMPATIBLE" in migration
    assert "BEGIN TRY BEGIN TRANSACTION" in migration
    assert "IF XACT_STATE() <> 0 ROLLBACK TRANSACTION" in migration


def test_workshop_trial_schedule_migration_is_serialized_and_always_releases_lock() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    migration_start = text.index("DECLARE @WORKSHOPTRIALSCHEDULELOCKRESULT")
    migration_end = text.index("DECLARE @EXPECTEDCOLUMNS TABLE")
    migration = text[migration_start:migration_end]

    acquire = migration.index("SYS.SP_GETAPPLOCK")
    metadata_check = migration.index("TEMPDB.SYS.CHECK_CONSTRAINTS")
    alter = migration.index("ALTER TABLE LAB.WORKSHOPTRIAL WITH CHECK")
    success_release = migration.index("SYS.SP_RELEASEAPPLOCK", alter)
    catch = migration.index("BEGIN CATCH", success_release)
    error_release = migration.index("SYS.SP_RELEASEAPPLOCK", catch)

    assert "@RESOURCE = N'MCP_SQL_WORKSHOP_LIFECYCLE'" in migration
    assert "@LOCKMODE = N'EXCLUSIVE'" in migration
    assert "@LOCKOWNER = N'SESSION'" in migration
    assert "@LOCKTIMEOUT = 0" in migration
    assert acquire < metadata_check < alter < success_release < catch < error_release
    assert "IF @WORKSHOPTRIALSCHEDULELOCKRESULT < 0" in migration
    assert "SET @WORKSHOPTRIALSCHEDULELOCKHELD = 1" in migration
    assert "SET @WORKSHOPTRIALSCHEDULELOCKHELD = 0" in migration
    assert "THROW;" in migration[catch:]


def test_cleanup_recognizes_and_removes_workshop_trial_schedule_constraint() -> None:
    text = normalized("09-Cleanup.sql")
    inventory = text[
        text.index("DECLARE @EXPECTEDLABCONSTRAINTS TABLE"):
        text.index("DECLARE @EXPECTEDLABTRIGGERS TABLE")
    ]
    drop = "ALTER TABLE LAB.WORKSHOPTRIAL DROP CONSTRAINT CK_WORKSHOPTRIAL_SCHEDULE"

    assert "(N'WORKSHOPTRIAL', N'CK_WORKSHOPTRIAL_SCHEDULE', 'C')" in inventory
    assert drop in text
    assert text.index(drop) < text.index(
        "ALTER TABLE LAB.WORKSHOPTRIAL DROP CONSTRAINT PK_WORKSHOPTRIAL"
    )


def test_workshop_trial_is_not_reader_exposed_and_has_exact_denies() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for permission in ("INSERT", "UPDATE", "DELETE", "ALTER", "CONTROL"):
        assert f"DENY {permission} ON OBJECT::LAB.WORKSHOPTRIAL TO [MCP_WORKSHOP_READER]" in text
        assert f"(1, OBJECT_ID(N'LAB.WORKSHOPTRIAL'), 0, N'{permission}', N'D')" in text
        assert f"N'LAB.WORKSHOPTRIAL', N'OBJECT', N'{permission}'" in text
    assert "GRANT SELECT ON OBJECT::LAB.WORKSHOPTRIAL TO [MCP_WORKSHOP_READER]" not in text


def test_all_four_evidence_tables_have_exact_deterministic_column_metadata_checks() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for table, last_column in (
        ("WORKSHOPRUN", "WAITTIMEMS"),
        ("WORKSHOPSAMPLE", "PROCESSLOWMEMORYSIGNAL"),
        ("WORKSHOPREQUESTSAMPLE", "PLANID"),
        ("VALIDATIONRUN", "VALIDATEDATUTC"),
    ):
        assert f"N'{table}'" in text
        assert f"N'{last_column}'" in text
    for metadata in (
        "COLUMN_ID",
        "TYPE_NAME",
        "MAX_LENGTH",
        "PRECISION",
        "SCALE",
        "IS_NULLABLE",
        "IS_IDENTITY",
        "IDENTITY_SEED",
        "IDENTITY_INCREMENT",
    ):
        assert metadata in text
    assert "TYPE_NAME(C.USER_TYPE_ID)" in text
    assert "SYS.IDENTITY_COLUMNS" in text
    assert "@EXPECTEDCOLUMNS" in text
    assert text.count("EXCEPT") >= 12
    assert "COUNT(*) FROM SYS.COLUMNS" not in text


def test_all_four_evidence_tables_validate_exact_keys_indexes_defaults_and_checks() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    for expected_table in (
        "@EXPECTEDPRIMARYKEYCOLUMNS",
        "@EXPECTEDFOREIGNKEYCOLUMNS",
        "@EXPECTEDUNIQUEINDEXCOLUMNS",
        "@EXPECTEDDEFAULTS",
        "@EXPECTEDCHECKS",
    ):
        assert expected_table in text
    for catalog in (
        "SYS.KEY_CONSTRAINTS",
        "SYS.INDEXES",
        "SYS.INDEX_COLUMNS",
        "SYS.FOREIGN_KEYS",
        "SYS.FOREIGN_KEY_COLUMNS",
        "DELETE_REFERENTIAL_ACTION_DESC",
        "UPDATE_REFERENTIAL_ACTION_DESC",
        "IS_NOT_FOR_REPLICATION",
        "SYS.DEFAULT_CONSTRAINTS",
        "SYS.CHECK_CONSTRAINTS",
    ):
        assert catalog in text
    for table in ("WORKSHOPRUN", "WORKSHOPSAMPLE", "WORKSHOPREQUESTSAMPLE", "VALIDATIONRUN"):
        assert f"PK_{table}" in text
    assert "FK_WORKSHOPSAMPLE_WORKSHOPRUN" in text
    assert "FK_WORKSHOPREQUESTSAMPLE_WORKSHOPSAMPLE" in text
    assert "FK_VALIDATIONRUN_BASELINEWORKSHOPRUN" in text
    assert "FK_VALIDATIONRUN_OPTIMIZEDWORKSHOPRUN" in text
    assert "IS_DISABLED" in text and "IS_HYPOTHETICAL" in text
    assert re.search(r"SYS\.INDEXES.*?I\.IS_DISABLED.*?I\.IS_HYPOTHETICAL", text)
    assert re.search(r"SYS\.CHECK_CONSTRAINTS.*?CC\.IS_NOT_FOR_REPLICATION", text)
    assert "SYS.DEFAULT_CONSTRAINTS" in text and "DC.DEFINITION" in text
    assert text.index("THROW 51604") < text.index("CREATE OR ALTER VIEW LAB.VW_WORKSHOPRUNSUMMARY")


def test_check_validation_uses_engine_normalized_full_definition_hashes() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    assert "@EXPECTEDCHECKCOLUMNS" in text
    assert "SYS.SQL_EXPRESSION_DEPENDENCIES" in text
    check_region = text[text.index("DECLARE @EXPECTEDCHECKS"):text.index("CREATE OR ALTER VIEW LAB.VW_WORKSHOPRUNSUMMARY")]
    for expected_shape in (
        "#EXPECTEDWORKSHOPRUNCHECKSHAPE",
        "#EXPECTEDWORKSHOPSAMPLECHECKSHAPE",
        "#EXPECTEDWORKSHOPREQUESTSAMPLECHECKSHAPE",
        "#EXPECTEDVALIDATIONRUNCHECKSHAPE",
    ):
        assert expected_shape in check_region
    assert "TEMPDB.SYS.CHECK_CONSTRAINTS" in check_region
    assert "HASHBYTES(N'SHA2_256'" in check_region
    assert "NORMALIZED_DEFINITION_HASH" in check_region
    assert "EXPECTED_DEFINITION_HASH" in check_region
    assert "ACTUAL_DEFINITION_HASH" in check_region
    assert "EXCEPT" in check_region


def test_check_validation_has_no_token_or_literal_count_acceptance_path() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    check_region = text[text.index("DECLARE @EXPECTEDCHECKS"):text.index("CREATE OR ALTER VIEW LAB.VW_WORKSHOPRUNSUMMARY")]
    for weak_acceptance_marker in (
        "@EXPECTEDCHECKTOKENS",
        "REQUIRED_TOKEN",
        "CHARINDEX(EXPECTED.REQUIRED_TOKEN",
        "EXPECTED_STRING_LITERAL_COUNT",
    ):
        assert weak_acceptance_marker not in check_region

    assert "REPLACE(REPLACE(REPLACE(REPLACE(" in check_region
    assert "N'[', N''" in check_region
    assert "N']', N''" in check_region
    assert "N'(', N''" not in check_region
    assert "N')', N''" not in check_region


def test_workshop_outcome_check_has_only_the_exact_allowed_terminal_states() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    expected = (
        "OUTCOME IS NULL OR OUTCOME IN ('TARGETMET', 'IMPROVEDOUTSIDETARGET', "
        "'NOMATERIALIMPROVEMENT', 'BASELINETARGETNOTREACHED', 'SAFETYSTOP', "
        "'MANUALSTOP', 'FAILED')"
    )
    assert expected in text
    for legacy in ("'IMPROVED'", "'INCONCLUSIVE'", "'REGRESSED'"):
        assert legacy not in text


def test_validation_batch_remains_unlinked_and_uses_workshop_trials_for_experiment_linkage() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    assert "CREATE OR ALTER PROCEDURE LAB.USP_LINKVALIDATIONBATCH" not in text
    assert "UPDATE LAB.VALIDATIONRUN SET BASELINERUNID" not in text
    comparison = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_CompareWorkshopRuns")).upper()
    assert "FROM LAB.WORKSHOPTRIAL" in comparison
    assert "VALIDATIONBATCHID = @VALIDATIONBATCHID" in comparison
    assert "CORRECT = 1" in comparison


def test_six_diagnostic_procedures_are_separate_stable_owner_batches() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    assert text.count("CREATE OR ALTER PROCEDURE LAB.USP_") == 6
    for procedure in DIAGNOSTIC_PROCEDURES:
        batch = re.sub(r"\s+", " ", diagnostic_batch(procedure)).upper()
        assert "WITH EXECUTE AS OWNER" in batch
        assert "SET NOCOUNT ON" in batch
        assert "SELECT" in batch
    assert len(batches("05-CreateDiagnostics.sql")) >= 10


def test_live_memory_diagnostics_are_bounded_filtered_and_secret_free() -> None:
    snapshot = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_GetMemorySnapshot")).upper()
    assert "SYS.DM_RESOURCE_GOVERNOR_RESOURCE_POOLS" in snapshot
    assert "SYS.DM_EXEC_QUERY_RESOURCE_SEMAPHORES" in snapshot
    assert "RP.NAME = N'MCP_SQL_WORKSHOP_POOL'" in snapshot
    assert "RS.RESOURCE_SEMAPHORE_ID = 0" in snapshot
    assert "CAST(100.0 * RS.GRANTED_MEMORY_KB / NULLIF(RS.TOTAL_MEMORY_KB, 0) AS DECIMAL(9,6))" in snapshot
    assert "RS.TOTAL_MEMORY_KB - RS.GRANTED_MEMORY_KB" in snapshot
    assert "SYS.DM_OS_SYS_MEMORY" in snapshot and "SYS.DM_OS_PROCESS_MEMORY" in snapshot
    assert "SYS.DM_OS_PERFORMANCE_COUNTERS" in snapshot
    assert "THROW" in snapshot and "POOL" in snapshot
    assert "MEMORY SNAPSHOT SOURCES ARE UNAVAILABLE" in snapshot
    assert re.search(
        r"PROCESS\.PROCESS_PHYSICAL_MEMORY_LOW\) AS PROCESSPHYSICALMEMORYLOW",
        snapshot,
    )
    assert re.search(
        r"PROCESS\.PROCESS_VIRTUAL_MEMORY_LOW\) AS PROCESSVIRTUALMEMORYLOW",
        snapshot,
    )
    assert re.search(
        r"HOST\.SYSTEM_LOW_MEMORY_SIGNAL_STATE\) AS SYSTEMPHYSICALMEMORYLOW",
        snapshot,
    )
    assert re.search(
        r"HOST\.SYSTEM_HIGH_MEMORY_SIGNAL_STATE\) AS SYSTEMPHYSICALMEMORYHIGH",
        snapshot,
    )

    grants = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_GetActiveWorkshopGrants")).upper()
    assert "@TOP INT = 20" in grants and "@TOP NOT BETWEEN 1 AND 100" in grants
    assert "SELECT TOP (@TOP)" in grants and "ORDER BY" in grants
    assert "S.PROGRAM_NAME LIKE N'MCP-SQL-WORKSHOP%'" not in grants
    assert "@RUNID UNIQUEIDENTIFIER = NULL" in grants
    assert "@PHASE VARCHAR(16)" in grants
    assert "@PHASE NOT IN ('BASELINE', 'OPTIMIZED')" in grants
    assert "S.CONTEXT_INFO" in grants
    assert "DATALENGTH(S.CONTEXT_INFO) = 17" in grants
    assert "TRY_CONVERT(UNIQUEIDENTIFIER" in grants
    assert "SUBSTRING(S.CONTEXT_INFO, 17, 1)" in grants
    assert "WHEN 1 THEN 'BASELINE'" in grants
    assert "WHEN 2 THEN 'OPTIMIZED'" in grants
    assert "SESSIONCONTEXT.RUNID = @RUNID" in grants
    assert "SESSIONCONTEXT.PHASE = @PHASE" in grants
    assert "CONVERT(CHAR(36), SESSIONCONTEXT.RUNID)" in grants
    assert "S.PROGRAM_NAME COLLATE LATIN1_GENERAL_100_BIN2" in grants
    assert re.search(r"N'MCP-SQL-WORKSHOP-'.*?SESSIONCONTEXT\.PHASE.*?N'-1'", grants)
    assert re.search(r"N'MCP-SQL-WORKSHOP-'.*?SESSIONCONTEXT\.PHASE.*?N'-4'", grants)
    assert "LAB.WORKSHOPREQUESTSAMPLE" not in grants
    assert "CROSS APPLY" in grants
    assert "SYS.DM_EXEC_QUERY_MEMORY_GRANTS" in grants
    assert "SYS.DM_EXEC_REQUESTS" in grants and "SYS.DM_EXEC_SESSIONS" in grants
    assert "DM_EXEC_SQL_TEXT" not in grants and "SQL_HANDLE" not in grants


def test_workload_procedures_publish_run_id_for_cross_session_dmv_correlation() -> None:
    for name, procedure, phase_byte in (
        ("04-CreateBaselineProcedure.sql", "lab.usp_MonthEndSalesBaseline", "01"),
        ("06-CreateOptimizedProcedure.sql", "lab.usp_MonthEndSalesOptimized", "02"),
    ):
        body = procedure_body(name, procedure)
        assert "CONVERT(BINARY(16), @RUNID)" in body
        assert f"CONVERT(BINARY(16), @RUNID) + 0X{phase_byte}" in body
        assert "SET CONTEXT_INFO @RUNCONTEXTINFO" in body


def test_server_dmv_access_uses_minimal_certificate_module_signing() -> None:
    raw = sql("05-CreateDiagnostics.sql")
    text = normalized("05-CreateDiagnostics.sql")
    assert "SESSION_CONTEXT(N'DATABASEMASTERKEYREADY')" in text
    assert "##MS_DATABASEMASTERKEY##" in text
    assert "CREATE MASTER KEY" not in text
    assert "CREATE CERTIFICATE [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE]" in text
    assert "SERVERPROPERTY(N'INSTANCEDEFAULTBACKUPPATH')" in text
    assert "BACKUP CERTIFICATE [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE] TO FILE" in text
    assert "CREATE CERTIFICATE [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE] FROM FILE" in text
    assert "CREATE LOGIN [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN] FROM CERTIFICATE" in text
    assert "GRANT VIEW SERVER PERFORMANCE STATE TO [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN]" in text
    assert "GRANT VIEW SERVER STATE TO [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN]" not in text
    assert "GRANT VIEW SERVER PERFORMANCE STATE TO [MCP_WORKSHOP_READER]" not in text
    assert "GRANT VIEW SERVER STATE TO [MCP_WORKSHOP_READER]" not in text
    for procedure in ("USP_GETMEMORYSNAPSHOT", "USP_GETACTIVEWORKSHOPGRANTS"):
        assert f"ADD SIGNATURE TO OBJECT::LAB.{procedure}" in text
        assert f"OBJECT_ID(N'LAB.{procedure}', N'P')" in text
    assert "SYS.CRYPT_PROPERTIES" in text and "THUMBPRINT" in text
    assert "DATABASEPROPERTYEX(DB_NAME(), N'ISTRUSTWORTHYON')" in text
    assert "TRUSTWORTHY ON" not in text
    assert "PRIVATE KEY" not in text.upper()
    assert not re.search(r"(?i)WITH\s+PASSWORD\s*=\s*N?'[^']+?'", raw)
    assert "CERTIFICATE EXPORT IS PUBLIC" in text
    assert not re.search(r"(?i)(PASSWORD|SECRET)\s*=\s*N?'[^']+'", raw)


def test_query_store_diagnostics_validate_windows_scope_and_safe_procedure_enum() -> None:
    for procedure in ("lab.usp_GetQueryStoreTopQueries", "lab.usp_GetQueryStoreWaits"):
        body = re.sub(r"\s+", " ", diagnostic_batch(procedure)).upper()
        assert "@STARTUTC DATETIME2(0)" in body and "@ENDUTC DATETIME2(0)" in body
        assert "@TOP INT = 20" in body and "@TOP NOT BETWEEN 1 AND 100" in body
        assert "DATEDIFF(MINUTE, @STARTUTC, @ENDUTC) > 1440" in body
        assert "SELECT TOP (@TOP)" in body and "ORDER BY" in body
        assert "SYS.QUERY_STORE_QUERY" in body and "SYS.QUERY_STORE_RUNTIME_STATS_INTERVAL" in body
        assert "OBJECT_ID(N'LAB.USP_MONTHENDSALESBASELINE')" in body
        assert "OBJECT_ID(N'LAB.USP_MONTHENDSALESOPTIMIZED')" in body
    top = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_GetQueryStoreTopQueries")).upper()
    for metric in ("AVG_DURATION", "AVG_CPU_TIME", "AVG_LOGICAL_IO_READS", "COUNT_EXECUTIONS", "AVG_QUERY_MAX_USED_MEMORY"):
        assert metric in top
    waits = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_GetQueryStoreWaits")).upper()
    assert "SYS.QUERY_STORE_WAIT_STATS" in waits
    assert "WAIT_CATEGORY_DESC" in waits and "TOTAL_QUERY_WAIT_TIME_MS" in waits

    plans = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_GetProcedurePlanSummary")).upper()
    assert "@PROCEDURENAME SYSNAME" in plans
    assert "@PROCEDURENAME NOT IN (N'LAB.USP_MONTHENDSALESBASELINE', N'LAB.USP_MONTHENDSALESOPTIMIZED')" in plans
    assert "OBJECT_ID(@PROCEDURENAME, N'P')" in plans
    assert "QUERY_SQL_TEXT" not in plans
    assert not re.search(r"SELECT\s+(?:TOP\s*\([^)]*\)\s+)?[^;]*\bP\.QUERY_PLAN\s+(?:AS\s+)?QUERYPLAN", plans)
    assert "HASHBYTES('SHA2_256'" in plans
    assert "SP_EXECUTESQL" not in plans and "EXEC(" not in plans


def test_run_comparison_requires_exact_validation_linkage_and_material_improvement() -> None:
    body = re.sub(r"\s+", " ", diagnostic_batch("lab.usp_CompareWorkshopRuns")).upper()
    assert "@RUNID UNIQUEIDENTIFIER" in body
    assert "@BASELINERUNID UNIQUEIDENTIFIER" not in body
    assert "@OPTIMIZEDRUNID UNIQUEIDENTIFIER" not in body
    assert "@VALIDATIONBATCHID UNIQUEIDENTIFIER = NULL" in body
    assert "@PARENTCOMPARISONID UNIQUEIDENTIFIER" not in body
    assert "ROW_NUMBER() OVER (PARTITION BY" in body
    assert "COUNT_BIG(*) OVER (PARTITION BY" in body
    assert "PEAKGRANTUTILIZATIONPERCENT" in body
    assert "MEDIANGRANTUTILIZATIONPERCENT" in body
    for metric in ("DURATIONMS", "CPUMS", "LOGICALREADS", "SPILLS", "WAITTIMEMS"):
        assert metric in body
    for band in (
        "TARGETMET",
        "IMPROVEDOUTSIDETARGET",
        "NOMATERIALIMPROVEMENT",
        "BASELINETARGETNOTREACHED",
        "FAILED",
    ):
        assert f"N'{band}'" in body
    assert "BASELINEPEAKGRANTUTILIZATIONPERCENT BETWEEN 75.00 AND 85.00" in body
    assert "OPTIMIZEDPEAKGRANTUTILIZATIONPERCENT BETWEEN 35.00 AND 45.00" in body
    assert "BASELINEPEAKGRANTUTILIZATIONPERCENT - OPTIMIZEDPEAKGRANTUTILIZATIONPERCENT >= 25.00" in body
    assert "LAB.WORKSHOPTRIAL" in body
    assert "TRIAL.VALIDATIONBATCHID = @VALIDATIONBATCHID" in body
    assert "TRIAL.CORRECT = 1" in body
    assert "COUNT_BIG(*)" in body and "<> 12" in body
    assert "EXPECTEDTRIALS" in body
    for sequence, slot, phase in (
        (1, 1, "BASELINE"), (2, 1, "OPTIMIZED"),
        (3, 2, "OPTIMIZED"), (4, 2, "BASELINE"),
        (5, 3, "OPTIMIZED"), (6, 3, "BASELINE"),
        (7, 4, "BASELINE"), (8, 4, "OPTIMIZED"),
        (9, 5, "BASELINE"), (10, 5, "OPTIMIZED"),
        (11, 6, "OPTIMIZED"), (12, 6, "BASELINE"),
    ):
        assert re.search(rf"\(\s*{sequence}\s*,\s*{slot}\s*,\s*'{phase}'\s*\)", body)
    integrity_guard = body[:body.index(";WITH RANKEDSAMPLES")]
    assert integrity_guard.count("EXCEPT") >= 2
    assert "THROW 51666" in integrity_guard
    assert "CAST(AVG(" in body and "AS DECIMAL(9,6)) AS MEDIANGRANTUTILIZATIONPERCENT" in body
    assert "CONVERT(DECIMAL(9,6), BASELINEMEDIANGRANTUTILIZATIONPERCENT - OPTIMIZEDMEDIANGRANTUTILIZATIONPERCENT)" in body
    assert "CORRECTNESSPASSED" in body
    assert "HASMATERIALREGRESSION" in body
    assert "HASADDITIONALMETRICIMPROVEMENT" in body
    for pair in (
        ("BASELINEDURATIONMS", "OPTIMIZEDDURATIONMS"),
        ("BASELINECPUMS", "OPTIMIZEDCPUMS"),
        ("BASELINELOGICALREADS", "OPTIMIZEDLOGICALREADS"),
        ("BASELINESPILLS", "OPTIMIZEDSPILLS"),
        ("BASELINEWAITTIMEMS", "OPTIMIZEDWAITTIMEMS"),
    ):
        baseline, optimized = pair
        assert f"{baseline} = 0 AND {optimized} > 0" in body
        assert f"{optimized}) > CONVERT(DECIMAL(38,4), {baseline}) * 1.10" in body
        assert f"{baseline} > 0 AND CONVERT(DECIMAL(38,4), {optimized}) <= CONVERT(DECIMAL(38,4), {baseline}) * 0.90" in body
    outcome_case = body[body.index("CONVERT(VARCHAR(24), CASE"):]
    assert "MEDIANGRANTUTILIZATIONPERCENT BETWEEN" not in outcome_case
    assert "MEDIANGRANTUTILIZATIONPERCENT - OPTIMIZEDMEDIANGRANTUTILIZATIONPERCENT >=" not in outcome_case
    assert body.count("THROW") >= 3
    assert "FROZENSETTINGSHASH" in body and "RUNSTATUS = 'COMPLETED'" in body
    assert "NO MEMORY SAMPLES" in body
    assert re.search(r"WHEN CORRECTNESSPASSED = 0 THEN N'FAILED'", outcome_case)
    assert re.search(r"WHEN HASMATERIALREGRESSION = 1 THEN N'NOMATERIALIMPROVEMENT'", outcome_case)
    assert re.search(r"WHEN HASADDITIONALMETRICIMPROVEMENT = 0 THEN N'NOMATERIALIMPROVEMENT'", outcome_case)


def test_summary_views_and_reader_permissions_are_least_privileged_and_verified() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    views = re.findall(r"CREATE OR ALTER VIEW (LAB\.VW_\w+)", text)
    assert set(views) == {"LAB.VW_WORKSHOPRUNSUMMARY", "LAB.VW_WORKSHOPSAMPLESUMMARY"}
    assert "FROZENSETTINGSJSON" not in " ".join(
        re.sub(r"\s+", " ", batch).upper()
        for batch in batches("05-CreateDiagnostics.sql")
        if re.match(r"CREATE\s+OR\s+ALTER\s+VIEW", batch, re.IGNORECASE)
    )
    assert "SUSER_ID(N'MCP_WORKSHOP_READER') IS NULL" in text
    assert "SESSION_CONTEXT(N'MCPREADERPASSWORD')" in text
    assert "CREATE LOGIN" in text
    assert "CHECK_POLICY = ON" in text
    assert "CHECK_EXPIRATION = OFF" in text
    assert "DEFAULT_DATABASE = [ADVENTUREWORKS2022]" in text
    assert "QUOTENAME(@READERLOGINNAME)" in text
    assert "REPLACE(@MCPREADERPASSWORD" in text
    assert "CREATE USER [MCP_WORKSHOP_READER] FOR LOGIN [MCP_WORKSHOP_READER]" in text
    assert not re.search(r"(?i)WITH\s+PASSWORD\s*=\s*N?'[^']+?'", sql("05-CreateDiagnostics.sql"))
    assert "GRANT CONNECT TO [MCP_WORKSHOP_READER]" in text
    for procedure in DIAGNOSTIC_PROCEDURES:
        assert f"GRANT EXECUTE ON OBJECT::{procedure.upper()} TO [MCP_WORKSHOP_READER]" in text
    for view in views:
        assert f"GRANT SELECT ON OBJECT::{view} TO [MCP_WORKSHOP_READER]" in text
    for table in ("WORKSHOPRUN", "WORKSHOPSAMPLE", "WORKSHOPREQUESTSAMPLE", "VALIDATIONRUN"):
        for permission in ("INSERT", "UPDATE", "DELETE", "ALTER", "CONTROL"):
            assert f"DENY {permission} ON OBJECT::LAB.{table} TO [MCP_WORKSHOP_READER]" in text
    for permission in ("INSERT", "UPDATE", "DELETE", "ALTER", "CONTROL"):
        assert f"DENY {permission} ON SCHEMA::LAB TO [MCP_WORKSHOP_READER]" not in text
    assert "DENY CONTROL ON DATABASE::[ADVENTUREWORKS2022] TO [MCP_WORKSHOP_READER]" not in text
    assert "DENY CONTROL ON SCHEMA::LAB TO [MCP_WORKSHOP_READER]" not in text
    assert "EXECUTE AS USER = N'MCP_WORKSHOP_READER'" in text
    assert "DATABASE_PRINCIPALS" in text and "SUSER_SID" in text
    assert "SERVER ROLE" in text and "DATABASE ROLE" in text
    assert "HAS_PERMS_BY_NAME" in text and "REVERT" in text
    assert "BEGIN TRY" in text and "BEGIN CATCH" in text
    assert "@EXPECTEDREADERPERMISSIONS" in text
    assert "SYS.DATABASE_PERMISSIONS" in text
    assert "GRANT_WITH_GRANT_OPTION" in text
    assert "SYS.DATABASE_ROLE_MEMBERS" in text
    assert "SYS.SERVER_ROLE_MEMBERS" in text
    assert "SYS.FN_MY_PERMISSIONS" in text
    assert "USER_ID(N'PUBLIC')" in text
    assert "@EFFECTIVEREADERPERMISSIONS" in text
    assert "FROM MASTER.SYS.SERVER_PERMISSIONS" in text
    assert "STATE IN (N'G', N'W')" in text
    assert "PERMISSION_NAME IN (N'VIEW SERVER STATE'" not in text
    for permission in ("TAKE OWNERSHIP", "VIEW DEFINITION", "IMPERSONATE ANY USER"):
        assert f"DENY {permission}" in text
    permission_verification = text[text.index("DECLARE @PERMISSIONFAILURE"):]
    for table in ("WORKSHOPRUN", "WORKSHOPSAMPLE", "WORKSHOPREQUESTSAMPLE", "VALIDATIONRUN"):
        for permission in ("INSERT", "UPDATE", "DELETE"):
            assert f"N'LAB.{table}', N'OBJECT', N'{permission}'" in permission_verification
    for procedure in DIAGNOSTIC_PROCEDURES:
        assert f"N'{procedure.upper()}', N'OBJECT', N'EXECUTE'" in permission_verification
    for view in views:
        assert f"N'{view}', N'OBJECT', N'SELECT'" in permission_verification
    for table in ("WORKSHOPRUN", "WORKSHOPSAMPLE", "WORKSHOPREQUESTSAMPLE", "VALIDATIONRUN"):
        for permission in ("ALTER", "CONTROL"):
            assert f"N'LAB.{table}', N'OBJECT', N'{permission}'" in permission_verification
    assert "N'DBO', N'USER', N'IMPERSONATE'" in permission_verification
    assert permission_verification.index("BEGIN TRY") < permission_verification.index("REVERT")
    assert permission_verification.index("REVERT") < permission_verification.index("BEGIN CATCH")
    for forbidden in ("SP_ADDROLEMEMBER", "SP_ADDSRVROLEMEMBER", "ALTER SERVER ROLE", "ADD MEMBER", "TRUSTWORTHY ON"):
        assert forbidden not in text


def test_reader_login_secret_is_validated_cleared_and_never_embedded_in_source() -> None:
    raw = sql("05-CreateDiagnostics.sql")
    text = normalized("05-CreateDiagnostics.sql")
    assert "DECLARE @MCPREADERPASSWORD NVARCHAR(4000)" in text
    assert "LEN(@MCPREADERPASSWORD) NOT BETWEEN 20 AND 128" in text
    assert "DATALENGTH(@MCPREADERPASSWORD) / 2 NOT BETWEEN 20 AND 128" in text
    assert "COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[A-Z]%'" in raw
    assert "COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[a-z]%'" in raw
    assert "COLLATE LATIN1_GENERAL_100_BIN2 NOT LIKE N'%[0-9]%'" in text
    assert "MCP_WORKSHOP_READER" in text and "CHARINDEX" in text
    assert "@KEY = N'MCPREADERPASSWORD', @VALUE = NULL" in text
    assert "TYPE_DESC = N'SQL_LOGIN'" in text
    assert "IS_DISABLED = 0" in text
    assert "DEFAULT_DATABASE_NAME = N'ADVENTUREWORKS2022'" in text
    assert "IS_POLICY_CHECKED = 1" in text
    assert "IS_EXPIRATION_CHECKED = 0" in text
    assert "IS_SRVROLEMEMBER(N'SYSADMIN', N'MCP_WORKSHOP_READER')" in text
    assert not re.search(r"(?i)PASSWORD\s*=\s*N?'[^']+'", raw)


def test_reader_secret_is_captured_and_cleared_before_identity_mutation() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    capture = text.index("DECLARE @MCPREADERPASSWORD NVARCHAR(4000)")
    clear = text.index(
        "EXEC SYS.SP_SET_SESSION_CONTEXT @KEY = N'MCPREADERPASSWORD', @VALUE = NULL",
        capture,
    )
    identity_mutations = tuple(
        match.start()
        for pattern in (
            r"\bCREATE\s+CERTIFICATE\b",
            r"\bCREATE\s+LOGIN\b",
            r"\bCREATE\s+USER\b",
            r"\bADD\s+SIGNATURE\b",
            r"\bGRANT\s+(?:CONNECT|EXECUTE|SELECT|VIEW)\b",
            r"\bREVOKE\s+VIEW\b",
            r"\bDENY\s+(?:INSERT|UPDATE|DELETE|ALTER|CONTROL|TAKE|VIEW|IMPERSONATE)\b",
        )
        for match in re.finditer(pattern, text)
    )
    first_identity_mutation = min(identity_mutations)

    assert capture < clear < first_identity_mutation
    assert "SUSER_ID" not in text[capture:clear]
    assert clear < text.index("IF SUSER_ID(N'MCP_WORKSHOP_READER') IS NULL")


def test_reader_secret_clear_is_verified_and_fails_closed_without_swallowing_errors() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    lifecycle = text[
        text.index("DECLARE @MCPREADERPASSWORD NVARCHAR(4000)"):
        text.index("DECLARE @DATABASECERTIFICATETHUMBPRINT VARBINARY(32)")
    ]

    assert re.search(
        r"BEGIN TRY EXEC SYS\.SP_SET_SESSION_CONTEXT "
        r"@KEY = N'MCPREADERPASSWORD', @VALUE = NULL; END TRY "
        r"BEGIN CATCH SET @MCPREADERPASSWORD = NULL; THROW \d+, N?'[^']+', 1; END CATCH",
        lifecycle,
    )
    assert re.search(
        r"IF SESSION_CONTEXT\(N'MCPREADERPASSWORD'\) IS NOT NULL "
        r"BEGIN SET @MCPREADERPASSWORD = NULL; THROW \d+, N?'[^']+', 1; END",
        lifecycle,
    )
    assert not re.search(r"BEGIN CATCH\s+END CATCH", lifecycle)


def test_reader_login_creation_zeroes_secret_and_dynamic_sql_on_success_and_failure() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    creation_start = text.index("DECLARE @CREATEREADERLOGINSQL NVARCHAR(MAX)")
    login_creation = text[
        creation_start:
        text.index("IF NOT EXISTS ( SELECT 1 FROM MASTER.SYS.SERVER_PRINCIPALS", creation_start)
    ]
    cleanup = (
        r"SET @MCPREADERPASSWORD = NULL; "
        r"SET @ESCAPEDMCPREADERPASSWORD = NULL; "
        r"SET @CREATEREADERLOGINSQL = NULL;"
    )

    assert re.search(
        r"BEGIN TRY BEGIN TRANSACTION; "
        r"EXEC MASTER\.SYS\.SP_EXECUTESQL @CREATEREADERLOGINSQL; .*?"
        r"INSERT WORKSHOPADMIN\.DBO\.IDENTITYOWNERSHIP .*?"
        r"COMMIT TRANSACTION; "
        + cleanup
        + r" END TRY BEGIN CATCH IF XACT_STATE\(\) <> 0 ROLLBACK TRANSACTION; "
        + cleanup
        + r" THROW; END CATCH",
        login_creation,
    )
    for statement in re.findall(r"\b(?:PRINT|THROW)\b[^;]*;", text):
        assert "@MCPREADERPASSWORD" not in statement
        assert "@ESCAPEDMCPREADERPASSWORD" not in statement
        assert "@CREATEREADERLOGINSQL" not in statement


def test_existing_reader_login_is_rejected_unless_exactly_workshop_owned_before_access_mutation() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    login_lifecycle = text[text.index("DECLARE @READERLOGINNAME SYSNAME"):]
    ownership_guard = re.search(
        r"IF SUSER_ID\(@READERLOGINNAME\) IS NOT NULL AND NOT EXISTS\s*\(.*?"
        r"WORKSHOPADMIN\.DBO\.IDENTITYOWNERSHIP.*?"
        r"MARKERID = @WORKSHOPMARKER.*?SCHEMAVERSION = @WORKSHOPSCHEMAVERSION.*?"
        r"PRINCIPALTYPE = 'SQL_LOGIN'.*?PRINCIPALNAME = @READERLOGINNAME.*?"
        r"PRINCIPALSID = SUSER_SID\(@READERLOGINNAME\).*?CREATEDBYWORKSHOP = 1.*?"
        r"\)\s*THROW",
        login_lifecycle,
    )
    assert ownership_guard, "a pre-existing reader login must fail closed without exact ownership"
    guard_position = ownership_guard.start()
    assert guard_position < login_lifecycle.index("CREATE USER [MCP_WORKSHOP_READER]")
    assert guard_position < login_lifecycle.index("GRANT CONNECT TO [MCP_WORKSHOP_READER]")


def test_existing_reader_login_ownership_is_bound_to_its_exact_sql_login_sid() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    lifecycle = text[text.index("DECLARE @READERLOGINNAME SYSNAME"):]
    ownership_guard = lifecycle[:lifecycle.index("THROW 51669")]
    for predicate in (
        "MASTER.SYS.SQL_LOGINS",
        "PRINCIPAL.NAME = @READERLOGINNAME",
        "PRINCIPAL.TYPE_DESC = N'SQL_LOGIN'",
        "OWNERSHIP.PRINCIPALSID = PRINCIPAL.SID",
        "OWNERSHIP.CREATEDBYWORKSHOP = 1",
    ):
        assert predicate in ownership_guard
    assert "READER LOGIN OWNERSHIP" in lifecycle


def test_exact_owned_reader_login_password_is_rotated_with_required_login_options() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    lifecycle = text[text.index("DECLARE @READERLOGINNAME SYSNAME"):]
    assert re.search(
        r"IF SUSER_ID\(@READERLOGINNAME\) IS NOT NULL.*?"
        r"ALTER LOGIN.*?WITH PASS' \+ N'WORD = N'''.*?CHECK_POLICY = ON.*?"
        r"CHECK_EXPIRATION = OFF.*?DEFAULT_DATABASE = \[ADVENTUREWORKS2022\]",
        lifecycle,
    )
    assert "SESSION_CONTEXT(N'MCPREADERPASSWORD')" in lifecycle


def test_reader_rotation_clears_every_secret_variable_before_later_identity_or_grant_mutation() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    lifecycle = text[text.index("DECLARE @MCPREADERPASSWORD NVARCHAR(4000)"):]
    rotation = lifecycle.index("ALTER LOGIN")
    later_identity_mutation = min(
        lifecycle.index("CREATE USER [MCP_WORKSHOP_READER]", rotation),
        lifecycle.index("GRANT CONNECT TO [MCP_WORKSHOP_READER]", rotation),
    )
    cleared_region = lifecycle[rotation:later_identity_mutation]
    for secret in (
        "@MCPREADERPASSWORD",
        "@ESCAPEDMCPREADERPASSWORDFORROTATION",
        "@READERLOGINPASSWORDSQL",
    ):
        assert cleared_region.count(f"SET {secret} = NULL") >= 2


def test_existing_reader_database_user_requires_exact_ownership_before_grants() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    user_lifecycle = text[text.index("IF USER_ID(N'MCP_WORKSHOP_READER') IS NULL"):]
    ownership_guard = re.search(
        r"IF USER_ID\(N'MCP_WORKSHOP_READER'\) IS NOT NULL AND NOT EXISTS\s*\(.*?"
        r"WORKSHOPADMIN\.DBO\.IDENTITYOWNERSHIP.*?"
        r"PRINCIPALTYPE = 'DATABASE_USER'.*?PRINCIPALNAME = N'MCP_WORKSHOP_READER'.*?"
        r"PRINCIPALSID = SUSER_SID\(@READERLOGINNAME\).*?CREATEDBYWORKSHOP = 1.*?"
        r"\)\s*THROW",
        user_lifecycle,
    )
    assert ownership_guard
    assert ownership_guard.start() < user_lifecycle.index("GRANT CONNECT TO [MCP_WORKSHOP_READER]")


def test_new_reader_login_and_exact_ownership_record_are_one_transaction() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    creation = text[
        text.index("IF SUSER_ID(N'MCP_WORKSHOP_READER') IS NULL"):
        text.index("GRANT VIEW SERVER PERFORMANCE STATE")
    ]
    assert re.search(
        r"CREATE LOGIN.*?BEGIN TRANSACTION.*?"
        r"EXEC MASTER\.SYS\.SP_EXECUTESQL @CREATEREADERLOGINSQL.*?"
        r"INSERT WORKSHOPADMIN\.DBO\.IDENTITYOWNERSHIP.*?"
        r"PRINCIPALSID.*?SUSER_SID\(@READERLOGINNAME\).*?COMMIT TRANSACTION",
        creation,
    )


def test_cleanup_refuses_reader_identity_without_exact_ownership_and_only_then_drops() -> None:
    text = normalized("09-Cleanup.sql")
    lifecycle = text[text.index("DECLARE @READERSID VARBINARY(85)"):text.index("DECLARE @DATABASECERTIFICATETHUMBPRINT")]
    for principal_type, drop_statement in (
        ("DATABASE_USER", "DROP USER [MCP_WORKSHOP_READER]"),
        ("SQL_LOGIN", "DROP LOGIN [MCP_WORKSHOP_READER]"),
    ):
        ownership = re.search(
            rf"NOT EXISTS\s*\(.*?WORKSHOPADMIN\.DBO\.IDENTITYOWNERSHIP.*?"
            rf"PRINCIPALTYPE = '{principal_type}'.*?PRINCIPALSID = @READERSID.*?"
            rf"CREATEDBYWORKSHOP = 1.*?\).*?THROW",
            lifecycle,
        )
        assert ownership, f"cleanup must fail closed for an unowned {principal_type}"
        assert ownership.start() < lifecycle.index(drop_statement)


def test_all_sql_is_bounded_and_avoids_destructive_or_public_network_commands() -> None:
    combined = "\n".join(normalized(path.name) for path in SQL_DIR.glob("*.sql"))
    forbidden = (
        r"\bDBCC\s+DROPCLEANBUFFERS\b",
        r"\bDBCC\s+FREEPROCCACHE\b",
        r"\bWHILE\s+1\s*=\s*1\b",
        r"\bDROP\s+(?:DATABASE|ENDPOINT)\b",
        r"\bSHUTDOWN\b",
        r"\bXP_CMDSHELL\b",
        r"\bSP_CONFIGURE\s+N?'REMOTE\s+ACCESS'",
        r"\b(?:CREATE|ALTER)\s+ENDPOINT\b",
        r"\bOPENROWSET\b",
        r"\bOPENDATASOURCE\b",
    )
    assert not any(re.search(pattern, combined) for pattern in forbidden)


@pytest.mark.parametrize(
    "name",
    [
        "00-Preflight.sql",
        "01-ConfigureInstance.sql",
        "02-RestoreAndConfigureDatabase.sql",
        "03-CreateScaledLabData.sql",
    ],
)
def test_scripts_use_explicit_throw_numbers_and_no_raiserror(name: str) -> None:
    text = normalized(name)
    assert "RAISERROR" not in text
    throw_numbers = [int(value) for value in re.findall(r"\bTHROW\s+(\d{5}),", text)]
    assert throw_numbers
    assert all(50000 <= value <= 59999 for value in throw_numbers)


def test_optional_hint_requires_exact_secure_lab_contract_before_mutation() -> None:
    raw = sql("08-OptionalQueryStoreHint.sql")
    text = normalized("08-OptionalQueryStoreHint.sql")
    assert ":on error exit" in raw.lower()
    assert not re.search(r"\$\(\w+\)", raw)
    assert re.search(r"IF\s+@@TRANCOUNT\s*<>\s*0.*?THROW", text)
    for contract in (
        "SESSION_CONTEXT(N'EXPECTEDSERVERNAME')",
        "SESSION_CONTEXT(N'DATABASENAME')",
        "SESSION_CONTEXT(N'ALLOWOPTIONALHINTEXERCISE')",
        "N'ADVENTUREWORKS2022'",
        "SERVERPROPERTY('PRODUCTMAJORVERSION')",
        "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C",
        "N'MCP SQL QUERY STORE WORKSHOP'",
        "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B",
        "ACTUAL_STATE_DESC = N'READ_WRITE'",
    ):
        assert contract in text
    first_mutation = min(text.index("SP_QUERY_STORE_SET_HINTS"), text.index("INSERT INTO WORKSHOPADMIN.DBO.QUERYSTOREHINTOWNERSHIP"))
    assert text.index("ALLOWOPTIONALHINTEXERCISE") < first_mutation
    assert re.search(r"ISNULL\(@ALLOWOPTIONALHINTEXERCISE,\s*0\)\s*<>\s*1.*?RETURN", text)
    assert "@ALLOWOPTIONALHINTEXERCISEVALUE" in text
    assert "SQL_VARIANT_PROPERTY(@ALLOWOPTIONALHINTEXERCISEVALUE, 'BASETYPE') <> N'BIT'" in text
    assert re.search(r"TRY_CONVERT\(INT,\s*@ALLOWOPTIONALHINTEXERCISEVALUE\).*?NOT IN \(0, 1\).*?THROW", text)


def test_optional_hint_discovers_exact_baseline_query_without_fixed_id() -> None:
    text = normalized("08-OptionalQueryStoreHint.sql")
    assert "SYS.QUERY_STORE_QUERY AS Q" in text
    assert "SYS.QUERY_STORE_QUERY_TEXT AS QT" in text
    assert "Q.OBJECT_ID = OBJECT_ID(N'LAB.USP_MONTHENDSALESBASELINE', N'P')" in text
    assert "Q.QUERY_CONTEXT_SETTINGS_ID" in text
    assert "SESSION_CONTEXT(N'OPTIONALHINTQUERYCONTEXTSETTINGSID')" in text
    assert "Q.QUERY_HASH" in text
    assert "HASHBYTES('SHA2_256'" in text
    assert "INSERT @WIDEWORK" in text and "FROM LAB.FACTSALES AS FS" in text
    assert "SP_QUERY_STORE_SET_HINTS" not in text[:text.index("SYS.QUERY_STORE_QUERY AS Q")]
    assert re.search(r"@MATCHCOUNT\s*<>\s*1.*?THROW", text)
    assert not re.search(r"DECLARE\s+@QUERYID\s+BIGINT\s*=\s*\d+", text)
    assert "EXCLUDE OWN DIAGNOSTIC TEXT" in text


def test_optional_hint_owns_inspects_tests_clears_and_verifies_lifecycle() -> None:
    text = normalized("08-OptionalQueryStoreHint.sql")
    hint = "OPTION (MAX_GRANT_PERCENT = 10)"
    assert hint in text
    assert "WORKSHOPADMIN.DBO.QUERYSTOREHINTOWNERSHIP" in text
    assert "SYS.QUERY_STORE_QUERY_HINTS" in text
    assert "QUERY_HINT_TEXT" in text
    assert "LAST_QUERY_HINT_FAILURE_REASON" in text
    assert "LAST_QUERY_HINT_FAILURE_REASON_DESC" in text
    assert "QUERY_HINT_FAILURE_COUNT" in text
    assert "SOURCE_DESC" in text
    assert "FOREIGN OR MANUAL QUERY STORE HINT" in text
    assert "LAB.USP_MONTHENDSALESOPTIMIZED" not in text
    assert "EXEC LAB.USP_MONTHENDSALESBASELINE" in text
    assert "DECLARE @TESTSTARTDATE DATE = CONVERT(DATE, '2014-01-01')" in text
    assert "DECLARE @TESTENDDATEEXCLUSIVE DATE = CONVERT(DATE, '2014-01-08')" in text
    assert "@STARTDATE = @TESTSTARTDATE" in text
    assert "@ENDDATEEXCLUSIVE = @TESTENDDATEEXCLUSIVE" in text
    assert text.count("SYS.SP_QUERY_STORE_CLEAR_HINTS") >= 2
    assert "@CREATEDBYTHISINVOCATION" in text
    assert "@OWNEDHINTFORTHISINVOCATION" in text
    assert "MCP_SQL_WORKSHOP_LIFECYCLE" in text
    assert "@BEFORESTATISTICS" in text and "@AFTERSTATISTICS" in text
    assert "SYS.QUERY_STORE_RUNTIME_STATS" in text
    assert "EXERCISEEXECUTIONCOUNT" in text and "EXERCISEDURATIONMICROSECONDS" in text
    assert "OWNERSHIPSTATE = 'CLEARED'" in text
    assert re.search(r"OWNERSHIPSTATE = 'CLEARED'.*?SET OWNERSHIPSTATE = 'PENDING'", text)
    clear_calls = [match.start() for match in re.finditer(r"SYS\.SP_QUERY_STORE_CLEAR_HINTS", text)]
    for call in clear_calls:
        preceding = text[max(0, call - 1800):call]
        assert "SYS.QUERY_STORE_QUERY_HINTS" in preceding
        assert "OPTION(MAX_GRANT_PERCENT=10)" in preceding
        assert "QUERYSTOREHINTOWNERSHIP" in preceding
    assert re.search(r"IF EXISTS\s*\(.*?SYS\.QUERY_STORE_QUERY_HINTS.*?THROW", text)
    catch = text[text.index("BEGIN CATCH"):]
    assert "ERROR_NUMBER()" in catch
    assert "CLEAR ATTEMPT" in catch
    assert re.search(r"THROW\s*;", catch)


def test_cleanup_requires_exact_context_marker_server_database_and_lock() -> None:
    raw = sql("09-Cleanup.sql")
    text = normalized("09-Cleanup.sql")
    assert ":on error exit" in raw.lower()
    assert not re.search(r"\$\(\w+\)", raw)
    assert re.search(r"IF\s+@@TRANCOUNT\s*<>\s*0.*?THROW", text)
    for contract in (
        "SESSION_CONTEXT(N'EXPECTEDSERVERNAME')",
        "SESSION_CONTEXT(N'DATABASENAME')",
        "SESSION_CONTEXT(N'DROPLABDATA')",
        "N'ADVENTUREWORKS2022'",
        "SERVERPROPERTY('PRODUCTMAJORVERSION')",
        "68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C",
        "N'MCP SQL QUERY STORE WORKSHOP'",
        "0XADA06F206D3DB321527A5AAB390FC814E28EBB59791967EB99841BF669E1B16B",
        "SYS.SP_GETAPPLOCK",
        "SYS.SP_RELEASEAPPLOCK",
        "MCP_SQL_WORKSHOP_LIFECYCLE",
    ):
        assert contract in text
    assert re.search(r"@DROPLABDATA\s+BIT\s*=\s*COALESCE\(.*?,\s*0\)", text)
    assert re.search(r"TRY_CONVERT\(INT,\s*@DROPLABDATAVALUE\).*?NOT IN \(0, 1\).*?THROW", text)
    assert "SQL_VARIANT_PROPERTY(@DROPLABDATAVALUE, 'BASETYPE') <> N'BIT'" in text
    assert "@QUERYSTOREISREADWRITE" in text
    assert re.search(r"@OWNEDACTIVEHINTCOUNT\s*>\s*0.*?@QUERYSTOREISREADWRITE\s*<>\s*1.*?THROW", text)
    lock = text.index("SYS.SP_GETAPPLOCK")
    assert lock < text.index("CREATE TABLE DBO.CLEANUPAUDIT")
    assert lock < text.index("INSERT WORKSHOPADMIN.DBO.CLEANUPAUDIT")


def test_cleanup_session_termination_is_double_tagged_snapshotted_and_bounded() -> None:
    text = normalized("09-Cleanup.sql")
    assert "SESSION_CONTEXT(N'CLEANUPRUNID')" in text
    assert "@CLEANUPRUNID UNIQUEIDENTIFIER" in text
    assert "SYS.DM_EXEC_SESSIONS" in text
    assert "SYS.DM_EXEC_REQUESTS" in text
    assert "CONTEXT_INFO" in text
    assert "TRY_CONVERT(UNIQUEIDENTIFIER, CONVERT(BINARY(16), SUBSTRING(" in text
    for phase in ("BASELINE", "OPTIMIZED", "COMPARISON"):
        assert re.search(rf"N'-{phase}-[1-4]'", text)
    assert "LATIN1_GENERAL_100_BIN2" in text
    assert re.search(r"@KILLCOUNT\s*>\s*100.*?THROW", text)
    assert "SESSION_ID <> @@SPID" in text
    assert "PRIMARY KEY" in text
    assert re.search(r"WHILE\s+@KILLORDINAL\s*<=\s+@KILLCOUNT", text)
    assert "WHILE 1 = 1" not in text
    assert "KILL " in text
    assert "CURRENTMARKER.RUNID = @KILLRUNID" in text
    assert "CURRENTSESSION.PROGRAM_NAME COLLATE LATIN1_GENERAL_100_BIN2" in text
    assert text.index("CURRENTMARKER.RUNID = @KILLRUNID") < text.index("DECLARE @KILLSQL")
    assert "QUOTENAME" not in text[text.index("DECLARE @KILLSQL"):text.index("EXEC SYS.SP_EXECUTESQL @KILLSQL")]


def test_cleanup_session_termination_has_no_wildcard_only_identity_acceptance() -> None:
    text = normalized("09-Cleanup.sql")
    termination = text[text.index("DECLARE @SESSIONSTOKILL"):text.index("DECLARE @OWNEDHINTS")]
    assert "PROGRAM_NAME LIKE N'MCP-SQL-WORKSHOP-%'" not in termination
    assert re.search(r"PROGRAM_NAME\s+COLLATE\s+LATIN1_GENERAL_100_BIN2\s*=\s*N'MCP-SQL-WORKSHOP-'", termination)
    assert termination.count("SUBSTRING(") >= 2
    assert termination.count("SYS.DM_EXEC_REQUESTS") >= 2


def test_cleanup_clears_only_owned_hints_and_restores_configuration() -> None:
    text = normalized("09-Cleanup.sql")
    assert "WORKSHOPADMIN.DBO.QUERYSTOREHINTOWNERSHIP" in text
    assert "SYS.SP_QUERY_STORE_CLEAR_HINTS" in text
    assert "SYS.QUERY_STORE_QUERY_HINTS" in text
    assert "CONFIGURATIONBACKUP" in text and "DATABASECONFIGURATIONBACKUP" in text
    for setting in (
        "ROW_MODE_MEMORY_GRANT_FEEDBACK",
        "BATCH_MODE_MEMORY_GRANT_FEEDBACK",
        "MEMORY_GRANT_FEEDBACK_PERCENTILE_GRANT",
        "MEMORY_GRANT_FEEDBACK_PERSISTENCE",
        "QUERY_STORE",
        "MAX SERVER MEMORY (MB)",
        "MIN SERVER MEMORY (MB)",
        "CLASSIFIER_FUNCTION",
        "RESOURCE GOVERNOR RECONFIGURE",
    ):
        assert setting in text
    memory = text[text.index("DECLARE @RESTOREMEMORYSQL"):]
    assert memory.index("MIN SERVER MEMORY (MB)', 0") < memory.index("MAX SERVER MEMORY (MB)', @BACKUPMAXSERVERMEMORYMB")
    assert memory.index("MAX SERVER MEMORY (MB)', @BACKUPMAXSERVERMEMORYMB") < memory.index("MIN SERVER MEMORY (MB)', @BACKUPMINSERVERMEMORYMB")
    hint_loop = text[text.index("WHILE @HINTORDINAL <= @HINTCOUNT"):text.index("IF EXISTS", text.index("WHILE @HINTORDINAL <= @HINTCOUNT") + 20)]
    assert "SYS.QUERY_STORE_QUERY_HINTS" in hint_loop
    assert "QUERYSTOREHINTOWNERSHIP" in hint_loop
    assert "OPTION(MAX_GRANT_PERCENT=10)" in hint_loop
    for fingerprint in ("QUERYCONTEXTSETTINGSID", "QUERYHASH", "QUERYTEXTHASH"):
        assert fingerprint in hint_loop
    assert "MAX_STORAGE_SIZE_MB" in text
    assert "QUERY_CAPTURE_MODE" in text
    assert text.index("MAX_STORAGE_SIZE_MB") < text.index("OPERATION_MODE = READ_ONLY")
    assert "FOR SECONDARY SET ROW_MODE_MEMORY_GRANT_FEEDBACK = PRIMARY" in text
    assert "FOR SECONDARY SET BATCH_MODE_MEMORY_GRANT_FEEDBACK = PRIMARY" in text
    for option in (
        "STALE_QUERY_THRESHOLD_DAYS", "DATA_FLUSH_INTERVAL_SECONDS", "INTERVAL_LENGTH_MINUTES",
        "SIZE_BASED_CLEANUP_MODE", "WAIT_STATS_CAPTURE_MODE",
    ):
        assert option in text


def test_restore_captures_complete_pre_workshop_query_store_state_before_configuration() -> None:
    text = normalized("02-RestoreAndConfigureDatabase.sql")
    capture = text.index("INSERT INTO WORKSHOPADMIN.DBO.DATABASECONFIGURATIONBACKUP")
    configure = text.index("EXEC SYS.SP_EXECUTESQL @CONFIGURESQL")
    assert capture < configure
    for column in (
        "QUERYSTORESTALEQUERYTHRESHOLDDAYS", "QUERYSTOREFLUSHINTERVALSECONDS",
        "QUERYSTOREINTERVALLENGTHMINUTES", "QUERYSTORESIZEBASEDCLEANUPMODEDESC",
        "QUERYSTOREWAITSTATSCAPTUREMODEDESC",
    ):
        assert column in text
    assert "INCOMPLETE LEGACY DATABASE CONFIGURATION BACKUP CANNOT BE SAFELY BACKFILLED" in text
    assert "UPDATE WORKSHOPADMIN.DBO.DATABASECONFIGURATIONBACKUP" not in text
    assert "COMPATIBILITYLEVEL" in text


def test_cleanup_restores_original_database_compatibility_level() -> None:
    text = normalized("09-Cleanup.sql")
    assert "@BACKUPCOMPATIBILITYLEVEL" in text
    assert "SET COMPATIBILITY_LEVEL = " in text
    assert "SYS.DATABASES" in text


def test_cleanup_removes_only_exact_owned_resource_governor_objects() -> None:
    text = normalized("09-Cleanup.sql")
    assert "RESOURCEGOVERNOROBJECTOWNERSHIP" in text
    assert "DEFINITIONHASH" in text
    assert "MASTER.SYS.SQL_MODULES" in text and "HASHBYTES('SHA2_256'" in text
    assert "REQUEST_MAX_MEMORY_GRANT_PERCENT = 40" in text
    assert "MIN_MEMORY_PERCENT = 0" in text and "MAX_MEMORY_PERCENT = 50" in text
    assert "DROP WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]" in text
    assert "DROP RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "DROP FUNCTION DBO.MCP_SQL_WORKSHOP_CLASSIFIER" in text
    assert text.index("DROP WORKLOAD GROUP [MCP_SQL_WORKSHOP_GROUP]") < text.index("DROP RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]")
    assert "RESTORE THE PRIOR CLASSIFIER" in text
    assert "FOREIGN" in text and "REFUSING TO DROP" in text
    classifier_region = text[text.index("DECLARE @EXPECTEDCLASSIFIERCREATESQL"):text.index("RELATIONSHIP-SAFE MEMORY RESTORATION") if "RELATIONSHIP-SAFE MEMORY RESTORATION" in text else text.index("DECLARE @RESTOREMEMORYSQL")]
    assert "USE [MASTER]" in classifier_region
    assert "MASTER.SYS.OBJECTS" in classifier_region
    assert "MASTER.SYS.SQL_MODULES" in classifier_region
    assert "@CURRENTCLASSIFIERID" in classifier_region
    assert re.search(r"@CURRENTCLASSIFIERID NOT IN \(COALESCE\(@WORKSHOPCLASSIFIERID, -1\), @BACKUPCLASSIFIERFUNCTIONID\).*?THROW", classifier_region)


def test_cleanup_identity_certificate_and_dmk_are_narrow_and_audited() -> None:
    text = normalized("09-Cleanup.sql")
    assert "DROP USER [MCP_WORKSHOP_READER]" in text
    assert "DROP LOGIN [MCP_WORKSHOP_READER]" in text
    assert "SUSER_SID(N'MCP_WORKSHOP_READER')" in text
    assert "DROP LOGIN [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN]" in text
    assert text.count("DROP CERTIFICATE [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE]") >= 2
    assert "MCP WORKSHOP SERVER DMV MODULE SIGNING" in text
    assert "CERTIFICATE EXPORT" in text and "BOOTSTRAP CLEANUP" in text
    assert "CLOSE MASTER KEY" in text
    assert "DROP MASTER KEY" not in text
    assert "XP_CMDSHELL" not in text
    assert "CLEANUPAUDIT" in text and "SYSUTCDATETIME()" in text
    assert "IDENTITYOWNERSHIP" in text
    assert "CREATEDBYWORKSHOP = 1" in text


def test_cleanup_optional_drop_is_marker_owned_dependency_ordered_and_preserves_source() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    assert "LAB.WORKSHOPMARKER" in optional
    assert re.search(r"DROP VIEW(?: IF EXISTS)? LAB\.VW_WORKSHOPSAMPLESUMMARY", optional)
    assert re.search(r"DROP PROCEDURE(?: IF EXISTS)? LAB\.USP_GETMEMORYSNAPSHOT", optional)
    assert re.search(r"DROP TABLE(?: IF EXISTS)? LAB\.WORKSHOPREQUESTSAMPLE", optional)
    assert re.search(r"DROP TABLE(?: IF EXISTS)? LAB\.FACTSALES", optional)
    assert re.search(r"DROP TABLE(?: IF EXISTS)? LAB\.WORKSHOPMARKER", optional)
    assert optional.index("DROP VIEW") < optional.index("DROP PROCEDURE") < optional.index("DROP TABLE IF EXISTS LAB.WORKSHOPREQUESTSAMPLE")
    assert "DROP SCHEMA LAB" in optional
    assert "@EXPECTEDLABOBJECTS" in optional
    assert "LABOBJECTOWNERSHIP" in optional
    assert "DEFINITIONHASH" in optional and "SCHEMAHASH" in optional
    assert "SYS.OBJECTS" in optional and "SYS.SCHEMAS" in optional
    assert "UNEXPECTED OR DRIFTED LAB OBJECT" in optional
    for catalog in (
        "SYS.TRIGGERS", "SYS.INDEXES", "SYS.STATS", "SYS.FOREIGN_KEYS",
        "SYS.DEFAULT_CONSTRAINTS", "SYS.CHECK_CONSTRAINTS", "SYS.KEY_CONSTRAINTS",
        "SYS.DATABASE_PERMISSIONS", "SYS.EXTENDED_PROPERTIES",
        "SYS.COMPUTED_COLUMNS", "SYS.SQL_EXPRESSION_DEPENDENCIES",
        "SYS.FULLTEXT_INDEXES",
    ):
        assert catalog in optional
    for feature in ("TEMPORAL_TYPE", "IS_TRACKED_BY_CDC"):
        assert feature in optional
    assert "IS_SCHEMA_BOUND_REFERENCE" not in optional
    first_drop = optional.index("DROP VIEW")
    for blocker in (
        "UNRECOGNIZED LAB TRIGGER", "UNRECOGNIZED LAB INDEX",
        "UNRECOGNIZED LAB STATISTIC", "UNRECOGNIZED LAB FOREIGN KEY",
        "UNRECOGNIZED LAB PERMISSION", "UNRECOGNIZED LAB DEPENDENCY",
    ):
        assert blocker in optional
        assert optional.index(blocker) < first_drop
    assert "DROP DATABASE" not in text
    for source in ("SALES.SALESORDERHEADER", "SALES.SALESORDERDETAIL", "SALES.SALESTERRITORY"):
        assert f"DROP TABLE {source}" not in text
    assert "DBCC" not in text


def test_cleanup_inventories_every_user_lab_object_type_before_the_first_drop() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    inventory = optional[:optional.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")]

    assert "@EXPECTEDLABOBJECTS" in inventory
    assert "OBJECT_ENTRY.IS_MS_SHIPPED = 0" in inventory
    assert "OBJECT_ENTRY.PARENT_OBJECT_ID = 0" in inventory
    assert "OBJECT_ENTRY.PARENT_OBJECT_ID <> 0" in inventory
    assert "OBJECT_ENTRY.TYPE NOT IN ('PK', 'UQ', 'C', 'D', 'F', 'TR')" in inventory
    assert "OBJECT_ENTRY.TYPE NOT IN ('S', 'IT')" in inventory
    exhaustive_guard = inventory[:inventory.index("DECLARE @OWNEDLABOBJECTIDS")]
    assert "OBJECT_ENTRY.TYPE IN ('U', 'V', 'P')" not in exhaustive_guard
    for catalog in (
        "SYS.SYNONYMS", "SYS.SEQUENCES", "SYS.TYPES", "SYS.XML_SCHEMA_COLLECTIONS",
        "SYS.FULLTEXT_INDEXES", "SYS.SERVICE_QUEUES",
    ):
        assert catalog in inventory
    assert "UNRECOGNIZED LAB SCHEMA-SCOPED OBJECT" in inventory


def test_cleanup_treats_a_foreign_lab_scalar_function_as_an_extra_before_drop() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    allowlist = optional[
        optional.index("INSERT @EXPECTEDLABOBJECTS"):
        optional.index("DECLARE @OWNEDLABOBJECTIDS")
    ]

    assert "'FN'" not in allowlist
    assert "OBJECT_ENTRY.PARENT_OBJECT_ID = 0" in allowlist
    assert "OBJECT_ENTRY.TYPE NOT IN ('S', 'IT')" in allowlist
    assert allowlist.index("UNRECOGNIZED LAB SCHEMA-SCOPED OBJECT") < optional.index(
        "DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY"
    )


def test_cleanup_rejects_lab_synonyms_and_synonyms_targeting_owned_tables_before_drop() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    first_drop = optional.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")
    synonym_guard = optional.index("UNRECOGNIZED LAB SYNONYM")

    assert "SYS.SYNONYMS" in optional
    assert "BASE_OBJECT_NAME" in optional
    assert "PARSENAME" in optional
    assert "@OWNEDLABOBJECTIDS" in optional
    synonym_region = optional[optional.index("FROM SYS.SYNONYMS"):synonym_guard]
    assert "PARSENAME(SYNONYM_ENTRY.BASE_OBJECT_NAME, 4) IS NULL" not in synonym_region
    assert synonym_guard < first_drop


def test_cleanup_dependency_guard_blocks_external_non_schema_bound_modules_in_both_directions() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    dependency_guard = optional[:optional.index("UNRECOGNIZED LAB DEPENDENCY")]
    first_drop = optional.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")

    assert "@OWNEDLABOBJECTIDS" in dependency_guard
    assert "DEPENDENCY.REFERENCED_ID" in dependency_guard
    assert "DEPENDENCY.REFERENCING_ID" in dependency_guard
    assert dependency_guard.count("SELECT OBJECTID FROM @OWNEDLABOBJECTIDS") >= 2
    assert "IS_SCHEMA_BOUND_REFERENCE" not in dependency_guard
    assert optional.index("UNRECOGNIZED LAB DEPENDENCY") < first_drop


def test_cleanup_snapshots_every_eligible_online_database_and_fails_closed_on_inaccessibility() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    cross_database = optional[optional.index("DECLARE @CROSSDATABASESCAN"):]
    initial_guard = cross_database[:cross_database.index("DECLARE @EXPECTEDLABOBJECTS")]
    first_enumeration = cross_database.index("WHILE @CROSSDATABASEORDINAL <= @CROSSDATABASECOUNT")
    first_drop = cross_database.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")

    assert "FROM SYS.DATABASES" in cross_database
    assert "STATE_DESC = N'ONLINE'" in cross_database
    assert "SOURCE_DATABASE_ID IS NULL" in cross_database
    assert "NAME <> N'TEMPDB'" in cross_database
    assert "N'MASTER'" in cross_database and "N'MSDB'" in cross_database
    assert "HAS_DBACCESS(DATABASENAME)" in initial_guard
    assert re.search(r"HAS_DBACCESS\(DATABASENAME\).*?=\s*0.*?THROW", initial_guard)
    assert "AND HAS_DBACCESS(NAME) = 1" not in initial_guard
    assert re.search(r"@CROSSDATABASECOUNT\s*>\s*256.*?THROW", initial_guard)
    assert "@INACCESSIBLEDATABASECOUNT" in initial_guard
    assert "@INACCESSIBLEDATABASELIST" in initial_guard
    assert "QUOTENAME(" in initial_guard
    assert initial_guard.index("HAS_DBACCESS(DATABASENAME)") < first_enumeration < first_drop


def test_cleanup_rechecks_database_access_immediately_before_cross_database_enumeration_and_drop() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    cross_database = optional[optional.index("DECLARE @CROSSDATABASESCAN"):]
    first_check = cross_database.index("DECLARE @INACCESSIBLEDATABASECOUNT")
    recheck = cross_database[cross_database.index("SET @INACCESSIBLEDATABASECOUNT", first_check):]
    first_enumeration = recheck.index("WHILE @CROSSDATABASEORDINAL <= @CROSSDATABASECOUNT")
    last_dependency_guard = recheck.index("UNRECOGNIZED CROSS-DATABASE LAB SYNONYM")
    first_drop = recheck.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")

    assert re.search(r"HAS_DBACCESS\(.*?\).*?<>\s*1.*?THROW", recheck[:first_enumeration])
    assert "DATABASE METADATA VISIBILITY IS INSUFFICIENT" in recheck
    final_access_check = recheck.rindex("HAS_DBACCESS(DATABASENAME)")
    assert last_dependency_guard < final_access_check < first_drop
    assert first_enumeration < first_drop


def test_cleanup_cross_database_dependency_query_is_quoted_parameterized_and_exact() -> None:
    raw = sql("09-Cleanup.sql")
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    cross_database = optional[optional.index("DECLARE @CROSSDATABASESCAN"):]

    assert "QUOTENAME(@CROSSDATABASENAME)" in cross_database
    assert "SYS.SQL_EXPRESSION_DEPENDENCIES" in cross_database
    assert "LOWER(DEPENDENCY.REFERENCED_DATABASE_NAME)" in cross_database
    assert "LOWER(@TARGETDATABASE)" in cross_database
    assert "DEPENDENCY.REFERENCED_ID" in cross_database
    assert "LOWER(DEPENDENCY.REFERENCED_SCHEMA_NAME)" in cross_database
    assert "LOWER(@TARGETSCHEMA)" in cross_database
    assert "DEPENDENCY.REFERENCED_ENTITY_NAME" in cross_database
    assert "#OWNEDLABOBJECTS" in cross_database
    assert "SYS.SP_EXECUTESQL @CROSSDATABASESQL" in cross_database
    assert "@TARGETDATABASE SYSNAME, @TARGETSCHEMA SYSNAME, @SCANNEDDATABASE SYSNAME" in cross_database
    assert "@TARGETDATABASE = @DATABASENAME" in cross_database
    dynamic_sql = re.search(
        r"SET @CROSSDATABASESQL = N'(?P<body>.*?)';\s*BEGIN TRY",
        raw,
        re.IGNORECASE | re.DOTALL,
    )
    assert dynamic_sql
    assert "+ @CrossDatabaseName +" not in dynamic_sql.group("body")


def test_cleanup_cross_database_synonyms_are_normalized_and_fail_closed() -> None:
    text = normalized("09-Cleanup.sql")
    optional = text[text.index("IF @DROPLABDATA = 1"):]
    cross_database = optional[optional.index("DECLARE @CROSSDATABASESCAN"):]

    assert "SYS.SYNONYMS" in cross_database
    assert "SYNONYM_ENTRY.BASE_OBJECT_NAME" in cross_database
    assert "REPLACE(" in cross_database and "N''[''" in cross_database and "N'']''" in cross_database
    assert "PARSENAME(" in cross_database
    assert re.search(r"LIKE\s+N''%''\s*\+\s*LOWER\(@TARGETDATABASE\).*?\+\s*N''%''", cross_database)
    assert "UNRECOGNIZED CROSS-DATABASE LAB SYNONYM" in cross_database
    catch = cross_database[cross_database.index("BEGIN CATCH"):]
    assert "ERROR_MESSAGE()" not in catch
    assert "CANNOT PROVE OPTIONAL LAB DELETION SAFE IN DATABASE " in catch
    assert "@CROSSDATABASENAME" in catch
    assert re.search(r"THROW\s+519\d{2},\s*@CROSSDATABASEERROR", catch)


def test_cleanup_cross_database_guards_are_rechecked_under_lock_immediately_before_drop() -> None:
    raw = sql("09-Cleanup.sql").upper()
    text = normalized("09-Cleanup.sql")
    lock = text.index("SYS.SP_GETAPPLOCK")
    scan = text.index("DECLARE @CROSSDATABASESCAN")
    dependency_block = text.index("UNRECOGNIZED CROSS-DATABASE LAB DEPENDENCY")
    synonym_block = text.index("UNRECOGNIZED CROSS-DATABASE LAB SYNONYM")
    first_drop = text.index("DROP VIEW IF EXISTS LAB.VW_WORKSHOPSAMPLESUMMARY")

    assert lock < scan < dependency_block < synonym_block < first_drop
    assert "DDL RACES" in raw
    assert "APPLICATION LOCK" in raw


def test_diagnostics_records_created_identity_ownership() -> None:
    text = normalized("05-CreateDiagnostics.sql")
    assert "WORKSHOPADMIN.DBO.IDENTITYOWNERSHIP" in text
    assert "@READERLOGINCREATED" in text
    assert "CREATEDBYWORKSHOP" in text


def test_runner_finalizes_exact_lab_object_ownership_after_all_setup_scripts() -> None:
    text = (ROOT / "deploy" / "Invoke-WorkshopSqlScripts.ps1").read_text(encoding="utf-8").upper()
    finalize = text.index("$FINALIZELABOWNERSHIPCOMMAND")
    assert finalize > text.index("FOREACH ($SCRIPTNAME IN $SCRIPTNAMES)")
    for token in ("WORKSHOPADMIN.DBO.LABOBJECTOWNERSHIP", "DEFINITIONHASH", "SCHEMAHASH", "@CURRENTLABOBJECTS"):
        assert token in text[finalize:]


def test_cleanup_global_catch_releases_lock_best_effort_and_bare_rethrows() -> None:
    text = normalized("09-Cleanup.sql")
    catch = text[text.index("BEGIN CATCH", text.index("SYS.SP_GETAPPLOCK")):]
    assert "@RESTORATIONERRORS" in catch
    assert "SYS.SP_RELEASEAPPLOCK" in catch
    assert "BEST-EFFORT RESTORE" in catch
    assert "ERROR_MESSAGE()" not in catch
    assert re.search(r"THROW\s*;\s*END CATCH", catch)


def test_task13_scripts_avoid_unsafe_global_operations_and_raw_substitution() -> None:
    combined = "\n".join(sql(name) for name in ("08-OptionalQueryStoreHint.sql", "09-Cleanup.sql"))
    upper = combined.upper()
    assert not re.search(r"\$\(\w+\)", combined)
    for forbidden in (
        "DROP DATABASE", "DBCC DROPCLEANBUFFERS", "DBCC FREEPROCCACHE", "WHILE 1 = 1",
        "XP_CMDSHELL", "SHUTDOWN", "ALTER ENDPOINT", "CREATE ENDPOINT",
    ):
        assert forbidden not in upper
    cleanup = normalized("09-Cleanup.sql")
    assert cleanup.count("DROP LOGIN [MCP_WORKSHOP_READER]") == 1
    assert cleanup.count("DROP LOGIN [MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN]") == 1
    assert not re.search(r"DROP\s+LOGIN\s+(?!\[MCP_WORKSHOP_READER\]|\[MCP_WORKSHOP_DIAGNOSTICS_CERTIFICATE_LOGIN\])", cleanup)
    for path in SQL_DIR.glob("*.sql"):
        if path.name != "09-Cleanup.sql":
            assert "DROP LOGIN" not in normalized(path.name)
