[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ProtectedPayloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'Administration bootstrap requires PowerShell 7.4 or later.'
}
if ($env:MCP_SQL_ADMIN_BOOTSTRAP_PWSH -cne '1') {
    throw 'Administration bootstrap must be launched by the guarded PowerShell 7 bootstrap wrapper.'
}

$metadataUri = 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
$privateDnsName = 'sql01.mcpworkshop.internal'
$expectedSqlIp = '10.20.2.10'
$readinessPath = 'C:\McpSqlWorkshop\evidence\admin-vm-readiness.json'
$evidenceDirectory = Split-Path $readinessPath
$transcriptPath = Join-Path $evidenceDirectory 'admin-bootstrap-transcript.log'
$transcriptStarted = $false
$packageIds = @(
    'Microsoft.PowerShell',
    'Microsoft.VisualStudioCode',
    'Microsoft.SQLServerManagementStudio',
    'Microsoft.DotNet.SDK.9',
    'Git.Git',
    'GitHub.cli'
)
$minimumPackageVersions = @{
    'Microsoft.PowerShell' = [version]'7.4'
    'Microsoft.VisualStudioCode' = [version]'1.0'
    'Microsoft.SQLServerManagementStudio' = [version]'22.7'
    'Microsoft.DotNet.SDK.9' = [version]'9.0'
    'Git.Git' = [version]'2.0'
    'GitHub.cli' = [version]'2.0'
}
$extensionIds = @('ms-mssql.mssql', 'GitHub.copilot', 'GitHub.copilot-chat', 'ms-vscode.powershell')
$genericTools = @('describe_entities', 'read_records', 'execute_entity', 'aggregate_records')
$customTools = @(
    'get_memory_snapshot', 'get_active_workshop_grants', 'get_query_store_top_queries',
    'get_query_store_waits', 'get_procedure_plan_summary', 'compare_workshop_runs'
)
$forbiddenTools = @('create-record', 'create_records', 'update-record', 'update_records', 'delete-record', 'delete_records')

function Assert-Condition {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-NativeChecked {
    param([Parameter(Mandatory)][string] $FilePath, [Parameter(Mandatory)][string[]] $ArgumentList)
    $output = @(& $FilePath @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Required command failed: $FilePath. Corporate network policy may be blocking an official endpoint."
    }
    @($output | ForEach-Object { [string] $_ })
}

function Get-GitHubCliAuthStatus {
    param(
        [AllowNull()][string] $GitHubCliPath,
        [scriptblock] $CommandInvoker = {
            param($FilePath, $Arguments)
            $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    )
    if ([string]::IsNullOrWhiteSpace($GitHubCliPath)) {
        return [pscustomobject]@{ Status = 'Unavailable' }
    }
    try {
        $result = & $CommandInvoker $GitHubCliPath @('auth', 'status')
        # Deliberately discard output: authentication diagnostics can contain account details.
        $status = if ([int]$result.ExitCode -eq 0) { 'Authenticated' } else { 'NotAuthenticated' }
        [pscustomobject]@{ Status = $status }
    }
    catch {
        [pscustomobject]@{ Status = 'Unavailable' }
    }
}

function Protect-WorkshopFileAcl {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier] $InteractiveUserSid
    )
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($InteractiveUserSid, 'Read', 'Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Resolve-WorkshopLocalUser {
    param([Parameter(Mandatory)][string] $UserName)
    Assert-Condition ($UserName -match '^[A-Za-z0-9._-]+$') 'Interactive administration username is invalid.'
    $localUser = Get-LocalUser -Name $UserName -ErrorAction Stop
    Assert-Condition $localUser.Enabled 'Interactive administration local account is disabled.'
    $sid = [Security.Principal.SecurityIdentifier]::new([string]$localUser.SID)
    [pscustomobject]@{
        Name = $localUser.Name
        Sid = $sid
        Account = $sid.Translate([Security.Principal.NTAccount]).Value
    }
}

function Grant-WorkshopWorkspaceModify {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier] $InteractiveUserSid
    )
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $InteractiveUserSid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
    ))
    Set-Acl -LiteralPath $Path -AclObject $acl

    $readback = Get-Acl -LiteralPath $Path
    $rules = @($readback.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $userRules = @($rules | Where-Object {
        $_.IdentityReference -eq $InteractiveUserSid -and $_.AccessControlType -eq 'Allow'
    })
    $modifyRule = @($userRules | Where-Object {
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -eq
            [Security.AccessControl.FileSystemRights]::Modify -and
        ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
            [Security.AccessControl.FileSystemRights]::FullControl -and
        ($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0 -and
        ($_.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit) -ne 0
    })
    $requiredOwnerRules = @('S-1-5-18', 'S-1-5-32-544') | ForEach-Object {
        $requiredSid = [Security.Principal.SecurityIdentifier]::new($_)
        @($rules | Where-Object {
            $_.IdentityReference -eq $requiredSid -and $_.AccessControlType -eq 'Allow'
        }).Count -gt 0
    }
    $modifyRule.Count -eq 1 -and $userRules.Count -eq 1 -and $requiredOwnerRules -notcontains $false
}

function Test-WorkshopEnvAcl {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][Security.Principal.SecurityIdentifier] $InteractiveUserSid
    )
    $acl = Get-Acl -LiteralPath $Path
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544', $InteractiveUserSid.Value)
    $userRules = @($rules | Where-Object { $_.IdentityReference -eq $InteractiveUserSid })
    $userReadOnly = $userRules.Count -eq 1 -and
        ($userRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read) -eq
            [Security.AccessControl.FileSystemRights]::Read -and
        ($userRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -eq 0 -and
        ($userRules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -ne
            [Security.AccessControl.FileSystemRights]::Modify
    $acl.AreAccessRulesProtected -and $rules.Count -eq 3 -and $userReadOnly -and
        @($rules | Where-Object {
            $_.AccessControlType -ne 'Allow' -or $_.IdentityReference.Value -notin $allowedSids
        }).Count -eq 0
}

function Resolve-WorkshopExecutable {
    param([Parameter(Mandatory)][string] $Name, [string[]] $Candidates = @())
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath, $env:Path) -join ';'
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    $candidate = @($Candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    Assert-Condition ($candidate.Count -eq 1) "Required executable '$Name' is unavailable."
    $candidate[0]
}

function Protect-WorkshopDirectoryAcl {
    param([Parameter(Mandatory)][string] $Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        ))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function ConvertTo-SecureValue {
    param([Parameter(Mandatory)][string] $Value)
    $secure = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    $secure
}

function Resolve-DabSqlClientProvider {
    param([Parameter(Mandatory)][string] $PackageRoot)

    $builderType = 'Microsoft.Data.SqlClient.SqlConnectionStringBuilder' -as [type]
    $connectionType = 'Microsoft.Data.SqlClient.SqlConnection' -as [type]
    if ($null -eq $builderType -or $null -eq $connectionType) {
        $dabPackagePath = Join-Path $PackageRoot 'microsoft.dataapibuilder\2.0.9'
        $assemblyPath = Get-ChildItem -LiteralPath $dabPackagePath -Filter 'Microsoft.Data.SqlClient.dll' `
            -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($assemblyPath)) `
            'The DAB Microsoft.Data.SqlClient assembly is unavailable after tool restore.'
        Add-Type -LiteralPath $assemblyPath -ErrorAction Stop
        $builderType = 'Microsoft.Data.SqlClient.SqlConnectionStringBuilder' -as [type]
        $connectionType = 'Microsoft.Data.SqlClient.SqlConnection' -as [type]
    }
    Assert-Condition ($null -ne $builderType -and $null -ne $connectionType) `
        'The DAB Microsoft.Data.SqlClient types could not be loaded.'
    [pscustomobject]@{ Builder = $builderType; Connection = $connectionType }
}

function ConvertTo-DabMssqlConnectionString {
    param(
        [Parameter(Mandatory)][type] $BuilderType,
        [Parameter(Mandatory)][string] $DataSource,
        [Parameter(Mandatory)][string] $Database,
        [Parameter(Mandatory)][string] $UserId,
        [Parameter(Mandatory)][securestring] $ReaderSecret,
        [Parameter(Mandatory)][string] $HostNameInCertificate,
        [Parameter(Mandatory)][string] $ApplicationName
    )

    $builder = [Activator]::CreateInstance($BuilderType)
    $builder.DataSource = $DataSource
    $builder.InitialCatalog = $Database
    $builder.UserID = $UserId
    $secretPointer = [IntPtr]::Zero
    try {
        $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ReaderSecret)
        $builder.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
    }
    finally {
        if ($secretPointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
        }
    }
    $builder.Encrypt = $true
    $builder.TrustServerCertificate = $false
    $builder.ApplicationName = $ApplicationName
    if ($null -ne $BuilderType.GetProperty('HostNameInCertificate')) {
        $builder.HostNameInCertificate = $HostNameInCertificate
        return $builder.ConnectionString
    }

    # System.Data.SqlClient does not know this DAB/Microsoft.Data key. Only the fixed,
    # validated nonsecret key is appended; the password was already escaped by its builder.
    return '{0};HostNameInCertificate={1}' -f $builder.ConnectionString.TrimEnd(';'), $HostNameInCertificate
}

function Read-DabMssqlEnvironment {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][type] $BuilderType,
        [Parameter(Mandatory)][string] $ExpectedDataSource,
        [Parameter(Mandatory)][string] $ExpectedUserId,
        [Parameter(Mandatory)][string] $ExpectedHostNameInCertificate,
        [Parameter(Mandatory)][string] $ExpectedApplicationName
    )

    $prefix = 'MSSQL_CONNECTION_STRING='
    $environmentText = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).TrimEnd("`r", "`n")
    if (-not $environmentText.StartsWith($prefix, [StringComparison]::Ordinal) -or
        $environmentText.Substring($prefix.Length) -match "[`r`n]") {
        throw 'Root .env must contain exactly one MSSQL_CONNECTION_STRING assignment.'
    }
    $builder = [Activator]::CreateInstance(
        $BuilderType,
        [object[]]@($environmentText.Substring($prefix.Length))
    )
    $encryptEnabled = [string]$builder['Encrypt'] -match '^(?i:true|mandatory)$'
    $trustServerCertificate = [Convert]::ToBoolean([string]$builder['TrustServerCertificate'])
    if ([string]$builder.DataSource -cne $ExpectedDataSource) { throw 'DAB SQL data source readback is incorrect.' }
    if (-not $encryptEnabled) { throw 'DAB SQL encryption readback is not enabled.' }
    if ($trustServerCertificate) { throw 'DAB SQL certificate validation readback is disabled.' }
    if ([string]$builder.HostNameInCertificate -cne $ExpectedHostNameInCertificate) { throw 'DAB SQL certificate hostname readback is incorrect.' }
    if ([string]$builder.UserID -cne $ExpectedUserId) { throw 'DAB SQL user readback is incorrect.' }
    if ([string]::IsNullOrEmpty([string]$builder.Password)) { throw 'DAB SQL password readback is empty.' }
    if ([string]$builder.ApplicationName -cne $ExpectedApplicationName) { throw 'DAB SQL application name readback is incorrect.' }

    [pscustomobject]@{
        DataSource = [string]$builder.DataSource
        Encrypt = $encryptEnabled
        TrustServerCertificate = $trustServerCertificate
        HostNameInCertificate = [string]$builder.HostNameInCertificate
        UserId = [string]$builder.UserID
        PasswordPresent = -not [string]::IsNullOrEmpty([string]$builder.Password)
        ApplicationName = [string]$builder.ApplicationName
        Builder = $builder
    }
}

function Invoke-McpAllowlistProbe {
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Resolve-WorkshopExecutable -Name 'dotnet.exe' -Candidates @('C:\Program Files\dotnet\dotnet.exe'))
    $startInfo.WorkingDirectory = $RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $escapedConfig = (Join-Path $RepositoryRoot 'mcp\dab-config.json').Replace('"', '\"')
    $startInfo.Arguments = "tool run dab -- start --mcp-stdio role:workshop-reader --config `"$escapedConfig`" --LogLevel error"
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    Assert-Condition ($process.Start()) 'DAB MCP process could not be started.'
    $readTask = $null
    $errorTask = $process.StandardError.ReadToEndAsync()
    try {
        $requests = @(
            @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'workshop-readiness'; version = '1.0' } } },
            @{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{} },
            @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} }
        )
        foreach ($request in $requests) {
            $json = $request | ConvertTo-Json -Depth 10 -Compress
            $process.StandardInput.WriteLine($json)
            $process.StandardInput.Flush()
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $responses = [System.Collections.Generic.List[object]]::new()
        $readTask = $process.StandardOutput.ReadLineAsync()
        while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
            if (-not $readTask.Wait(1000)) { continue }
            $line = $readTask.Result
            $readTask = $process.StandardOutput.ReadLineAsync()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $responses.Add(($line | ConvertFrom-Json)) } catch { continue }
            if ($responses | Where-Object id -EQ 2) { break }
        }
        $toolResponse = $responses | Where-Object id -EQ 2 | Select-Object -First 1
        Assert-Condition ($null -ne $toolResponse) 'MCP tools/list did not return before the bounded deadline.'
        $names = @($toolResponse.result.tools.name | Sort-Object -Unique)
        foreach ($name in @($genericTools + $customTools)) {
            Assert-Condition ($names -contains $name) "MCP tool allowlist is missing '$name'."
        }
        foreach ($name in $forbiddenTools) {
            Assert-Condition ($names -notcontains $name) "Forbidden MCP mutation tool '$name' was exposed."
        }
        Assert-Condition ($names.Count -eq ($genericTools.Count + $customTools.Count)) 'MCP tools/list exposed unexpected tools outside the exact allowlist.'
        $names
    }
    finally {
        if (-not $process.HasExited) { $process.Kill() }
        $null = $process.WaitForExit(5000)
        if ($null -ne $readTask -and -not $readTask.IsCompleted) { $null = $readTask.Wait(5000) }
        if (-not $errorTask.IsCompleted) { $null = $errorTask.Wait(5000) }
        $process.Dispose()
    }
}

Assert-Condition (Test-Path -LiteralPath $ProtectedPayloadPath -PathType Leaf) 'Protected bootstrap payload is unavailable.'
$payloadAcl = Get-Acl -LiteralPath $ProtectedPayloadPath
$unexpectedReaders = @($payloadAcl.Access | Where-Object {
    $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')
})
Assert-Condition ($unexpectedReaders.Count -eq 0) 'Protected bootstrap payload ACL is broader than Administrators and SYSTEM.'
$protectedPayload = Get-Content -LiteralPath $ProtectedPayloadPath -Raw
$payload = Unprotect-CmsMessage -Content $protectedPayload | ConvertFrom-Json
$protectedPayload = $null

try {
    $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    Protect-WorkshopDirectoryAcl -Path $evidenceDirectory
    $null = Start-Transcript -LiteralPath $transcriptPath -Force
    $transcriptStarted = $true
    $metadata = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $metadataUri -TimeoutSec 10
    Assert-Condition ($metadata.compute.name -ceq $payload.ExpectedVmName) 'IMDS VM identity does not match.'
    Assert-Condition ($metadata.compute.vmSize -ceq $payload.ExpectedVmSize) 'IMDS VM size does not match.'
    Assert-Condition ($metadata.compute.location -ieq $payload.ExpectedLocation) 'IMDS VM location does not match.'
    $imdsPublicIps = @($metadata.network.interface.ipv4.ipAddress.publicIpAddress | Where-Object { $_ })
    Assert-Condition ($imdsPublicIps.Count -eq 1) 'Administration VM IMDS public IP boundary is not exactly one address.'

    $os = Get-CimInstance Win32_OperatingSystem
    Assert-Condition ($os.Caption -match 'Windows 11 Enterprise') 'Windows 11 Enterprise is required.'
    Assert-Condition ([version]$os.Version -ge [version]'10.0.26100') 'Windows 11 Enterprise 24H2 (build 26100 or later) is required.'
    Assert-Condition ([bool](Confirm-SecureBootUEFI)) 'Secure Boot is not enabled.'
    $tpm = Get-Tpm
    Assert-Condition ($tpm.TpmPresent -and $tpm.TpmReady) 'A ready vTPM is required.'
    $null = Get-CimInstance Win32_Tpm -Namespace root\CIMV2\Security\MicrosoftTpm -ErrorAction Stop
    $license = Get-CimInstance SoftwareLicensingProduct -Filter "Name LIKE 'Windows%Enterprise%' AND PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue |
        Sort-Object LicenseStatus -Descending | Select-Object -First 1
    $activationStatus = if ($null -eq $license) { 'Unavailable' } elseif ([int]$license.LicenseStatus -eq 1) { 'Licensed' } else { 'Unknown' }
    if ($activationStatus -ne 'Licensed') { $activationStatus = 'ObservedUnknown' }

    $packageVersions = [ordered]@{}
    $wingetPath = Resolve-WorkshopExecutable -Name 'winget.exe' -Candidates @(
        Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | ForEach-Object FullName
    )
    foreach ($id in $packageIds) {
        $null = Invoke-NativeChecked -FilePath $wingetPath -ArgumentList @(
            'install', '--id', $id, '--exact', '--silent', '--disable-interactivity',
            '--accept-package-agreements', '--accept-source-agreements', '--source', 'winget'
        )
        $listOutput = (Invoke-NativeChecked -FilePath $wingetPath -ArgumentList @('list', '--id', $id, '--exact', '--source', 'winget')) -join ' '
        $packageLine = @($listOutput -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($id) } | Select-Object -Last 1)[0]
        $versionMatches = [regex]::Matches([string]$packageLine, '(?<!\d)(\d+\.\d+(?:\.\d+){0,2})(?!\d)')
        Assert-Condition ($versionMatches.Count -ge 1) "Installed version for '$id' could not be read back."
        $installedVersion = [version]$versionMatches[0].Groups[1].Value
        Assert-Condition ($installedVersion -ge $minimumPackageVersions[$id]) "Installed version for '$id' is below the approved minimum."
        $packageVersions[$id] = $installedVersion.ToString()
    }

    $repositoryRoot = [string] $payload.RepositoryRoot
    $gitPath = Resolve-WorkshopExecutable -Name 'git.exe' -Candidates @('C:\Program Files\Git\cmd\git.exe')
    $dotnetPath = Resolve-WorkshopExecutable -Name 'dotnet.exe' -Candidates @('C:\Program Files\dotnet\dotnet.exe')
    $codePath = Resolve-WorkshopExecutable -Name 'code.cmd' -Candidates @('C:\Program Files\Microsoft VS Code\bin\code.cmd')
    $ghPath = Resolve-WorkshopExecutable -Name 'gh.exe' -Candidates @('C:\Program Files\GitHub CLI\gh.exe')
    $githubCliAuthStatus = (Get-GitHubCliAuthStatus -GitHubCliPath $ghPath).Status
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git'))) {
        $null = Invoke-NativeChecked -FilePath $gitPath -ArgumentList @('clone', '--no-checkout', '--', [string]$payload.RepositoryUrl, $repositoryRoot)
    }
    $null = Invoke-NativeChecked -FilePath $gitPath -ArgumentList @('-C', $repositoryRoot, 'fetch', '--depth', '1', 'origin', [string]$payload.RepositoryCommit)
    $null = Invoke-NativeChecked -FilePath $gitPath -ArgumentList @('-C', $repositoryRoot, 'checkout', '--detach', [string]$payload.RepositoryCommit)
    $head = (Invoke-NativeChecked -FilePath $gitPath -ArgumentList @('-C', $repositoryRoot, 'rev-parse', 'HEAD'))[-1].Trim()
    Assert-Condition ($head -ceq [string]$payload.RepositoryCommit) 'Repository HEAD does not match the protected immutable commit.'

    $interactiveUser = Resolve-WorkshopLocalUser -UserName ([string]$payload.InteractiveUserName)
    $workspaceUserModify = Grant-WorkshopWorkspaceModify -Path $repositoryRoot `
        -InteractiveUserSid $interactiveUser.Sid
    Assert-Condition $workspaceUserModify 'Interactive administration user does not have inherited Modify access to the workshop workspace.'
    $extensionDirectory = "C:\Users\$($interactiveUser.Name)\.vscode\extensions"
    $null = New-Item -ItemType Directory -Path $extensionDirectory -Force
    foreach ($extensionId in $extensionIds) {
        $null = Invoke-NativeChecked -FilePath $codePath -ArgumentList @('--extensions-dir', $extensionDirectory, '--install-extension', $extensionId, '--force')
    }
    $extensionVersions = @(Invoke-NativeChecked -FilePath $codePath -ArgumentList @('--extensions-dir', $extensionDirectory, '--list-extensions', '--show-versions'))
    foreach ($extensionId in $extensionIds) {
        Assert-Condition ($extensionVersions -match "^$([regex]::Escape($extensionId))@") "VS Code extension '$extensionId' version could not be read back."
    }

    $env:NUGET_PACKAGES = if ([string]::IsNullOrWhiteSpace([string]$payload.NugetPackagesPath)) {
        Join-Path $repositoryRoot '.packages'
    } else { [string]$payload.NugetPackagesPath }
    $restoreArguments = @('tool', 'restore')
    if ([string]::IsNullOrWhiteSpace([string]$payload.NugetConfigPath)) {
        $payload.NugetConfigPath = Join-Path $repositoryRoot 'NuGet.Config'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$payload.NugetConfigPath)) {
        $restoreArguments += @('--configfile', [string]$payload.NugetConfigPath)
    }
    Push-Location $repositoryRoot
    try {
        $null = Invoke-NativeChecked -FilePath $dotnetPath -ArgumentList $restoreArguments
        $dabVersion = (Invoke-NativeChecked -FilePath $dotnetPath -ArgumentList @('tool', 'run', 'dab', '--version')) -join ' '
        Assert-Condition ($dabVersion -match '2\.0\.9') 'Pinned DAB version 2.0.9 was not restored.'
    }
    finally { Pop-Location }

    $certificatePath = Join-Path $env:TEMP 'sql01-public.cer'
    [IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String([string]$payload.PublicCertificateBase64))
    $certificateHash = (Get-FileHash -LiteralPath $certificatePath -Algorithm SHA256).Hash
    Assert-Condition ($certificateHash -ceq [string]$payload.PublicCertificateSha256) 'Public certificate SHA-256 does not match the SQL readiness evidence.'
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
    $certificateThumbprint = ([string]$certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    Assert-Condition ($certificateThumbprint -ceq [string]$payload.CertificateThumbprint) 'Public certificate thumbprint does not match the SQL readiness evidence.'
    Assert-Condition (-not $certificate.HasPrivateKey) 'Only the SQL public certificate may be transferred.'
    $null = Import-Certificate -FilePath $certificatePath -CertStoreLocation Cert:\LocalMachine\Root
    Remove-Item -LiteralPath $certificatePath -Force

    $dns = @(Resolve-DnsName $privateDnsName -Type A -ErrorAction Stop)
    Assert-Condition ($dns.IPAddress -contains $expectedSqlIp) 'Private DNS did not resolve to the approved SQL address.'
    $tcp = Test-NetConnection $privateDnsName -Port 1433 -WarningAction SilentlyContinue
    Assert-Condition ($tcp.TcpTestSucceeded) 'Private SQL TCP 1433 connectivity failed.'

    $envPath = Join-Path $repositoryRoot '.env'
    $sqlClientTypes = Resolve-DabSqlClientProvider -PackageRoot $env:NUGET_PACKAGES
    $mcpReaderSecret = ConvertTo-SecureValue -Value ([string]$payload.McpReaderSecret)
    $connectionText = ConvertTo-DabMssqlConnectionString -BuilderType $sqlClientTypes.Builder `
        -DataSource $privateDnsName -Database 'AdventureWorks2022' -UserId 'mcp_workshop_reader' `
        -ReaderSecret $mcpReaderSecret `
        -HostNameInCertificate 'sql01.mcpworkshop.internal' -ApplicationName 'MCP-SQL-Workshop-MCP'
    [IO.File]::WriteAllText($envPath, "MSSQL_CONNECTION_STRING=$connectionText`r`n", [Text.UTF8Encoding]::new($false))
    Protect-WorkshopFileAcl -Path $envPath -InteractiveUserSid $interactiveUser.Sid
    $rootEnvAclRestricted = Test-WorkshopEnvAcl -Path $envPath -InteractiveUserSid $interactiveUser.Sid
    Assert-Condition $rootEnvAclRestricted 'Root .env ACL readback is broader than the approved identities.'
    $parsedEnvironment = Read-DabMssqlEnvironment -Path $envPath -BuilderType $sqlClientTypes.Builder `
        -ExpectedDataSource $privateDnsName -ExpectedUserId 'mcp_workshop_reader' `
        -ExpectedHostNameInCertificate 'sql01.mcpworkshop.internal' `
        -ExpectedApplicationName 'MCP-SQL-Workshop-MCP'
    $env:MSSQL_CONNECTION_STRING = $parsedEnvironment.Builder.ConnectionString

    $connection = [Activator]::CreateInstance(
        $sqlClientTypes.Connection,
        [object[]]@($parsedEnvironment.Builder.ConnectionString)
    )
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID;'
        $encrypted = [string] $command.ExecuteScalar()
        $command.Dispose()
        Assert-Condition ($encrypted -ceq 'TRUE') 'SQL connection did not negotiate encrypted TDS.'
    }
    finally {
        $connection.Dispose()
        $parsedEnvironment.Builder.Clear()
    }

    Push-Location $repositoryRoot
    try {
        $null = Invoke-NativeChecked -FilePath $dotnetPath -ArgumentList @('tool', 'run', 'dab', '--', 'validate', '--config', (Join-Path $repositoryRoot 'mcp\dab-config.json'))
        $toolNames = @(Invoke-McpAllowlistProbe -RepositoryRoot $repositoryRoot)
    }
    finally { Pop-Location }

    $toolVersions = [ordered]@{
        VisualStudioCode = ((Invoke-NativeChecked -FilePath $codePath -ArgumentList @('--version'))[0])
        DotNet = ((Invoke-NativeChecked -FilePath $dotnetPath -ArgumentList @('--version'))[0])
        Git = ((Invoke-NativeChecked -FilePath $gitPath -ArgumentList @('--version')) -join ' ')
        GitHubCli = ((Invoke-NativeChecked -FilePath $ghPath -ArgumentList @('--version'))[0])
        DAB = $dabVersion
        WingetPackages = @($packageIds | ForEach-Object { [ordered]@{ Id = $_; VersionReadback = $packageVersions[$_] } })
        Extensions = $extensionVersions
    }
    $readiness = [ordered]@{
        Completed = $true
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        SchemaVersion = '1.0'
        DeploymentId = [string]$payload.DeploymentId
        Evidence = [ordered]@{ Sanitized = $true }
        Vm = [ordered]@{ Name = $metadata.compute.name; Size = $metadata.compute.vmSize; Location = $metadata.compute.location; AdminPublicIpBoundaryObserved = $true; PublicIpCount = $imdsPublicIps.Count; SecureBoot = $true; Tpm = $true; Os = $os.Caption; Build = $os.BuildNumber; Activation = $activationStatus; WindowsClientLicenseAttested = [bool]$payload.WindowsClientLicenseAttested }
        Repository = [ordered]@{ Commit = $head }
        Workspace = [ordered]@{ User = $interactiveUser.Account; WorkspaceUserModify = $workspaceUserModify }
        Tools = $toolVersions
        RootEnvAcl = [ordered]@{ Path = $envPath; Restricted = $rootEnvAclRestricted; EnvAclRestricted = $rootEnvAclRestricted }
        Auth = [ordered]@{ GitHubCliAuthStatus = $githubCliAuthStatus; CopilotAuthStatus = 'InteractiveSignInRequired' }
        Network = [ordered]@{ DnsName = $privateDnsName; ResolvedAddress = $expectedSqlIp; Tcp1433 = $true }
        SqlTls = [ordered]@{ DnsName = $parsedEnvironment.DataSource; Address = $expectedSqlIp; Tcp1433 = $true; CertificateThumbprint = $certificateThumbprint; PublicCertificateSha256 = $certificateHash; CertificateValidated = $true; ValidationMethod = 'SqlClientChainHostAndTransferredCertificate'; EncryptOption = $encrypted; Encrypt = $parsedEnvironment.Encrypt; TrustServerCertificate = $parsedEnvironment.TrustServerCertificate; HostNameInCertificate = $parsedEnvironment.HostNameInCertificate; UserId = $parsedEnvironment.UserId; PasswordPresent = $parsedEnvironment.PasswordPresent; ApplicationName = $parsedEnvironment.ApplicationName; ClientProvider = $sqlClientTypes.Builder.Namespace; RemoteAdminTest = $true }
        Mcp = [ordered]@{ ConfigValid = $true; DabMinimumVersionMet = ([version]([regex]::Match($dabVersion, '\d+\.\d+\.\d+').Value) -ge [version]'2.0.9'); ToolNames = $toolNames; ForbiddenMutationTools = $false }
    }
    $readiness | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $readinessPath -Encoding UTF8
    $readiness
}
finally {
    if ($transcriptStarted) {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $transcriptPath) {
            $transcript = Get-Content -LiteralPath $transcriptPath -Raw
            if (-not [string]::IsNullOrEmpty([string]$payload.McpReaderSecret)) {
                $transcript = $transcript -replace [regex]::Escape([string]$payload.McpReaderSecret), '[REDACTED]'
            }
            $transcript = [regex]::Replace($transcript, '(?i)(password|pwd|secret|token|sas)\s*[=:]\s*[^;\s]+', '$1=[REDACTED]')
            Set-Content -LiteralPath $transcriptPath -Value $transcript -Encoding UTF8
        }
    }
    $env:MSSQL_CONNECTION_STRING = $null
    if ($null -ne $payload) { $payload.McpReaderSecret = $null }
    Remove-Item -LiteralPath $ProtectedPayloadPath -Force -ErrorAction SilentlyContinue
}
