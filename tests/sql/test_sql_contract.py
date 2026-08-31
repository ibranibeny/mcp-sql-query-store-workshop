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
