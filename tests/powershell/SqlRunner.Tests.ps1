Set-StrictMode -Version Latest

BeforeAll {
    $script:RunnerPath = Join-Path $PSScriptRoot '../../deploy/Invoke-WorkshopSqlScripts.ps1'
}

Describe 'Workshop SQL batch parser' {
    BeforeAll {
        . $script:RunnerPath -LoadFunctionsOnly
    }

    It 'splits only standalone GO lines and honors a positive repeat count' {
        $source = @"
SELECT 1;
GO 2 -- repeat
SELECT 2;
GO /* batch boundary */
"@
        @(Split-WorkshopSqlBatch -SqlText $source) | Should -Be @('SELECT 1;', 'SELECT 1;', 'SELECT 2;')
    }

    It 'does not split GO inside strings or block comments' {
        $source = @"
SELECT N'first
GO
last';
/*
GO 4
*/
SELECT 2;
GO
"@
        $batches = @(Split-WorkshopSqlBatch -SqlText $source)
        $batches | Should -HaveCount 1
        $batches[0] | Should -Match "N'first\r?\nGO\r?\nlast'"
        $batches[0] | Should -Match 'GO 4'
    }

    It 'rejects zero or excessive GO counts' -ForEach @('GO 0', 'GO 1001') {
        { Split-WorkshopSqlBatch -SqlText "SELECT 1;`n$_" } | Should -Throw '*GO repeat count*'
    }
}

Describe 'Workshop SQL runner security and ordering' {
    It 'has a strict secure credential surface and no plaintext secret parameters' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:RunnerPath, [ref] $tokens, [ref] $errors
        )
        $errors | Should -HaveCount 0
        foreach ($name in @('SqlConnectionString', 'DatabaseMasterKeyPassword', 'McpReaderPassword')) {
            $parameter = $ast.ParamBlock.Parameters |
                Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter.StaticType.FullName | Should -Be 'System.Security.SecureString'
        }
        $text = Get-Content -LiteralPath $script:RunnerPath -Raw
        $text | Should -Match 'Microsoft\.Data\.SqlClient'
        $text | Should -Match 'Encrypt'
        $text | Should -Match 'TrustServerCertificate'
        $text | Should -Match 'HostNameInCertificate'
        $text | Should -Not -Match '(?i)(Write-(Host|Verbose|Debug|Information)|Out-Host).*password'
    }

    It 'uses one executor connection, parameterized contexts, and prepares secrets immediately before diagnostics' {
        $text = Get-Content -LiteralPath $script:RunnerPath -Raw
        foreach ($key in @(
            'ExpectedServerName', 'DatabaseName', 'PreflightPhase', 'BackupPath', 'DataPath',
            'LogPath', 'DatabaseMasterKeyPassword', 'McpReaderPassword'
        )) {
            $text | Should -Match "Write-WorkshopSessionContext.*$key"
        }
        $text | Should -Match '@read_only\s*=\s*0'
        $text | Should -Match 'sys\.symmetric_keys'
        $text | Should -Match 'DatabaseMasterKeyReady'
        $text.IndexOf("-Key 'DatabaseMasterKeyPassword'") |
            Should -BeLessThan $text.IndexOf("-Key 'DatabaseMasterKeyReady'")
        $text.IndexOf("-Key 'McpReaderPassword'") |
            Should -BeGreaterThan $text.LastIndexOf("if (`$scriptName -eq '05-CreateDiagnostics.sql')")
        $text | Should -Match 'finally'
        $text | Should -Match '\.Dispose\(\)'
    }

    It 'declares the exact deterministic default script order' {
        $text = Get-Content -LiteralPath $script:RunnerPath -Raw
        $positions = 0..7 | ForEach-Object { $text.IndexOf(('0{0}-' -f $_)) }
        $positions | ForEach-Object { $_ | Should -BeGreaterThan -1 }
        for ($index = 1; $index -lt $positions.Count; $index++) {
            $positions[$index] | Should -BeGreaterThan $positions[$index - 1]
        }
    }
}