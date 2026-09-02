Set-StrictMode -Version Latest

BeforeAll {
    $script:DeployRoot = Join-Path $PSScriptRoot '../../deploy'
    $script:SqlBootstrapPath = Join-Path $script:DeployRoot 'Initialize-SqlVm.ps1'
    $script:AdminBootstrapPath = Join-Path $script:DeployRoot 'Initialize-AdminVm.ps1'
    $script:AdminBootstrapWrapperPath = Join-Path $script:DeployRoot 'Invoke-AdminBootstrap.ps1'
    $script:EvidencePath = Join-Path $script:DeployRoot 'Capture-DeploymentEvidence.ps1'
    $script:ModulePath = Join-Path $script:DeployRoot 'Workshop.Azure.psd1'
    $script:ToolManifestPath = Join-Path $PSScriptRoot '../../.config/dotnet-tools.json'
    $script:McpConfigPath = Join-Path $PSScriptRoot '../../.vscode/mcp.json'
    $script:ConfigPath = Join-Path $script:DeployRoot 'WorkshopConfig.psd1'

    function Get-ScriptContract {
        param([Parameter(Mandatory)][string] $Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref] $tokens, [ref] $errors
        )
        [pscustomobject]@{
            Ast = $ast
            Errors = @($errors)
            Text = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw } else { '' }
        }
    }
}

Describe 'SQL VM bootstrap static contract' {
    BeforeAll { $script:SqlContract = Get-ScriptContract -Path $script:SqlBootstrapPath }

    It 'exists, parses, and accepts only a protected payload file' {
        Test-Path -LiteralPath $script:SqlBootstrapPath | Should -BeTrue
        $script:SqlContract.Errors | Should -HaveCount 0
        $names = @($script:SqlContract.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $names | Should -Contain 'ProtectedPayloadPath'
        $names | Should -Not -Contain 'Password'
        $names | Should -Not -Contain 'McpReaderPassword'
        $names | Should -Not -Contain 'DatabaseMasterKeyPassword'
        $script:SqlContract.Text | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }

    It 'fails closed on IMDS identity, private boundary, SQL 2022 Enterprise, and Trusted Launch checks' {
        $text = $script:SqlContract.Text
        $text | Should -Match '169\.254\.169\.254/metadata/instance'
        $text | Should -Match 'compute\.name'
        $text | Should -Match 'compute\.vmSize'
        $text | Should -Match 'compute\.location'
        $text | Should -Match 'publicIpAddress'
        $text | Should -Match 'ProductMajorVersion'
        $text | Should -Match 'Enterprise'
        $text | Should -Match 'Win32_Tpm|Get-Tpm'
        $text | Should -Match 'Confirm-SecureBootUEFI'
        $text | Should -Match 'compute\.location\s+-ieq\s+\$payload\.ExpectedLocation'
        $text | Should -Match 'compute\.name\s+-ceq\s+\$payload\.ExpectedVmName'
        $text | Should -Match 'compute\.vmSize\s+-ceq\s+\$payload\.ExpectedVmSize'
        $text | Should -Match 'PathName.*sqlservr\\\.exe'
        $text | Should -Not -Match "Where-Object\s*\{\s*\$_.Name\s+-notmatch\s+'Launcher\|FDLauncher'"
    }

    It 'uses canonical SqlClient keyword indexers compatible with Windows PowerShell 5' {
        $text = $script:SqlContract.Text
        foreach ($keyword in @(
            'Data Source', 'Initial Catalog', 'Integrated Security', 'Encrypt',
            'TrustServerCertificate', 'Application Name'
        )) {
            $text | Should -Match ("\['{0}'\]\s*=" -f [regex]::Escape($keyword))
        }
        $text | Should -Not -Match '\$builder\.(DataSource|InitialCatalog|IntegratedSecurity|Encrypt|TrustServerCertificate|ApplicationName)\s*='
    }

    It 'maps exact LUN zero and one with expected sizes and verifies 64 KiB NTFS labels' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'Mount-WorkshopDisk\s+-Lun\s+0'
        $text | Should -Match 'Mount-WorkshopDisk\s+-Lun\s+1'
        $text | Should -Match 'Initialize-Disk'
        $text | Should -Match 'PartitionStyle\s+GPT'
        $text | Should -Match 'Format-Volume'
        $text | Should -Match 'AllocationUnitSize\s+65536'
        $text | Should -Match 'SQLData'
        $text | Should -Match 'SQLLog'
        $text | Should -Match 'F'
        $text | Should -Match 'G'
        $text | Should -Match 'AllocationUnitSize'
        $text | Should -Match '-not\s+\$_.IsBoot'
        $text | Should -Match '-not\s+\$_.IsSystem'
    }

    It 'preflights exact F and G assignments and never selects an alternate drive letter' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'Get-Volume\s+-DriveLetter\s+\$PreferredDriveLetter'
        $text | Should -Match 'Get-Partition\s+-DriveLetter\s+\$PreferredDriveLetter'
        $text | Should -Match "PreferredDriveLetter\s+F"
        $text | Should -Match "PreferredDriveLetter\s+G"
        $text | Should -Not -Match '\[char\]\(\[int\]\$PreferredDriveLetter\s*\+'
        $text | Should -Match 'Drive\s*=\s*"\$PreferredDriveLetter`:"'
        $fPreflight = $text.IndexOf('PreferredDriveLetter F -PreflightOnly')
        $gPreflight = $text.IndexOf('PreferredDriveLetter G -PreflightOnly')
        $firstMutation = $text.IndexOf('Mount-WorkshopDisk -Lun 0 -ExpectedSizeGiB', $gPreflight + 1)
        $fPreflight | Should -BeGreaterThan -1
        $gPreflight | Should -BeGreaterThan $fPreflight
        $firstMutation | Should -BeGreaterThan $gPreflight
    }

    It 'moves and verifies every TempDB file under one capacity-checked approved root' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'FROM\s+tempdb\.sys\.database_files'
        $text | Should -Match 'type_desc'
        $text | Should -Match 'file_id'
        $text | Should -Match 'QUOTENAME'
        $text | Should -Match 'Get-PSDrive|SizeRemaining'
        $text | Should -Match 'FileCount'
        $text | Should -Match 'Files\s*='
        $text | Should -Match 'OldPathCount'
        $text | Should -Match 'AllFilesUnderApprovedRoot'
        $text | Should -Not -Match '\$tempDbPathCount\s+-eq\s+2'
    }

    It 'uses resource TempDB only after safety validation and otherwise records managed fallback' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'Get-Volume\s+-DriveLetter\s+D'
        $text | Should -Match 'Get-Partition\s+-DriveLetter\s+D'
        $text | Should -Match 'HealthStatus'
        $text | Should -Match 'IsBoot'
        $text | Should -Match 'IsSystem'
        $text | Should -Match 'requiredTempDbBytes'
        $text | Should -Match 'ManagedData'
        $text | Should -Match 'TempDB placed on managed data disk'
    }

    It 'configures SQL 1433, a narrow firewall rule, disabled Browser, and exact service restart readback' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'TcpPort'
        $text | Should -Match '1433'
        $text | Should -Match '10\.20\.1\.0/24'
        $text | Should -Match 'New-NetFirewallRule'
        $text | Should -Match 'SQLBrowser'
        $text | Should -Match 'Disabled'
        $text | Should -Match 'Restart-Service'
        $text | Should -Match 'Running'
        $text | Should -Not -Match '(?i)RemoteAddress\s+[''\"]?(Any|\*|0\.0\.0\.0/0)'
        $text | Should -Match "Win32_Service\s+-Filter\s+`"Name='SQLBrowser'`""
        $text | Should -Match 'browserService\.StartMode'
        $text | Should -Match 'firewallAddressReadback'
        $text | Should -Match 'RemoteAddress.*adminSubnet'
        $text | Should -Match 'ConvertTo-WorkshopCanonicalIpv4Network'
        $text | Should -Match 'firewallRemoteNetworks\s*=.*firewallAddressReadback\.RemoteAddress'
        $text | Should -Match 'expectedAdminNetwork\s*=\s*ConvertTo-WorkshopCanonicalIpv4Network'
        $text | Should -Match 'firewallRemoteNetworks\[0\]\s+-ceq\s+\$expectedAdminNetwork'
        $text | Should -Not -Match 'RemoteAddress\)\[0\]\s+-ceq\s+\$adminSubnet'
        $text | Should -Match 'Get-NetFirewallApplicationFilter'
        $text | Should -Match 'Get-NetFirewallServiceFilter'
        $text | Should -Match 'sqlservr\\\.exe'
        $text | Should -Match '\$service\.Name'
    }

    It 'creates non-exportable private-DNS TLS and exports only a public certificate' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'sql01\.mcpworkshop\.internal'
        $text | Should -Match 'New-SelfSignedCertificate'
        $text | Should -Match '1\.3\.6\.1\.5\.5\.7\.3\.1'
        $text | Should -Match 'Exportable\s*[:=]\s*\$false|-KeyExportPolicy\s+NonExportable'
        $text | Should -Match 'Export-Certificate'
        $text | Should -Match 'ForceEncryption'
        $text | Should -Match 'Certificate'
        $text | Should -Match 'Get-Acl|Set-Acl|CryptoKeySecurity'
        $text | Should -Not -Match 'Export-PfxCertificate|\.pfx'
        $text | Should -Match 'Get-WorkshopAccessibleRsaPrivateKey'
        $text | Should -Match 'CryptographicException'
        $text | Should -Match 'catch\s+\[Security\.Cryptography\.CryptographicException\]\s*\{\s*return\s+\$null'
    }

    It 'reads back the exact normalized TLS binding and rejects certificate load errors' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'certificateThumbprint'
        $text | Should -Match 'Get-ItemPropertyValue\s+-Path\s+\$tcpRoot\s+-Name\s+Certificate'
        $text | Should -Match 'TlsLoadFailures'
        $text | Should -Match 'failed\|failure\|could not\|unable\|not'
        $text | Should -Match 'load\|initialize'
        $text | Should -Match 'ErrorLogPath'
        $text | Should -Not -Match "Get-ChildItem\s+-Path\s+'C:\\\\Program Files\\\\Microsoft SQL Server'.*-Recurse"
        $text | Should -Match 'PublicCertificateThumbprint'
        $text | Should -Match 'RegistryCertificate'
        $text | Should -Match 'ForceEncryption'
        $text | Should -Match 'storeCertificate'
    }

    It 'requires the reviewed official backup SHA256 before VERIFYONLY and bootstraps only scripts 00 through 05' {
        $text = $script:SqlContract.Text
        $runnerText = Get-Content -LiteralPath (Join-Path $script:DeployRoot 'Invoke-WorkshopSqlScripts.ps1') -Raw
        $config = Import-PowerShellDataFile $script:ConfigPath
        $text | Should -Match 'https://github\.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022\.bak'
        $text | Should -Match 'Get-FileHash'
        $text | Should -Match 'SHA256'
        $config.AdventureWorksBackup.Sha256 | Should -Be 'D17567ADB1521F972E1DC183A7216CEA869C4580B5D75632425BCADBAF82CE5E'
        $text | Should -Match 'expected-verified'
        $text | Should -Match 'Invoke-WorkshopSqlScripts\.ps1'
        $hashAt = $text.IndexOf('Get-FileHash')
        $expectedHashAt = $text.IndexOf('AdventureWorksBackupSha256')
        $verifyAt = $text.IndexOf('RESTORE VERIFYONLY')
        $runnerAt = $text.IndexOf('& $runner')
        $hashAt | Should -BeGreaterThan -1
        $expectedHashAt | Should -BeGreaterThan -1
        $hashAt | Should -BeLessThan $verifyAt
        $expectedHashAt | Should -BeLessThan $verifyAt
        $verifyAt | Should -BeLessThan $runnerAt
        $positions = 0..5 | ForEach-Object { $text.IndexOf(('0{0}-' -f $_)) }
        $positions | ForEach-Object { $_ | Should -BeGreaterThan -1 }
        $text | Should -Not -Match '06-CreateOptimizedProcedure|07-ValidateEquivalence|08-OptionalQueryStoreHint|09-Cleanup'
        $runnerText | Should -Match '00-Preflight\.sql'
        $runnerText | Should -Match '05-CreateDiagnostics\.sql'
        $runnerText | Should -Not -Match '06-CreateOptimizedProcedure|07-ValidateEquivalence|08-OptionalQueryStoreHint|09-Cleanup'
    }

    It 'rejects an existing or downloaded backup digest mismatch before SQL verification and runner execution' -ForEach @(
        @{ Case = 'existing'; Existing = $true; ExpectedDownloads = 0 }
        @{ Case = 'downloaded'; Existing = $false; ExpectedDownloads = 1 }
    ) {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-VerifiedAdventureWorksBackup'
        }, $true)
        $function | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($function.Extent.Text))
        $path = Join-Path $TestDrive "$Case.bak"
        if ($Existing) { Set-Content -LiteralPath $path -Value 'tampered' -NoNewline }
        $script:downloads = 0
        $download = {
            param($Uri, $OutFile)
            $null = $Uri
            $script:downloads++
            Set-Content -LiteralPath $OutFile -Value 'tampered' -NoNewline
        }
        $hash = {
            param($LiteralPath, $Algorithm)
            $null = $LiteralPath, $Algorithm
            [pscustomobject]@{ Hash = ('0' * 64) }
        }

        { Get-VerifiedAdventureWorksBackup -Uri 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak' `
                -Path $path -ExpectedSha256 ('A' * 64) -DownloadOperation $download -HashOperation $hash } |
            Should -Throw '*SHA256*'
        $script:downloads | Should -Be $ExpectedDownloads
    }

    It 'writes a secret-free ACL-restricted positive readiness report with required readbacks' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'C:\\McpSqlWorkshop\\evidence\\sql-vm-readiness\.json'
        foreach ($term in @('version', 'edition', 'disk', 'firewall', 'certificate', 'encryption', 'QueryStore', 'ResourceGovernor', 'procedure')) {
            $text | Should -Match $term
        }
        $text | Should -Match 'Set-Acl'
        $text | Should -Match 'Completed'
    }
}

Describe 'Administration VM bootstrap static contract' {
    BeforeAll {
        $script:AdminContract = Get-ScriptContract -Path $script:AdminBootstrapPath
        $script:AdminWrapperContract = Get-ScriptContract -Path $script:AdminBootstrapWrapperPath
    }

    It 'exists, parses, and accepts only a protected payload file' {
        Test-Path -LiteralPath $script:AdminBootstrapPath | Should -BeTrue
        $script:AdminContract.Errors | Should -HaveCount 0
        @($script:AdminContract.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath) | Should -Contain 'ProtectedPayloadPath'
        $script:AdminContract.Text | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }

    It 'bootstraps PowerShell 7 before a single guarded re-execution without secret arguments' {
        Test-Path -LiteralPath $script:AdminBootstrapWrapperPath | Should -BeTrue
        $script:AdminWrapperContract.Errors | Should -HaveCount 0
        @($script:AdminWrapperContract.Ast.ParamBlock.Parameters.Name.VariablePath.UserPath) |
            Should -Be @('ProtectedPayloadPath')
        $wrapper = $script:AdminWrapperContract.Text
        $wrapper | Should -Match 'Microsoft\.PowerShell'
        $wrapper | Should -Match 'winget\.exe'
        $wrapper | Should -Match 'MCP_SQL_ADMIN_BOOTSTRAP_PWSH'
        $wrapper | Should -Match 'pwsh\.exe'
        $wrapper | Should -Match 'Initialize-AdminVm\.ps1'
        $wrapper.IndexOf('Microsoft.PowerShell') | Should -BeLessThan $wrapper.IndexOf('pwsh.exe')
        [regex]::Matches($wrapper, '(?im)^\s*&\s+\$pwshPath\s+').Count | Should -Be 1
        $wrapper | Should -Match 'exit\s+\$exitCode'
        $wrapper | Should -Match 'Remove-Item\s+-LiteralPath\s+\$ProtectedPayloadPath'
        $wrapper | Should -Not -Match 'Unprotect-CmsMessage|ConvertFrom-Json|McpReaderSecret|password|token'
        $wrapper | Should -Not -Match '(?i)&\s+\$pwshPath[^\r\n]*(?:-Command|-EncodedCommand)'
    }

    It 'requires PowerShell 7.4 before any DAB SqlClient assembly load' {
        $text = $script:AdminContract.Text
        $versionGate = $text.IndexOf("[version]'7.4'")
        $addType = $text.IndexOf('Add-Type')
        $versionGate | Should -BeGreaterThan -1
        $addType | Should -BeGreaterThan $versionGate
        $text | Should -Match 'MCP_SQL_ADMIN_BOOTSTRAP_PWSH'
    }

    It 'grants only inherited Modify to a validated local workspace user and verifies exact ACL facts' {
        $text = $script:AdminContract.Text
        $text | Should -Match 'Get-LocalUser'
        $text | Should -Match 'SecurityIdentifier'
        $text | Should -Match "'Modify'\s*,\s*'ContainerInherit,ObjectInherit'"
        $text | Should -Not -Match "InteractiveUser[^\r\n]*'FullControl'"
        $text | Should -Match 'WorkspaceUserModify'
        $text | Should -Match 'EnvAclRestricted'
        $text | Should -Match '\$workspaceUserModify\s*=\s*Grant-WorkshopWorkspaceModify'
        $text | Should -Match 'WorkspaceUserModify\s*=\s*\$workspaceUserModify'
        $text | Should -Match 'EnvAclRestricted\s*=\s*\$rootEnvAclRestricted'
        $text | Should -Match 'AreAccessRulesProtected'
        $text | Should -Match 'InheritanceFlags.*ContainerInherit'
        $text | Should -Match 'InheritanceFlags.*ObjectInherit'
    }

    It 'verifies Windows 11 24H2 Enterprise, activation availability, IMDS identity, and Trusted Launch' {
        $text = $script:AdminContract.Text
        $text | Should -Match '169\.254\.169\.254/metadata/instance'
        $text | Should -Match 'Windows 11 Enterprise'
        $text | Should -Match '24H2|26100'
        $text | Should -Match 'SoftwareLicensingProduct'
        $text | Should -Match 'Unknown|Unavailable'
        $text | Should -Match 'Confirm-SecureBootUEFI'
        $text | Should -Match 'Win32_Tpm|Get-Tpm'
        $text | Should -Match 'publicIpAddress'
        $text | Should -Match 'compute\.location\s+-ieq\s+\$payload\.ExpectedLocation'
        $text | Should -Match 'compute\.name\s+-ceq\s+\$payload\.ExpectedVmName'
        $text | Should -Match 'compute\.vmSize\s+-ceq\s+\$payload\.ExpectedVmSize'
    }

    It 'installs exact official winget packages and VS Code extensions noninteractively and reads versions back' {
        $text = $script:AdminContract.Text
        foreach ($id in @('Microsoft.PowerShell', 'Microsoft.VisualStudioCode', 'Microsoft.SQLServerManagementStudio', 'Microsoft.DotNet.SDK.9', 'Git.Git', 'GitHub.cli')) {
            $text | Should -Match ([regex]::Escape($id))
        }
        foreach ($id in @('ms-mssql.mssql', 'GitHub.copilot', 'GitHub.copilot-chat', 'ms-vscode.powershell')) {
            $text | Should -Match ([regex]::Escape($id))
        }
        $text | Should -Match '--accept-package-agreements'
        $text | Should -Match '--accept-source-agreements'
        $text | Should -Match '--install-extension'
        $text | Should -Match '--version|--list-extensions'
    }

    It 'uses the pinned local DAB tool and validates the repository configuration' {
        $manifest = Get-Content -LiteralPath $script:ToolManifestPath -Raw | ConvertFrom-Json
        $manifest.tools.'microsoft.dataapibuilder'.version | Should -Be '2.0.9'
        $manifest.tools.'microsoft.dataapibuilder'.commands | Should -Contain 'dab'
        $text = $script:AdminContract.Text
        $text | Should -Match "'tool',\s*'restore'"
        $text | Should -Match "'tool',\s*'run',\s*'dab',\s*'--version'"
        $text | Should -Match "'tool',\s*'run',\s*'dab',\s*'--',\s*'validate'"
        $text | Should -Not -Match '(?i)dotnet\s+tool\s+install'
    }

    It 'checks out the exact protected commit and imports only a fingerprint-matched public certificate' {
        $text = $script:AdminContract.Text
        $text | Should -Match "'clone',\s*'--no-checkout'"
        $text | Should -Match "'checkout',\s*'--detach'"
        $text | Should -Match "'rev-parse',\s*'HEAD'"
        $text | Should -Match 'Import-Certificate'
        $text | Should -Match 'Get-FileHash'
        $text | Should -Match 'PublicCertificateSha256'
        $text | Should -Match 'CertificateThumbprint'
        $text | Should -Not -Match 'Import-PfxCertificate|\.pfx'
        $text | Should -Match 'SqlClientChainHostAndTransferredCertificate'
    }

    It 'creates only root env with restrictive ACL and verifies private DNS encrypted SQL and MCP allowlist' {
        $text = $script:AdminContract.Text
        $text | Should -Match 'Resolve-DnsName'
        $text | Should -Match 'Test-NetConnection'
        $text | Should -Match "-HostNameInCertificate\s+'sql01\.mcpworkshop\.internal'"
        $text | Should -Match 'Encrypt\s*=\s*\$true'
        $text | Should -Match 'TrustServerCertificate\s*=\s*\$false'
        $text | Should -Match 'ApplicationName'
        $text | Should -Match 'Microsoft\.Data\.SqlClient\.SqlConnectionStringBuilder'
        $text | Should -Match 'UTF8Encoding\]\:\:new\(\$false\)'
        $text | Should -Match 'encrypt_option'
        $text | Should -Match 'initialize'
        $text | Should -Match 'tools/list'
        foreach ($tool in @('get_memory_snapshot', 'get_active_workshop_grants', 'get_query_store_top_queries', 'get_query_store_waits', 'get_procedure_plan_summary', 'compare_workshop_runs')) {
            $text | Should -Match $tool
        }
        $text | Should -Match 'create-record|create_records|update-record|update_records|delete-record|delete_records'
        $text | Should -Match 'GitHubCliAuthStatus'
        $text | Should -Match 'CopilotAuthStatus'
        $text | Should -Match 'InteractiveSignInRequired'
        $text | Should -Match 'Set-Acl'
        $text | Should -Not -Match 'mcp[/\\]\.env'
    }

    It 'round-trips a delimiter-bearing password through a Microsoft.Data-compatible parser without output leakage' {
        foreach ($functionName in @('ConvertTo-DabMssqlConnectionString', 'Read-DabMssqlEnvironment')) {
            $functionAst = $script:AdminContract.Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            }, $true)
            $functionAst | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        if ('Microsoft.Data.SqlClient.TestSqlConnectionStringBuilder' -as [type] -eq $null) {
            Add-Type -TypeDefinition @'
namespace Microsoft.Data.SqlClient {
    public sealed class TestSqlConnectionStringBuilder : System.Data.Common.DbConnectionStringBuilder {
        public TestSqlConnectionStringBuilder() { }
        public TestSqlConnectionStringBuilder(string value) { ConnectionString = value; }
        private string Get(string key) { return ContainsKey(key) ? (string)this[key] : string.Empty; }
        private bool GetBool(string key) { return ContainsKey(key) && System.Convert.ToBoolean(this[key]); }
        public string DataSource { get { return Get("Data Source"); } set { this["Data Source"] = value; } }
        public string InitialCatalog { get { return Get("Initial Catalog"); } set { this["Initial Catalog"] = value; } }
        public string UserID { get { return Get("User ID"); } set { this["User ID"] = value; } }
        public string Password { get { return Get("Password"); } set { this["Password"] = value; } }
        public bool Encrypt { get { return GetBool("Encrypt"); } set { this["Encrypt"] = value; } }
        public bool TrustServerCertificate { get { return GetBool("TrustServerCertificate"); } set { this["TrustServerCertificate"] = value; } }
        public string HostNameInCertificate { get { return Get("Host Name In Certificate"); } set { this["Host Name In Certificate"] = value; } }
        public string ApplicationName { get { return Get("Application Name"); } set { this["Application Name"] = value; } }
    }
}
'@
        }

        $builderType = 'Microsoft.Data.SqlClient.TestSqlConnectionStringBuilder' -as [type]
        $secret = 'canary;value="quoted";tail'
        $secureSecret = [securestring]::new()
        foreach ($character in $secret.ToCharArray()) { $secureSecret.AppendChar($character) }
        $secureSecret.MakeReadOnly()
        $envPath = Join-Path $TestDrive '.env'
        $captured = @(
            $connectionString = ConvertTo-DabMssqlConnectionString -BuilderType $builderType `
                -DataSource 'sql01.mcpworkshop.internal' -Database 'AdventureWorks2022' `
            -UserId 'mcp_workshop_reader' -ReaderSecret $secureSecret `
                -HostNameInCertificate 'sql01.mcpworkshop.internal' `
                -ApplicationName 'MCP-SQL-Workshop-MCP'
            [IO.File]::WriteAllText(
                $envPath,
                "MSSQL_CONNECTION_STRING=$connectionString`r`n",
                [Text.UTF8Encoding]::new($false)
            )
            $parsed = Read-DabMssqlEnvironment -Path $envPath -BuilderType $builderType `
                -ExpectedDataSource 'sql01.mcpworkshop.internal' `
                -ExpectedUserId 'mcp_workshop_reader' `
                -ExpectedHostNameInCertificate 'sql01.mcpworkshop.internal' `
                -ExpectedApplicationName 'MCP-SQL-Workshop-MCP'
        )

        ($captured -join ' ') | Should -Not -Match ([regex]::Escape($secret))
        $parsed.DataSource | Should -BeExactly 'sql01.mcpworkshop.internal'
        $parsed.Encrypt | Should -BeTrue
        $parsed.TrustServerCertificate | Should -BeFalse
        $parsed.HostNameInCertificate | Should -BeExactly 'sql01.mcpworkshop.internal'
        $parsed.UserId | Should -BeExactly 'mcp_workshop_reader'
        $parsed.PasswordPresent | Should -BeTrue
        $parsed.ApplicationName | Should -BeExactly 'MCP-SQL-Workshop-MCP'
        $parsed.Builder.Password | Should -BeExactly $secret
        [IO.File]::ReadAllBytes($envPath)[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'observes GitHub CLI authentication without emitting token-bearing output' {
        $functionAst = $script:AdminContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-GitHubCliAuthStatus'
        }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($functionAst.Extent.Text))
        (Get-GitHubCliAuthStatus -GitHubCliPath 'gh.exe' -CommandInvoker {
            param($FilePath, $Arguments)
            $null = $FilePath, $Arguments
            [pscustomobject]@{ ExitCode = 0; Output = @('github.com account observed') }
        }).Status | Should -Be 'Authenticated'
        (Get-GitHubCliAuthStatus -GitHubCliPath 'gh.exe' -CommandInvoker {
            param($FilePath, $Arguments)
            $null = $FilePath, $Arguments
            [pscustomobject]@{ ExitCode = 1; Output = @('not logged in') }
        }).Status | Should -Be 'NotAuthenticated'
        (Get-GitHubCliAuthStatus -GitHubCliPath $null -CommandInvoker { throw 'must not run' }).Status |
            Should -Be 'Unavailable'
    }
}

Describe 'Bootstrap orchestration and evidence contracts' {
    BeforeAll {
        $script:SqlContract = Get-ScriptContract -Path $script:SqlBootstrapPath
        Import-Module $script:ModulePath -Force
        $script:BootstrapConfig = Import-PowerShellDataFile (Join-Path $script:DeployRoot 'WorkshopConfig.psd1')
        $script:SecureValue = [Security.SecureString]::new()
        foreach ($character in 'unit-test-secret-value'.ToCharArray()) { $script:SecureValue.AppendChar($character) }
        $script:SecureValue.MakeReadOnly()
        $script:AdministratorCredential = [PSCredential]::new('workshop-admin', $script:SecureValue)

        function Get-CompleteReadinessPair {
            $deploymentId = '11111111-2222-3333-4444-555555555555'
            $commit = '0123456789abcdef0123456789abcdef01234567'
            $thumbprint = '0123456789ABCDEF0123456789ABCDEF01234567'
            $publicHash = 'A' * 64
            [pscustomobject]@{
                Sql = [pscustomobject]@{
                    SchemaVersion = '1.0'; DeploymentId = $deploymentId; Completed = $true
                    Evidence = [pscustomobject]@{ Sanitized = $true }
                    Repository = [pscustomobject]@{ Commit = $commit }
                    Vm = [pscustomobject]@{ Name = 'vm-mcpsql-sql'; Size = 'Standard_E8s_v5'; Location = 'indonesiacentral'; PublicIp = $false; SecureBoot = $true; Tpm = $true }
                    Sql = [pscustomobject]@{ Version = 16; Edition = 'Enterprise Edition'; Service = 'MSSQLSERVER'; State = 'Running'; Port = 1433; BrowserStartupType = 'Disabled'; Encryption = 'Forced'; EncryptOption = 'TRUE' }
                    Disks = @(
                        [pscustomobject]@{ Lun = 0; Drive = 'F:'; Label = 'SQLData'; AllocationUnitSize = 65536; SizeGiB = 256 },
                        [pscustomobject]@{ Lun = 1; Drive = 'G:'; Label = 'SQLLog'; AllocationUnitSize = 65536; SizeGiB = 128 }
                    )
                    TempDb = [pscustomobject]@{ ApprovedRoot = 'D:\SQLTempDB'; Storage = 'Temporary'; Deviation = $null; EnoughSpace = $true; FileCount = 3; AllFilesUnderApprovedRoot = $true; OldPathCount = 0; Files = @(
                        [pscustomobject]@{ FileId = 1; LogicalName = 'tempdev'; Type = 'ROWS'; PhysicalName = 'D:\SQLTempDB\tempdb-1-tempdev.mdf' },
                        [pscustomobject]@{ FileId = 2; LogicalName = 'templog'; Type = 'LOG'; PhysicalName = 'D:\SQLTempDB\templog-2-templog.ldf' },
                        [pscustomobject]@{ FileId = 3; LogicalName = 'temp2'; Type = 'ROWS'; PhysicalName = 'D:\SQLTempDB\tempdb-3-temp2.ndf' }
                    ) }
                    Firewall = [pscustomobject]@{ Rule = 'MCP SQL Workshop 1433'; RemoteAddress = '10.20.1.0/24'; BroadRule = $false }
                    Certificate = [pscustomobject]@{ DnsName = 'sql01.mcpworkshop.internal'; Thumbprint = $thumbprint; RegistryCertificate = $thumbprint; StoreThumbprint = $thumbprint; ForceEncryption = 1; HasPrivateKey = $true; ServerAuthenticationEku = $true; SanVerified = $true; ServiceKeyAclVerified = $true; PublicCertificateThumbprint = $thumbprint; PublicCertificateSha256 = $publicHash; PrivateKeyExported = $false; TlsLoadFailures = 0; StartupBindingEvidence = 'DeferredRemoteValidation' }
                    Backup = [pscustomobject]@{ VerifyOnly = $true; Sha256 = 'B' * 64; ExpectedSha256 = 'B' * 64; ChecksumClassification = 'expected-verified' }
                    Database = [pscustomobject]@{ Marker = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C'; QueryStore = 'READ_WRITE'; ResourceGovernor = 'Enabled'; ProcedureCount = 7 }
                }
                Admin = [pscustomobject]@{
                    SchemaVersion = '1.0'; DeploymentId = $deploymentId; Completed = $true
                    Evidence = [pscustomobject]@{ Sanitized = $true }
                    Vm = [pscustomobject]@{ Name = 'vm-mcpsql-admin'; Size = 'Standard_D4s_v5'; Location = 'indonesiacentral'; AdminPublicIpBoundaryObserved = $true; PublicIpCount = 1; SecureBoot = $true; Tpm = $true; Os = 'Microsoft Windows 11 Enterprise'; Build = '26100'; Activation = 'ObservedUnknown'; WindowsClientLicenseAttested = $true }
                    Repository = [pscustomobject]@{ Commit = $commit }
                    Workspace = [pscustomobject]@{ User = 'VM-MCPSQL-ADMIN\workshop-admin'; WorkspaceUserModify = $true }
                    RootEnvAcl = [pscustomobject]@{ Path = 'C:\McpSqlWorkshop\workspace\.env'; Restricted = $true; EnvAclRestricted = $true }
                    Tools = [pscustomobject]@{ VisualStudioCode = '1.99.0'; DotNet = '9.0.100'; Git = 'git version 2.49.0'; GitHubCli = 'gh version 2.70.0'; DAB = '2.0.9'; WingetPackages = @(
                        [pscustomobject]@{ Id = 'Microsoft.PowerShell'; VersionReadback = '7.4.0' },
                        [pscustomobject]@{ Id = 'Microsoft.VisualStudioCode'; VersionReadback = '1.99.0' },
                        [pscustomobject]@{ Id = 'Microsoft.SQLServerManagementStudio'; VersionReadback = '22.7.0' },
                        [pscustomobject]@{ Id = 'Microsoft.DotNet.SDK.9'; VersionReadback = '9.0.100' },
                        [pscustomobject]@{ Id = 'Git.Git'; VersionReadback = '2.49.0' },
                        [pscustomobject]@{ Id = 'GitHub.cli'; VersionReadback = '2.70.0' }
                    ); Extensions = @('ms-mssql.mssql@1.30.0', 'GitHub.copilot@1.300.0', 'GitHub.copilot-chat@0.25.0', 'ms-vscode.powershell@2025.0.0') }
                    Auth = [pscustomobject]@{ GitHubCliAuthStatus = 'Unavailable'; CopilotAuthStatus = 'InteractiveSignInRequired' }
                    Network = [pscustomobject]@{ DnsName = 'sql01.mcpworkshop.internal'; ResolvedAddress = '10.20.2.10'; Tcp1433 = $true }
                    SqlTls = [pscustomobject]@{ DnsName = 'sql01.mcpworkshop.internal'; Address = '10.20.2.10'; Tcp1433 = $true; CertificateThumbprint = $thumbprint; PublicCertificateSha256 = $publicHash; CertificateValidated = $true; ValidationMethod = 'SqlClientChainHostAndTransferredCertificate'; EncryptOption = 'TRUE'; TrustServerCertificate = $false; HostNameInCertificate = 'sql01.mcpworkshop.internal'; RemoteAdminTest = $true }
                    Mcp = [pscustomobject]@{ ConfigValid = $true; DabMinimumVersionMet = $true; ForbiddenMutationTools = $false; ToolNames = @(
                        'describe_entities', 'read_records', 'execute_entity', 'aggregate_records',
                        'get_memory_snapshot', 'get_active_workshop_grants', 'get_query_store_top_queries',
                        'get_query_store_waits', 'get_procedure_plan_summary', 'compare_workshop_runs'
                    ) }
                }
            }
        }
    }

    It 'exports bootstrap, readiness, and evidence functions' {
        $manifest = Test-ModuleManifest $script:ModulePath
        foreach ($name in @('Initialize-WorkshopSqlVm', 'Initialize-WorkshopAdminVm', 'Test-WorkshopReadiness', 'Export-WorkshopDeploymentEvidence')) {
            $manifest.ExportedFunctions.Keys | Should -Contain $name
        }
    }

    It 'uses protected extension settings and never puts payloads or secrets in public settings' {
        $moduleText = Get-Content -LiteralPath (Join-Path $script:DeployRoot 'Workshop.Azure.psm1') -Raw
        $moduleText | Should -Match 'ProtectedSettings'
        $moduleText | Should -Match 'Set-AzVMExtension|Set-AzVMCustomScriptExtension'
        $moduleText | Should -Match 'Initialize-WorkshopSqlVm'
        $moduleText | Should -Match 'Initialize-WorkshopAdminVm'
        $moduleText | Should -Match 'Test-WorkshopReadiness'
        $moduleText | Should -Match 'Protect-CmsMessage'
        $moduleText | Should -Not -Match 'payloadBase64'
        $script:SqlContract.Text | Should -Match 'Unprotect-CmsMessage'
        $script:AdminContract.Text | Should -Match 'Unprotect-CmsMessage'
        $moduleText | Should -Not -Match '(?i)Settings\s*=\s*@\{[^}]*password'
    }

    It 'stages the trusted launcher and encrypted payload before using a short extension command' {
        $moduleText = Get-Content -LiteralPath (Join-Path $script:DeployRoot 'Workshop.Azure.psm1') -Raw
        $moduleText | Should -Match 'StageBootstrapFiles'
        $moduleText | Should -Match 'bootstrap-launcher\.ps1'
        $moduleText | Should -Match 'Invoke-AzVMRunCommand'
        $moduleText | Should -Match 'Add-Type\s+-AssemblyName\s+System\.IO\.Compression'
        $moduleText | Should -Match 'Add-Type\s+-AssemblyName\s+System\.IO\.Compression\.FileSystem'
        $moduleText.IndexOf('Add-Type -AssemblyName System.IO.Compression') |
            Should -BeLessThan $moduleText.IndexOf('$null = Expand-WorkshopBootstrapArchive')
        $moduleText | Should -Not -Match 'commandToExecute\s*=\s*"[^"]*-EncodedCommand'
        $moduleText.IndexOf('& $Operations.StageBootstrapFiles') |
            Should -BeLessThan $moduleText.IndexOf('& $Operations.SetExtension')
    }

    It 'starts the administration bootstrap through the PowerShell 5 safe wrapper' {
        $moduleText = Get-Content -LiteralPath (Join-Path $script:DeployRoot 'Workshop.Azure.psm1') -Raw
        $moduleText | Should -Match 'Invoke-AdminBootstrap\.ps1'
        $moduleText | Should -Match 'Initialize-AdminVm\.ps1'
        $moduleText.IndexOf("Invoke-AdminBootstrap.ps1") | Should -BeGreaterThan -1
    }

    It 'configures MCP to invoke the pinned local tool and keeps role immediately after stdio mode' {
        $config = Get-Content -LiteralPath $script:McpConfigPath -Raw | ConvertFrom-Json
        $server = $config.servers.'mcp-sql-query-store-workshop'
        $server.command | Should -Be 'dotnet'
        $server.args[0..3] | Should -Be @('tool', 'run', 'dab', '--')
        $stdioIndex = [array]::IndexOf([object[]] $server.args, '--mcp-stdio')
        $server.args[$stdioIndex + 1] | Should -Be 'role:workshop-reader'
    }

    It 'provides sanitized screenshot evidence pages without performing capture' {
        Test-Path -LiteralPath $script:EvidencePath | Should -BeTrue
        $text = Get-Content -LiteralPath $script:EvidencePath -Raw
        $text | Should -Match 'ConvertTo-Html'
        $text | Should -Match 'redact|Redact'
        $text | Should -Not -Match '(?i)(Start-Process.*(browser|msedge|chrome)|playwright|selenium)'
    }

    It 'contains no Python or Python package installation in either VM bootstrap' {
        $combined = (Get-Content -LiteralPath $script:SqlBootstrapPath -Raw) + "`n" +
            (Get-Content -LiteralPath $script:AdminBootstrapPath -Raw)
        $combined | Should -Not -Match '(?im)(^|[;&|\s])(python(\.exe)?|py(\.exe)?|pip(3)?)(\s|$)'
        $combined | Should -Not -Match '(?i)pypi'
    }

    It 'orchestrates SQL bootstrap through injected operations and returns only readiness evidence' {
        $script:CapturedPayload = $null
        $operations = @{
            GetSubscriptionId = { '11111111-1111-1111-1111-111111111111' }
            AcquireDeploymentLock = { [pscustomobject]@{ Acquired = $true } }
            ReleaseDeploymentLock = { param($Lease) $null = $Lease }
            GetRecipientCertificate = { 'public-recipient-certificate' }
            ProtectPayload = {
                param($Recipient, $Payload)
                $null = $Recipient
                $script:CapturedPayload = $Payload | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                'encrypted-cms-envelope'
            }
            StageBootstrapFiles = {
                param($VmName, $ResourceGroupName, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit)
                $null = $VmName, $ResourceGroupName, $BootstrapScript, $RepositoryCommit
                $ProtectedEnvelope | Should -Be 'encrypted-cms-envelope'
            }
            SetExtension = {
                param($VmName, $ResourceGroupName, $Location, $ArchiveUri, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit)
                $null = $VmName, $ResourceGroupName, $Location, $ArchiveUri, $BootstrapScript, $RepositoryCommit
                $ProtectedEnvelope | Should -Be 'encrypted-cms-envelope'
            }
            GetExtension = { [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/succeeded' }) } }
            ReadReadiness = { [pscustomobject]@{ Completed = $true; DeploymentId = '11111111-2222-3333-4444-555555555555'; Certificate = [pscustomobject]@{ PublicCertificatePath = 'C:\public.cer'; PublicCertificateSha256 = ('A' * 64) } } }
        }
        $result = Initialize-WorkshopSqlVm -Config $script:BootstrapConfig `
            -AdministratorCredential $script:AdministratorCredential `
            -DatabaseMasterKeyPassword $script:SecureValue -McpReaderPassword $script:SecureValue `
            -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
            -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
            -DeploymentId '11111111-2222-3333-4444-555555555555' -Operations $operations

        $result.Completed | Should -BeTrue
        $script:CapturedPayload.ExpectedVmName | Should -Be $script:BootstrapConfig.SqlVm.Name
        $script:CapturedPayload.AdministratorUserName | Should -Be 'workshop-admin'
        $script:CapturedPayload.AdministratorSecret | Should -Be 'unit-test-secret-value'
        $script:CapturedPayload.DatabaseMasterKeySecret | Should -Be 'unit-test-secret-value'
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'unit-test-secret-value'
    }

    It 'relaunches SQL bootstrap through a bounded temporary administrator task without command-line secrets' {
        $text = Get-Content -LiteralPath $script:SqlBootstrapPath -Raw
        $text | Should -Match 'AdministratorUserName'
        $text | Should -Match 'AdministratorSecret'
        $text | Should -Match "New-Object\s+-ComObject\s+'Schedule\.Service'"
        $text | Should -Match 'RegisterTaskDefinition'
        # SYSTEM is not a SQL sysadmin and Windows refuses an elevated S4U token for a
        # local administrator, so password logon is the only supported identity switch.
        $text | Should -Match 'Principal\.LogonType\s*=\s*1'
        $text | Should -Match 'Windows rejected the scheduled-task credential'
        $text | Should -Match 'DeleteTask'
        $text | Should -Match 'LastTaskResult'
        $text | Should -Match 'MaximumAttempts'
        $text | Should -Match 'Threading\.Thread.*Sleep'
        $text | Should -Match 'WindowsIdentity.*GetCurrent'
        $text | Should -Not -Match 'Start-Process\s+-FilePath\s+\$powerShellPath\s+-Credential'
        $text | Should -Not -Match 'Arguments[^\r\n]*AdministratorSecret'
    }

    It 'binds administrator bootstrap completion to fresh deployment-specific readiness and verified task cleanup' -ForEach @(
        @{ Case = 'matching'; Written = '11111111-2222-3333-4444-555555555555'; Throws = $false }
        @{ Case = 'mismatched'; Written = '99999999-2222-3333-4444-555555555555'; Throws = $true }
        @{ Case = 'stale left behind'; Written = $null; Throws = $true }
    ) {
        foreach ($name in @(
            'Read-WorkshopBootstrapReadiness', 'Test-WorkshopScheduledTaskNotFound',
            'Stop-WorkshopScheduledTaskForCleanup', 'Remove-WorkshopScheduledTaskWithProof',
            'Get-WorkshopBootstrapFailure', 'Invoke-WorkshopAdministratorBootstrap'
        )) {
            $definition = $script:SqlContract.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object Name -EQ $name | Select-Object -First 1
            $definition | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($definition.Extent.Text))
        }

        $completionPath = Join-Path $TestDrive "readiness-$($Case -replace '\s', '-').json"
        # Stale evidence from an earlier deployment must not be able to satisfy this run.
        Set-Content -LiteralPath $completionPath -Encoding UTF8 `
            -Value '{"Completed":true,"DeploymentId":"aaaaaaaa-2222-3333-4444-555555555555"}'
        # ScriptMethod bodies do not share the Pester script scope, so the probe state is a
        # closure-captured reference type instead.
        $state = @{
            Order = [System.Collections.Generic.List[string]]::new()
            StaleAtRegistration = $true
            Deleted = 0
        }
        $writtenId = $Written

        $action = [pscustomobject]@{ Path = ''; Arguments = '' }
        $actions = [pscustomobject]@{}
        $actions | Add-Member ScriptMethod Create { param($Type) $null = $Type; $action }.GetNewClosure()
        $taskDefinition = [pscustomobject]@{
            RegistrationInfo = [pscustomobject]@{ Description = '' }
            Principal = [pscustomobject]@{ UserId = ''; LogonType = 0; RunLevel = 0 }
            Settings = [pscustomobject]@{
                Enabled = $false; Hidden = $false; StartWhenAvailable = $false; AllowDemandStart = $false
                DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true; ExecutionTimeLimit = ''
            }
            Actions = $actions
        }
        $runningTask = [pscustomobject]@{ State = 3 }
        $registeredTask = [pscustomobject]@{ LastTaskResult = 0; State = 3 }
        $registeredTask | Add-Member ScriptMethod Run { param($Parameters) $null = $Parameters; $runningTask }.GetNewClosure()
        $registeredTask | Add-Member ScriptMethod Stop { param($Flags) $null = $Flags }
        $taskFolder = [pscustomobject]@{}
        $taskFolder | Add-Member ScriptMethod RegisterTaskDefinition {
            param($Name, $Definition, $Flags, $User, $Secret, $LogonType, $Sddl)
            $null = $Name, $Definition, $Flags, $User, $Secret, $LogonType, $Sddl
            $state.Order.Add('register')
            $state.StaleAtRegistration = Test-Path -LiteralPath $completionPath -PathType Leaf
            if ($null -ne $writtenId) {
                Set-Content -LiteralPath $completionPath -Encoding UTF8 `
                    -Value ('{"Completed":true,"DeploymentId":"' + $writtenId + '"}')
            }
            $registeredTask
        }.GetNewClosure()
        $taskFolder | Add-Member ScriptMethod DeleteTask {
            param($Name, $Flags)
            $null = $Name, $Flags
            $state.Order.Add('delete')
            $state.Deleted++
        }.GetNewClosure()
        $taskFolder | Add-Member ScriptMethod GetTask {
            param($Name)
            throw [IO.FileNotFoundException]::new("The system cannot find the file specified. ($Name)")
        }
        $service = [pscustomobject]@{}
        $service | Add-Member ScriptMethod Connect { }
        $service | Add-Member ScriptMethod GetFolder { param($Path) $null = $Path; $taskFolder }.GetNewClosure()
        $service | Add-Member ScriptMethod NewTask { param($Flags) $null = $Flags; $taskDefinition }.GetNewClosure()
        Mock New-Object { $service } -ParameterFilter { $ComObject -eq 'Schedule.Service' }

        $taskLogon = [Security.SecureString]::new()
        foreach ($character in [char[]] 'placeholder') { $taskLogon.AppendChar($character) }
        $invoke = {
            Invoke-WorkshopAdministratorBootstrap -UserName 'HOST\facilitator' `
                -Password $taskLogon `
                -ScriptPath 'C:\McpSqlWorkshop\Initialize-SqlVm.ps1' `
                -PayloadPath 'C:\McpSqlWorkshop\protected-bootstrap.cms' `
                -CompletionPath $completionPath `
                -ExpectedDeploymentId '11111111-2222-3333-4444-555555555555' `
                -MaximumAttempts 1 -WaitOperation { param($Attempt) $null = $Attempt }
        }

        if ($Throws) { $invoke | Should -Throw }
        else { (& $invoke).DeploymentId | Should -BeExactly '11111111-2222-3333-4444-555555555555' }

        # The stale document must be gone before the task is ever registered, and the
        # temporary task must be deleted with proof on every path.
        $state.StaleAtRegistration | Should -BeFalse
        $state.Order | Should -Contain 'register'
        $state.Deleted | Should -Be 1
        $state.Order.IndexOf('register') | Should -BeLessThan $state.Order.IndexOf('delete')
    }

    It 'keeps the administrator bootstrap contract free of secret-bearing task arguments' {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-WorkshopAdministratorBootstrap'
        }, $true)
        $function | Should -Not -BeNullOrEmpty
        $parameter = $function.Body.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'ExpectedDeploymentId'
        }
        $parameter | Should -Not -BeNullOrEmpty
        ($parameter.Attributes | Where-Object TypeName -Match 'Parameter').NamedArguments |
            Where-Object ArgumentName -EQ 'Mandatory' | Should -Not -BeNullOrEmpty
        $function.Extent.Text | Should -Not -Match 'Arguments[^\r\n]*plainPassword'
    }

    It 'keeps the guest wait budget inside the CustomScriptExtension timeout' {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-WorkshopAdministratorBootstrap'
        }, $true)
        $parameter = $function.Body.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'MaximumAttempts'
        }
        $parameter | Should -Not -BeNullOrEmpty

        $range = $parameter.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateRange' }
        $maximumAllowed = [int] $range.PositionalArguments[1].Value
        $defaultAttempts = [int] $parameter.DefaultValue.Value

        # The loop sleeps 3s per attempt and CustomScriptExtension gives up near 90 minutes,
        # so a larger budget yields a multi-hour stuck extension instead of a clear failure.
        ($defaultAttempts * 3) | Should -BeLessOrEqual 3600
        ($maximumAllowed * 3) | Should -BeLessThan 5400
    }

    It 'stops queued and running temporary tasks before deletion through executable cleanup behavior' -ForEach @(
        @{ State = 2; ExpectedStops = 1 }
        @{ State = 4; ExpectedStops = 1 }
        @{ State = 3; ExpectedStops = 0 }
    ) {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Stop-WorkshopScheduledTaskForCleanup'
        }, $true)
        $function | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($function.Extent.Text))
        $script:stopCalls = 0
        $task = [pscustomobject]@{ State = $State }
        $task | Add-Member -MemberType ScriptMethod -Name Stop -Value { param($Flags) $null = $Flags; $script:stopCalls++ }

        { Stop-WorkshopScheduledTaskForCleanup -Task $task } | Should -Not -Throw
        $script:stopCalls | Should -Be $ExpectedStops
    }

    It 'surfaces executable temporary-task stop failures for cleanup aggregation' {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Stop-WorkshopScheduledTaskForCleanup'
        }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
        $task = [pscustomobject]@{ State = 2 }
        $task | Add-Member -MemberType ScriptMethod -Name Stop -Value { throw 'queued stop failed' }

        { Stop-WorkshopScheduledTaskForCleanup -Task $task } | Should -Throw '*queued stop failed*'
    }

    It 'proves temporary-task deletion and rejects a task that survives deletion' -ForEach @(
        @{ Survives = $false }
        @{ Survives = $true }
    ) {
        foreach ($name in @('Test-WorkshopScheduledTaskNotFound', 'Remove-WorkshopScheduledTaskWithProof')) {
            $definition = $script:SqlContract.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object Name -EQ $name | Select-Object -First 1
            $definition | Should -Not -BeNullOrEmpty
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:deleteCalls = 0
        $folder = [pscustomobject]@{ Survives = $Survives }
        $folder | Add-Member ScriptMethod DeleteTask { param($Name, $Flags) $null = $Name, $Flags; $script:deleteCalls++ }
        $folder | Add-Member ScriptMethod GetTask {
            param($Name)
            $null = $Name
            if ($this.Survives) { return [pscustomobject]@{ Name = $Name } }
            throw [IO.FileNotFoundException]::new('The system cannot find the file specified.')
        }

        $action = { Remove-WorkshopScheduledTaskWithProof -TaskFolder $folder -TaskName 'McpSqlWorkshop-SqlBootstrap-1' }
        if ($Survives) { $action | Should -Throw '*still exists after deletion*' }
        else { $action | Should -Not -Throw }
        $script:deleteCalls | Should -Be 1
    }

    It 'treats only ERROR_FILE_NOT_FOUND as proof of deletion, including when it is wrapped' -ForEach @(
        @{ Case = 'direct not found'; Throws = $false }
        @{ Case = 'wrapped not found'; Throws = $false }
        @{ Case = 'access denied'; Throws = $true }
    ) {
        foreach ($name in @('Test-WorkshopScheduledTaskNotFound', 'Remove-WorkshopScheduledTaskWithProof')) {
            $definition = $script:SqlContract.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object Name -EQ $name | Select-Object -First 1
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $lookupCase = $Case
        $folder = [pscustomobject]@{}
        $folder | Add-Member ScriptMethod DeleteTask { param($Name, $Flags) $null = $Name, $Flags }
        $folder | Add-Member ScriptMethod GetTask {
            param($Name)
            $null = $Name
            switch ($lookupCase) {
                'direct not found' { throw [IO.FileNotFoundException]::new('The system cannot find the file specified.') }
                'wrapped not found' {
                    throw [InvalidOperationException]::new(
                        'Exception calling "GetTask".',
                        [IO.FileNotFoundException]::new('The system cannot find the file specified.'))
                }
                default { throw [UnauthorizedAccessException]::new('Access is denied.') }
            }
        }.GetNewClosure()

        $action = { Remove-WorkshopScheduledTaskWithProof -TaskFolder $folder -TaskName 'McpSqlWorkshop-SqlBootstrap-1' }
        if ($Throws) { $action | Should -Throw '*Access is denied*' }
        else { $action | Should -Not -Throw }
    }

    It 'treats a never-registered task as already absent instead of a cleanup failure' {
        foreach ($name in @('Test-WorkshopScheduledTaskNotFound', 'Remove-WorkshopScheduledTaskWithProof')) {
            $definition = $script:SqlContract.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true) | Where-Object Name -EQ $name | Select-Object -First 1
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $probe = @{ LookedUp = $false }
        $folder = [pscustomobject]@{}
        $folder | Add-Member ScriptMethod DeleteTask {
            param($Name, $Flags)
            $null = $Name, $Flags
            throw [IO.FileNotFoundException]::new('The system cannot find the file specified.')
        }
        $folder | Add-Member ScriptMethod GetTask {
            param($Name)
            $null = $Name
            $probe.LookedUp = $true
            [pscustomobject]@{ Name = 'unexpected survivor' }
        }.GetNewClosure()

        { Remove-WorkshopScheduledTaskWithProof -TaskFolder $folder -TaskName 'McpSqlWorkshop-SqlBootstrap-1' } |
            Should -Not -Throw
        $probe.LookedUp | Should -BeFalse
    }

    It 'preserves the primary bootstrap failure and reports unproven cleanup' -ForEach @(
        @{ Case = 'primary-only'; HasPrimary = $true; Cleanup = @() }
        @{ Case = 'primary-and-cleanup'; HasPrimary = $true; Cleanup = @('cleanup could not be verified') }
        @{ Case = 'cleanup-only'; HasPrimary = $false; Cleanup = @('cleanup could not be verified') }
        @{ Case = 'success'; HasPrimary = $false; Cleanup = @() }
    ) {
        $definition = $script:SqlContract.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object Name -EQ 'Get-WorkshopBootstrapFailure' | Select-Object -First 1
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))
        $primary = if ($HasPrimary) {
            try { throw [InvalidOperationException]::new('readiness evidence was rejected') } catch { $_ }
        }

        $failure = Get-WorkshopBootstrapFailure -PrimaryError $primary -CleanupErrors $Cleanup

        switch ($Case) {
            'primary-only' {
                $failure | Should -BeOfType ([System.Management.Automation.ErrorRecord])
                $failure.Exception.Message | Should -BeExactly 'readiness evidence was rejected'
            }
            'primary-and-cleanup' {
                $failure.Message | Should -Match 'readiness evidence was rejected'
                $failure.Message | Should -Match 'Cleanup also failed'
                $failure.InnerException.Message | Should -BeExactly 'readiness evidence was rejected'
            }
            'cleanup-only' {
                $failure.Message | Should -Match 'task body succeeded, but cleanup could not be proven'
                $failure.InnerException | Should -BeNullOrEmpty
            }
            'success' { $failure | Should -BeNullOrEmpty }
        }
    }

    It 'accepts only Boolean true readiness for the exact canonical deployment identifier' -ForEach @(
        @{ Case = 'matching'; Json = '{"Completed":true,"DeploymentId":"11111111-2222-3333-4444-555555555555"}'; Throws = $false }
        @{ Case = 'lowercase property'; Json = '{"Completed":true,"deploymentId":"11111111-2222-3333-4444-555555555555"}'; Throws = $false }
        @{ Case = 'mismatch'; Json = '{"Completed":true,"DeploymentId":"99999999-2222-3333-4444-555555555555"}'; Throws = $true }
        @{ Case = 'string true'; Json = '{"Completed":"true","DeploymentId":"11111111-2222-3333-4444-555555555555"}'; Throws = $true }
        @{ Case = 'malformed'; Json = '{not-json'; Throws = $true }
    ) {
        $function = $script:SqlContract.Ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Read-WorkshopBootstrapReadiness'
        }, $true)
        $function | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($function.Extent.Text))
        $path = Join-Path $TestDrive "$Case.json"
        Set-Content -LiteralPath $path -Value $Json -Encoding UTF8
        $operation = { Read-WorkshopBootstrapReadiness -Path $path `
            -ExpectedDeploymentId '11111111-2222-3333-4444-555555555555' }
        if ($Throws) { $operation | Should -Throw }
        else { (& $operation).DeploymentId | Should -BeExactly '11111111-2222-3333-4444-555555555555' }
    }

    It 'passes the protected payload deployment identifier to the administrator bootstrap' {
        $text = $script:SqlContract.Text
        $text | Should -Match 'Invoke-WorkshopAdministratorBootstrap[\s\S]*-ExpectedDeploymentId\s+\(\[string\]\s*\$payload\.DeploymentId\)'
        $text | Should -Match 'DeploymentId\s*=\s*\[string\]\$payload\.DeploymentId'
        $text | Should -Match '\[System\.IO\.InvalidDataException\]'
    }

    It 'transfers only the SQL public certificate through injected admin operations' {
        $script:CapturedAdminPayload = $null
        $publicBytes = [byte[]](1, 2, 3, 4)
        $operations = @{
            GetSubscriptionId = { '11111111-1111-1111-1111-111111111111' }
            AcquireDeploymentLock = { [pscustomobject]@{ Acquired = $true } }
            ReleaseDeploymentLock = { param($Lease) $null = $Lease }
            GetRecipientCertificate = { 'public-recipient-certificate' }
            ProtectPayload = {
                param($Recipient, $Payload)
                $null = $Recipient
                $script:CapturedAdminPayload = $Payload | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                'encrypted-cms-envelope'
            }
            StageBootstrapFiles = {
                param($VmName, $ResourceGroupName, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit)
                $null = $VmName, $ResourceGroupName, $BootstrapScript, $RepositoryCommit
                $ProtectedEnvelope | Should -Be 'encrypted-cms-envelope'
            }
            SetExtension = {
                param($VmName, $ResourceGroupName, $Location, $ArchiveUri, $ProtectedEnvelope, $BootstrapScript, $RepositoryCommit)
                $null = $VmName, $ResourceGroupName, $Location, $ArchiveUri, $BootstrapScript, $RepositoryCommit
                $ProtectedEnvelope | Should -Be 'encrypted-cms-envelope'
            }
            GetExtension = { [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/succeeded' }) } }
            ReadReadiness = { [pscustomobject]@{ Completed = $true; DeploymentId = '11111111-2222-3333-4444-555555555555' } }
            ReadPublicCertificate = { [Convert]::ToBase64String($publicBytes) }.GetNewClosure()
        }
        $sqlReadiness = [pscustomobject]@{
            Completed = $true
            Certificate = [pscustomobject]@{ PublicCertificatePath = 'C:\McpSqlWorkshop\public\sql01.cer'; PublicCertificateSha256 = ('B' * 64); Thumbprint = ('A' * 40) }
        }
        $result = Initialize-WorkshopAdminVm -Config $script:BootstrapConfig -McpReaderPassword $script:SecureValue `
            -RepositoryUrl 'https://github.com/ibranibeny/mcp-sql-query-store-workshop.git' `
            -RepositoryCommit '0123456789abcdef0123456789abcdef01234567' `
            -DeploymentId '11111111-2222-3333-4444-555555555555' `
            -InteractiveUserName 'workshop-admin' `
            -WindowsClientLicenseAttested $true `
            -SqlReadiness $sqlReadiness -Operations $operations

        $result.Completed | Should -BeTrue
        $script:CapturedAdminPayload.RepositoryRoot | Should -BeExactly 'C:\McpSqlWorkshop\workspace'
        $script:CapturedAdminPayload.PublicCertificateBase64 | Should -Be ([Convert]::ToBase64String($publicBytes))
        $script:CapturedAdminPayload.PSObject.Properties.Name | Should -Not -Contain 'PrivateKey'
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match 'unit-test-secret-value'
    }

    It 'passes only a complete exact pair and labels attested unknown activation as a warning' {
        $pair = Get-CompleteReadinessPair
        $result = Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin
        $result.Passed | Should -BeTrue
        @($result.Checks | Where-Object Status -EQ 'Warning').Name | Should -Contain 'Administration activation observation'
    }

    It 'fails closed for every missing or wrong required security fact' -ForEach @(
        @{ Path = 'Sql.Vm.Name'; Value = 'wrong' },
        @{ Path = 'Sql.Disks'; Value = @() },
        @{ Path = 'Sql.TempDb.OldPathCount'; Value = 1 },
        @{ Path = 'Sql.Certificate.RegistryCertificate'; Value = $null },
        @{ Path = 'Sql.Certificate.TlsLoadFailures'; Value = 1 },
        @{ Path = 'Sql.Database.ProcedureCount'; Value = 8 },
        @{ Path = 'Admin.Vm.PublicIpCount'; Value = 0 },
        @{ Path = 'Admin.Workspace.WorkspaceUserModify'; Value = $false },
        @{ Path = 'Admin.RootEnvAcl.Restricted'; Value = $false },
        @{ Path = 'Admin.RootEnvAcl.EnvAclRestricted'; Value = $false },
        @{ Path = 'Admin.Auth.GitHubCliAuthStatus'; Value = $null },
        @{ Path = 'Admin.SqlTls.CertificateValidated'; Value = $false },
        @{ Path = 'Admin.SqlTls.ValidationMethod'; Value = 'generic' },
        @{ Path = 'Admin.Mcp.ForbiddenMutationTools'; Value = $true },
        @{ Path = 'Admin.DeploymentId'; Value = '99999999-2222-3333-4444-555555555555' },
        @{ Path = 'Admin.Repository.Commit'; Value = 'ffffffffffffffffffffffffffffffffffffffff' }
    ) {
        $pair = Get-CompleteReadinessPair
        $segments = $Path -split '\.'
        $target = $pair
        foreach ($segment in $segments[0..($segments.Count - 2)]) { $target = $target.$segment }
        $target.($segments[-1]) = $Value
        (Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin).Passed |
            Should -BeFalse -Because $Path
    }

    It 'fails closed rather than throwing when required records are absent' {
        { $script:Result = Test-WorkshopReadiness -SqlReadiness ([pscustomobject]@{}) -AdminReadiness ([pscustomobject]@{}) } |
            Should -Not -Throw
        $script:Result.Passed | Should -BeFalse
    }

    It 'fails closed without throwing for malformed DAB versions and deployment identifiers' {
        $pair = Get-CompleteReadinessPair
        $pair.Admin.Tools.DAB = 'not-a-version'
        { $script:MalformedVersionResult = Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin } |
            Should -Not -Throw
        $script:MalformedVersionResult.Passed | Should -BeFalse

        $pair = Get-CompleteReadinessPair
        $pair.Sql.DeploymentId = '------------------------------------'
        $pair.Admin.DeploymentId = '------------------------------------'
        (Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin).Passed | Should -BeFalse
    }

    It 'requires a validated readiness result before deployment evidence is exported' {
        $pair = Get-CompleteReadinessPair
        $output = Join-Path $TestDrive 'missing-validation'

        $command = Get-Command Export-WorkshopDeploymentEvidence
        $parameterAttribute = $command.Parameters['ReadinessResult'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $parameterAttribute.Mandatory | Should -Contain $true

        { Export-WorkshopDeploymentEvidence -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin `
            -ReadinessResult $null -OutputDirectory $output } | Should -Throw '*ReadinessResult*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'exports canonical source hashes from a valid readiness result without exporting secrets' {
        $pair = Get-CompleteReadinessPair
        $readiness = Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin
        $output = Join-Path $TestDrive 'valid-evidence'

        $result = Export-WorkshopDeploymentEvidence -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin `
            -ReadinessResult $readiness -OutputDirectory $output

        $result.Completed | Should -BeTrue
        $result.SqlReadinessSha256 | Should -Match '^[A-F0-9]{64}$'
        $result.AdminReadinessSha256 | Should -Match '^[A-F0-9]{64}$'
        $result.SqlReadinessSha256 | Should -BeExactly $readiness.SourceHashes.SqlReadinessSha256
        $result.AdminReadinessSha256 | Should -BeExactly $readiness.SourceHashes.AdminReadinessSha256
        $rendered = (Get-Content -LiteralPath $result.HtmlPath -Raw) +
            (Get-Content -LiteralPath $result.MarkdownPath -Raw)
        $rendered | Should -Match ([regex]::Escape($readiness.SourceHashes.SqlReadinessSha256))
        $rendered | Should -Match ([regex]::Escape($readiness.SourceHashes.AdminReadinessSha256))
        $rendered | Should -Not -Match 'unit-test-secret-value|Password|PrivateKey'
    }

    It 'rejects forged completion and sanitization flags before creating output' {
        $deploymentId = '11111111-2222-3333-4444-555555555555'
        $forgedSql = [pscustomobject]@{
            SchemaVersion = '1.0'; DeploymentId = $deploymentId; Completed = $true
            Evidence = [pscustomobject]@{ Sanitized = $true }
        }
        $forgedAdmin = [pscustomobject]@{
            SchemaVersion = '1.0'; DeploymentId = $deploymentId; Completed = $true
            Evidence = [pscustomobject]@{ Sanitized = $true }
        }
        $forgedResult = [pscustomobject]@{ Passed = $true; Checks = @(); SourceHashes = [pscustomobject]@{
            SqlReadinessSha256 = 'A' * 64; AdminReadinessSha256 = 'B' * 64
        } }
        $output = Join-Path $TestDrive 'forged-flags'

        { Export-WorkshopDeploymentEvidence -SqlReadiness $forgedSql -AdminReadiness $forgedAdmin `
            -ReadinessResult $forgedResult -OutputDirectory $output } | Should -Throw '*validated readiness result*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects a tampered readiness check or source hash before creating output' -ForEach @(
        @{ Case = 'check status'; Tamper = { param($r) $r.Checks[0].Status = 'Failed' } }
        @{ Case = 'SQL source hash'; Tamper = { param($r) $r.SourceHashes | Add-Member -NotePropertyName SqlReadinessSha256 -NotePropertyValue ('0' * 64) -Force } }
        @{ Case = 'admin source hash'; Tamper = { param($r) $r.SourceHashes | Add-Member -NotePropertyName AdminReadinessSha256 -NotePropertyValue ('0' * 64) -Force } }
    ) {
        $pair = Get-CompleteReadinessPair
        $readiness = Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin
        & $Tamper $readiness
        $output = Join-Path $TestDrive "tampered-result-$Case"

        { Export-WorkshopDeploymentEvidence -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin `
            -ReadinessResult $readiness -OutputDirectory $output } | Should -Throw '*validated readiness result*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects source-record security and identity tampering after validation before creating output' -ForEach @(
        @{ Case = 'security field'; Path = 'Admin.RootEnvAcl.Restricted'; Value = $false }
        @{ Case = 'deployment binding'; Path = 'Admin.DeploymentId'; Value = '99999999-2222-3333-4444-555555555555' }
        @{ Case = 'commit binding'; Path = 'Admin.Repository.Commit'; Value = 'ffffffffffffffffffffffffffffffffffffffff' }
        @{ Case = 'certificate binding'; Path = 'Admin.SqlTls.CertificateThumbprint'; Value = 'F' * 40 }
    ) {
        $pair = Get-CompleteReadinessPair
        $readiness = Test-WorkshopReadiness -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin
        $segments = $Path -split '\.'
        $target = $pair
        foreach ($segment in $segments[0..($segments.Count - 2)]) { $target = $target.$segment }
        $target.($segments[-1]) = $Value
        $output = Join-Path $TestDrive "tampered-source-$Case"

        { Export-WorkshopDeploymentEvidence -SqlReadiness $pair.Sql -AdminReadiness $pair.Admin `
            -ReadinessResult $readiness -OutputDirectory $output } | Should -Throw '*validated readiness result*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
}
