[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ProtectedPayloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$metadataUri = 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
$privateDnsName = 'sql01.mcpworkshop.internal'
$adminSubnet = '10.20.1.0/24'
$root = 'C:\McpSqlWorkshop'
$evidenceDirectory = Join-Path $root 'evidence'
$readinessPath = 'C:\McpSqlWorkshop\evidence\sql-vm-readiness.json'
$publicCertificatePath = Join-Path $root 'public\sql01.cer'
$transcriptPath = Join-Path $evidenceDirectory 'sql-bootstrap-transcript.log'
$transcriptStarted = $false
$backupUri = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak'
$orderedScripts = @(
    '00-Preflight.sql', '01-ConfigureInstance.sql', '02-RestoreAndConfigureDatabase.sql',
    '03-CreateScaledLabData.sql', '04-CreateBaselineProcedure.sql', '05-CreateDiagnostics.sql',
    '06-CreateOptimizedProcedure.sql', '07-ValidateEquivalence.sql'
)

function Assert-Condition {
    param([Parameter(Mandatory)][bool] $Condition, [Parameter(Mandatory)][string] $Message)
    if (-not $Condition) { throw $Message }
}

function ConvertTo-SecureValue {
    param([Parameter(Mandatory)][string] $Value)
    $secure = [Security.SecureString]::new()
    foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    $secure
}

function Invoke-LocalSqlScalar {
    param([Parameter(Mandatory)][string] $Query, [string] $Database = 'master', [switch] $BootstrapTrust)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder.DataSource = if ($BootstrapTrust) { 'localhost' } else { $privateDnsName }
    $builder.InitialCatalog = $Database
    $builder.IntegratedSecurity = $true
    $builder.Encrypt = $true
    $builder.TrustServerCertificate = $BootstrapTrust.IsPresent
    $builder.ApplicationName = 'MCP-SQL-Workshop-Bootstrap'
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $command = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 120
        $command.ExecuteScalar()
    }
    finally {
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
        $builder.Clear()
    }
}

function Get-SqlService {
    $services = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL%'" |
        Where-Object { $_.Name -notmatch 'Launcher|FDLauncher' })
    Assert-Condition ($services.Count -eq 1) 'Exactly one SQL Server database engine service is required.'
    $services[0]
}

function Test-FirewallPortCoverage {
    param([AllowNull()][object[]] $Ranges, [Parameter(Mandatory)][int] $Port)
    foreach ($rangeValue in @($Ranges)) {
        $range = [string]$rangeValue
        if ($range -in @('Any', '*', [string]$Port)) { return $true }
        if ($range -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) {
            return $true
        }
    }
    $false
}

function Mount-WorkshopDisk {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)][int] $Lun,
        [Parameter(Mandatory)][int] $ExpectedSizeGiB,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][char] $PreferredDriveLetter
    )
    $candidates = @(Get-Disk | Where-Object {
        $location = [string] $_.Location
        ($_.PSObject.Properties.Name -contains 'Lun' -and [int] $_.Lun -eq $Lun) -or
        $location -match "LUN\s*$Lun(?:\D|$)"
    })
    Assert-Condition ($candidates.Count -eq 1) "Expected exactly one attached disk at LUN $Lun."
    $disk = $candidates[0]
    $actualGiB = [math]::Round([double] $disk.Size / 1GB)
    Assert-Condition ($actualGiB -eq $ExpectedSizeGiB) "Disk at LUN $Lun does not match the expected size."
    if ($disk.PartitionStyle -eq 'RAW') {
        if (-not $PSCmdlet.ShouldProcess("Disk $($disk.Number) at LUN $Lun", 'Initialize GPT and format NTFS with a 64 KiB allocation unit')) {
            throw "Disk initialization was declined for LUN $Lun."
        }
        $disk = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru
        $letter = $PreferredDriveLetter
        if (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue) {
            $approved = @([char]([int]$PreferredDriveLetter + 2), [char]([int]$PreferredDriveLetter + 3))
            $letter = @($approved | Where-Object { -not (Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) })[0]
            Assert-Condition ($null -ne $letter) "No approved drive letter is available for LUN $Lun."
        }
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $letter
        $null = Format-Volume -Partition $partition -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel $Label -Confirm:$false
    }
    else {
        Assert-Condition ($disk.PartitionStyle -eq 'GPT') "LUN $Lun is initialized with a conflicting partition style."
    }
    $partitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter)
    Assert-Condition ($partitions.Count -eq 1) "LUN $Lun has an ambiguous partition layout."
    $volume = Get-Volume -DriveLetter $partitions[0].DriveLetter
    Assert-Condition ($volume.FileSystemType -eq 'NTFS') "LUN $Lun is not NTFS."
    Assert-Condition ([int64] $volume.AllocationUnitSize -eq 65536) "LUN $Lun does not use a 64 KiB allocation unit."
    Assert-Condition ($volume.FileSystemLabel -ceq $Label) "LUN $Lun has an unexpected volume label."
    [pscustomobject]@{ Lun = $Lun; Drive = "$($partitions[0].DriveLetter):"; Label = $Label; AllocationUnitSize = 65536; SizeGiB = $actualGiB }
}

function Protect-WorkshopDirectoryAcl {
    param([Parameter(Mandatory)][string] $Path)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
    function Grant-SqlServiceDirectoryAccess {
        param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Identity)
        $acl = Get-Acl -LiteralPath $Path
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $Identity, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
        $readback = Get-Acl -LiteralPath $Path
        Assert-Condition ($null -ne ($readback.Access | Where-Object {
            $_.IdentityReference.Value -eq $Identity -and $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify
        } | Select-Object -First 1)) "SQL service directory access was not verified for '$Path'."
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
    $metadata = Invoke-RestMethod -Headers @{ Metadata = 'true' } -Method Get -Uri $metadataUri -TimeoutSec 10
    Assert-Condition ($metadata.compute.name -ceq $payload.ExpectedVmName) 'IMDS VM identity does not match.'
    Assert-Condition ($metadata.compute.vmSize -ceq $payload.ExpectedVmSize) 'IMDS VM size does not match.'
    Assert-Condition ($metadata.compute.location -ceq $payload.ExpectedLocation) 'IMDS VM location does not match.'
    foreach ($interface in @($metadata.network.interface)) {
        foreach ($address in @($interface.ipv4.ipAddress)) {
            Assert-Condition ([string]::IsNullOrWhiteSpace([string] $address.publicIpAddress)) 'SQL VM must not have a public IP.'
        }
    }

    Assert-Condition ([bool](Confirm-SecureBootUEFI)) 'Secure Boot is not enabled.'
    $tpm = Get-Tpm
    Assert-Condition ($tpm.TpmPresent -and $tpm.TpmReady) 'A ready vTPM is required.'
    $null = Get-CimInstance Win32_Tpm -Namespace root\CIMV2\Security\MicrosoftTpm -ErrorAction Stop
    $os = Get-CimInstance Win32_OperatingSystem
    Assert-Condition ($os.Caption -match 'Windows Server 2022') 'Windows Server 2022 is required.'

    $service = Get-SqlService
    Assert-Condition ($service.State -eq 'Running') 'SQL Server service is not running.'
    $major = Invoke-LocalSqlScalar "SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));" -BootstrapTrust
    $edition = [string](Invoke-LocalSqlScalar "SELECT CONVERT(nvarchar(128), SERVERPROPERTY('Edition'));" -BootstrapTrust)
    Assert-Condition ([int] $major -eq 16 -and $edition -match 'Enterprise') 'SQL Server 2022 Enterprise is required.'

    $dataDisk = Mount-WorkshopDisk -Lun 0 -ExpectedSizeGiB ([int]$payload.DataDiskGiB) -Label SQLData -PreferredDriveLetter F -Confirm:$false
    $logDisk = Mount-WorkshopDisk -Lun 1 -ExpectedSizeGiB ([int]$payload.LogDiskGiB) -Label SQLLog -PreferredDriveLetter G -Confirm:$false
    $dataPath = Join-Path $dataDisk.Drive 'SQLData'
    $logPath = Join-Path $logDisk.Drive 'SQLLog'
    $backupPath = Join-Path $dataDisk.Drive 'Backup\AdventureWorks2022.bak'
    foreach ($path in @($root, $evidenceDirectory, (Split-Path $publicCertificatePath), $dataPath, $logPath, (Split-Path $backupPath))) {
        $null = New-Item -ItemType Directory -Path $path -Force
    }
    Protect-WorkshopDirectoryAcl -Path $evidenceDirectory
    $null = Start-Transcript -LiteralPath $transcriptPath -Force
    $transcriptStarted = $true

    $resourceMarker = 'D:\DATALOSS_WARNING_README.txt'
    $tempDbPath = if (Test-Path -LiteralPath $resourceMarker) { 'D:\SQLTempDB' } else { Join-Path $dataDisk.Drive 'SQLTempDB' }
    $tempDbDeviation = if (Test-Path -LiteralPath $resourceMarker) { $null } else { 'Azure temporary disk marker unavailable; TempDB placed on managed data disk.' }
    $null = New-Item -ItemType Directory -Path $tempDbPath -Force
    foreach ($sqlPath in @($dataPath, $logPath, (Split-Path $backupPath), $tempDbPath)) {
        Grant-SqlServiceDirectoryAccess -Path $sqlPath -Identity $service.StartName
    }

    $instanceName = if ($service.Name -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { $service.Name.Substring(6) }
    $instanceMap = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    $instanceId = [string] $instanceMap.$instanceName
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($instanceId)) 'SQL instance registry identity could not be resolved.'
    $instanceRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
    $tcpRoot = Join-Path $instanceRoot 'SuperSocketNetLib'
    $ipAll = Join-Path $tcpRoot 'Tcp\IPAll'
    Set-ItemProperty -Path $ipAll -Name TcpDynamicPorts -Value ''
    Set-ItemProperty -Path $ipAll -Name TcpPort -Value '1433'
    Set-ItemProperty -Path $instanceRoot -Name DefaultData -Value $dataPath
    Set-ItemProperty -Path $instanceRoot -Name DefaultLog -Value $logPath
    Set-Service -Name SQLBrowser -StartupType Disabled
    Stop-Service -Name SQLBrowser -Force -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayName 'MCP SQL Workshop 1433' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    $activeProfiles = @((Get-NetConnectionProfile).NetworkCategory | Sort-Object -Unique)
    Assert-Condition ($activeProfiles.Count -gt 0) 'Active Windows Firewall profile could not be determined.'
    $null = New-NetFirewallRule -DisplayName 'MCP SQL Workshop 1433' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress $adminSubnet -Profile $activeProfiles
    $broadSqlRules = @(Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | ForEach-Object {
        $rule = $_
        $port = $rule | Get-NetFirewallPortFilter
        $address = $rule | Get-NetFirewallAddressFilter
        $coversSql = ($port.Protocol -in @('TCP', 'Any') -and (Test-FirewallPortCoverage -Ranges @($port.LocalPort) -Port 1433)) -or
            ($port.Protocol -in @('UDP', 'Any') -and (Test-FirewallPortCoverage -Ranges @($port.LocalPort) -Port 1434))
        $isBroad = @($address.RemoteAddress) | Where-Object { $_ -in @('Any', '*', '0.0.0.0/0', 'Internet') }
        if ($coversSql -and $isBroad) { $rule }
    })
    Assert-Condition ($broadSqlRules.Count -eq 0) 'A broad inbound SQL firewall rule was detected.'

    $certificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $candidate = $_
        $sanExtension = $candidate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        $san = if ($null -eq $sanExtension) { '' } else { [string]$sanExtension.Format($false) }
        $usage = $candidate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | Select-Object -First 1
        $key = if ($candidate.HasPrivateKey) { [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($candidate) } else { $null }
        $candidate.Subject -ceq "CN=$privateDnsName" -and $candidate.NotAfter -gt (Get-Date).AddDays(30) -and
            $san -match "DNS Name=$([regex]::Escape($privateDnsName))" -and
            $null -ne $usage -and $usage.EnhancedKeyUsages.Value -contains '1.3.6.1.5.5.7.3.1' -and
            $key -is [Security.Cryptography.RSACng] -and $key.Key.ExportPolicy -notmatch 'AllowExport'
    } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($null -eq $certificate) {
        $certificate = New-SelfSignedCertificate -DnsName $privateDnsName -CertStoreLocation Cert:\LocalMachine\My `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable `
            -NotAfter (Get-Date).AddYears(1) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1')
    }
    Assert-Condition $certificate.HasPrivateKey 'SQL TLS certificate has no private key.'
    $eku = $certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | Select-Object -First 1
    Assert-Condition ($null -ne $eku -and $eku.EnhancedKeyUsages.Value -contains '1.3.6.1.5.5.7.3.1') 'SQL TLS certificate lacks Server Authentication EKU.'
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
    Assert-Condition ($rsa -is [Security.Cryptography.RSACng]) 'SQL TLS private key must use the non-exportable CNG provider.'
    Assert-Condition ($rsa.Key.ExportPolicy -notmatch 'AllowExport') 'SQL TLS private key is exportable.'
    $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($rsa.Key.UniqueName)"
    $keyAcl = Get-Acl -LiteralPath $keyPath
    $keyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($service.StartName, 'Read', 'Allow'))
    Set-Acl -LiteralPath $keyPath -AclObject $keyAcl
    $keyAclReadback = Get-Acl -LiteralPath $keyPath
    Assert-Condition ($null -ne ($keyAclReadback.Access | Where-Object {
        $_.IdentityReference.Value -eq $service.StartName -and $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read
    } | Select-Object -First 1)) 'SQL service account private-key read ACL was not verified.'
    $null = Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force
    $null = Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation Cert:\LocalMachine\Root
    Set-ItemProperty -Path $tcpRoot -Name Certificate -Value ($certificate.Thumbprint.ToLowerInvariant())
    Set-ItemProperty -Path $tcpRoot -Name ForceEncryption -Value 1

    $tempDbFiles = @(
        @{ Name = 'tempdev'; File = Join-Path $tempDbPath 'tempdb.mdf' },
        @{ Name = 'templog'; File = Join-Path $tempDbPath 'templog.ldf' }
    )
    foreach ($tempDbFile in $tempDbFiles) {
        $escapedFile = ([string]$tempDbFile.File).Replace("'", "''")
        $null = Invoke-LocalSqlScalar -Query "ALTER DATABASE tempdb MODIFY FILE (NAME = N'$($tempDbFile.Name)', FILENAME = N'$escapedFile');" -BootstrapTrust
    }

    Restart-Service -Name $service.Name -Force
    $restarted = Get-Service -Name $service.Name
    Assert-Condition ($restarted.Status -eq 'Running') 'SQL service failed its restart checkpoint.'
    Assert-Condition ((Get-ItemPropertyValue -Path $ipAll -Name TcpPort) -ceq '1433') 'SQL TCP 1433 readback failed.'
    Assert-Condition ([int](Get-ItemPropertyValue -Path $tcpRoot -Name ForceEncryption) -eq 1) 'SQL ForceEncryption readback failed.'
    $errorLog = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server' -Filter ERRORLOG -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    Assert-Condition ($null -ne $errorLog -and (Select-String -LiteralPath $errorLog.FullName -Pattern 'certificate' -Quiet)) 'SQL error log does not confirm certificate startup.'
    $tempDbPathCount = [int](Invoke-LocalSqlScalar -Query "SELECT COUNT(*) FROM tempdb.sys.database_files WHERE physical_name LIKE N'$($tempDbPath.Replace("'", "''"))%';")
    Assert-Condition ($tempDbPathCount -eq 2) 'TempDB file paths were not active after the SQL restart checkpoint.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Invoke-WebRequest -Uri $backupUri -OutFile $backupPath -UseBasicParsing
    }
    $backupHash = (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash
    Assert-Condition ($backupHash -match '^[A-F0-9]{64}$') 'Backup SHA256 could not be observed.'

    $verifyCommand = "RESTORE VERIFYONLY FROM DISK = N'$($backupPath.Replace("'", "''"))' WITH CHECKSUM;"
    $null = Invoke-LocalSqlScalar -Query $verifyCommand

    $databaseMasterKey = ConvertTo-SecureValue -Value ([string] $payload.DatabaseMasterKeySecret)
    $mcpReader = ConvertTo-SecureValue -Value ([string] $payload.McpReaderSecret)
    $connectionText = "Data Source=$privateDnsName;Initial Catalog=master;Integrated Security=True;Encrypt=True;TrustServerCertificate=False;Application Name=MCP-SQL-Workshop-Setup;"
    $secureConnection = ConvertTo-SecureValue -Value $connectionText
    $runner = Join-Path $payload.RepositoryRoot 'deploy\Invoke-WorkshopSqlScripts.ps1'
    foreach ($scriptName in $orderedScripts) {
        Assert-Condition (Test-Path -LiteralPath (Join-Path $payload.RepositoryRoot "sql\$scriptName")) "Required SQL script is missing: $scriptName"
    }
    & $runner -SqlConnectionString $secureConnection -ExpectedServerName $privateDnsName -BackupPath $backupPath `
        -DataPath $dataPath -LogPath $logPath -DatabaseMasterKeyPassword $databaseMasterKey `
        -McpReaderPassword $mcpReader -SqlDirectory (Join-Path $payload.RepositoryRoot 'sql')

    $databaseMarker = [string](Invoke-LocalSqlScalar "SELECT TOP (1) CONVERT(nvarchar(36), MarkerId) FROM AdventureWorks2022.lab.WorkshopMarker;")
    $queryStoreState = [string](Invoke-LocalSqlScalar "SELECT actual_state_desc FROM AdventureWorks2022.sys.database_query_store_options;")
    $resourceGovernorState = [string](Invoke-LocalSqlScalar "SELECT CASE WHEN is_enabled = 1 THEN 'Enabled' ELSE 'Disabled' END FROM sys.resource_governor_configuration;")
    $procedureCount = [int](Invoke-LocalSqlScalar "SELECT COUNT(*) FROM AdventureWorks2022.sys.procedures WHERE schema_id = SCHEMA_ID(N'lab');")
    $priorMaxServerMemory = [int](Invoke-LocalSqlScalar "SELECT MaxServerMemoryMB FROM WorkshopAdmin.dbo.ConfigurationBackup WHERE MarkerId = '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C' AND SchemaVersion = 1;")
    $tdsEncryption = [string](Invoke-LocalSqlScalar 'SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID;')
    Assert-Condition ($databaseMarker -ceq '68A70D6E-62D8-4A77-8F0A-9DA7934DBA7C') 'Workshop database marker readback failed.'
    Assert-Condition ($queryStoreState -ceq 'READ_WRITE') 'Query Store is not READ_WRITE.'
    Assert-Condition ($resourceGovernorState -ceq 'Enabled') 'Resource Governor is not enabled.'
    Assert-Condition ($procedureCount -eq 8) 'The exact lab stored-procedure count was not verified.'
    Assert-Condition ($priorMaxServerMemory -gt 0) 'Prior max server memory was not retained.'
    Assert-Condition ($tdsEncryption -ceq 'TRUE') 'Validated private-DNS SQL connection was not encrypted.'

    $readiness = [ordered]@{
        Completed = $true
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Vm = [ordered]@{ Name = $metadata.compute.name; Size = $metadata.compute.vmSize; Location = $metadata.compute.location; PublicIp = $false; SecureBoot = $true; Tpm = $true }
        Sql = [ordered]@{ Version = 16; Edition = $edition; Service = $service.Name; State = 'Running'; Port = 1433; Encryption = 'Forced'; EncryptOption = $tdsEncryption }
        Disks = @($dataDisk, $logDisk)
        TempDb = [ordered]@{ Path = $tempDbPath; PersistentDataOnTemporaryDisk = $false; Deviation = $tempDbDeviation }
        Firewall = [ordered]@{ Rule = 'MCP SQL Workshop 1433'; RemoteAddress = $adminSubnet; BroadRule = $false }
        Certificate = [ordered]@{ DnsName = $privateDnsName; ThumbprintSha256 = ([BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($certificate.Thumbprint)))).Replace('-', '')); PublicCertificateSha256 = (Get-FileHash -LiteralPath $publicCertificatePath -Algorithm SHA256).Hash; PublicCertificatePath = $publicCertificatePath; PrivateKeyExported = $false }
        Backup = [ordered]@{ Uri = $backupUri; Sha256 = $backupHash; ChecksumClassification = 'observed-not-upstream-expected'; VerifyOnly = $true }
        Database = [ordered]@{ Marker = $databaseMarker; QueryStore = $queryStoreState; ResourceGovernor = $resourceGovernorState; ProcedureCount = $procedureCount; PriorMaxServerMemoryMB = $priorMaxServerMemory }
    }
    $readiness | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $readinessPath -Encoding UTF8
    Protect-WorkshopDirectoryAcl -Path $evidenceDirectory
    $readiness
}
finally {
    if ($transcriptStarted) {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $transcriptPath) {
            $transcript = Get-Content -LiteralPath $transcriptPath -Raw
            foreach ($secretValue in @($payload.DatabaseMasterKeySecret, $payload.McpReaderSecret)) {
                if (-not [string]::IsNullOrEmpty([string]$secretValue)) {
                    $transcript = $transcript -replace [regex]::Escape([string]$secretValue), '[REDACTED]'
                }
            }
            $transcript = [regex]::Replace($transcript, '(?i)(password|pwd|secret|token|sas)\s*[=:]\s*[^;\s]+', '$1=[REDACTED]')
            Set-Content -LiteralPath $transcriptPath -Value $transcript -Encoding UTF8
        }
    }
    if ($null -ne $payload) {
        $payload.DatabaseMasterKeySecret = $null
        $payload.McpReaderSecret = $null
    }
    Remove-Item -LiteralPath $ProtectedPayloadPath -Force -ErrorAction SilentlyContinue
}
