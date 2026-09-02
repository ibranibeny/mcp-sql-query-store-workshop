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
    '03-CreateScaledLabData.sql', '04-CreateBaselineProcedure.sql', '05-CreateDiagnostics.sql'
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

function Get-VerifiedAdventureWorksBackup {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSha256,
        [scriptblock] $DownloadOperation = {
            param($SourceUri, $OutFile)
            Invoke-WebRequest -Uri $SourceUri -OutFile $OutFile -UseBasicParsing
        },
        [scriptblock] $HashOperation = {
            param($LiteralPath, $Algorithm)
            Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
        }
    )
    if ($Uri -cne 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak') {
        throw 'AdventureWorks backup URI is not approved.'
    }
    if ($ExpectedSha256 -notmatch '^[A-F0-9]{64}$') {
        throw 'AdventureWorks expected SHA256 is invalid.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        & $DownloadOperation $Uri $Path
    }
    $actualSha256 = [string] (& $HashOperation $Path 'SHA256').Hash
    if ($actualSha256 -cne $ExpectedSha256) {
        throw 'AdventureWorks backup SHA256 does not match the reviewed expected digest.'
    }
    $actualSha256
}

function Invoke-LocalSqlScalar {
    param([Parameter(Mandatory)][string] $Query, [string] $Database = 'master', [switch] $BootstrapTrust)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = if ($BootstrapTrust) { 'localhost' } else { $privateDnsName }
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $BootstrapTrust.IsPresent
    $builder['Application Name'] = 'MCP-SQL-Workshop-Bootstrap'
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

function Invoke-LocalSqlQuery {
    param([Parameter(Mandatory)][string] $Query, [string] $Database = 'master', [switch] $BootstrapTrust)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = if ($BootstrapTrust) { 'localhost' } else { $privateDnsName }
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $BootstrapTrust.IsPresent
    $builder['Application Name'] = 'MCP-SQL-Workshop-Bootstrap'
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $command = $null
    $reader = $null
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 120
        $reader = $command.ExecuteReader()
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($index = 0; $index -lt $reader.FieldCount; $index++) {
                $row[$reader.GetName($index)] = $reader.GetValue($index)
            }
            $rows.Add([pscustomobject]$row)
        }
        $rows.ToArray()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        $connection.Dispose()
        $builder.Clear()
    }
}

function Get-SqlService {
    $services = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'MSSQL%'" |
        Where-Object { $_.PathName -match '(?i)\\sqlservr\.exe(?:"|\s)' })
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
        [Parameter(Mandatory)][char] $PreferredDriveLetter,
        [switch] $PreflightOnly
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

    # Inspect both views before any mutation. F and G are part of the deployment contract, not preferences.
    $assignedVolume = Get-Volume -DriveLetter $PreferredDriveLetter -ErrorAction SilentlyContinue
    $assignedPartition = Get-Partition -DriveLetter $PreferredDriveLetter -ErrorAction SilentlyContinue
    if ($null -ne $assignedVolume -or $null -ne $assignedPartition) {
        Assert-Condition ($null -ne $assignedVolume -and $null -ne $assignedPartition) "Drive $PreferredDriveLetter`: has an incomplete volume assignment."
        Assert-Condition ([int]$assignedPartition.DiskNumber -eq [int]$disk.Number) "Drive $PreferredDriveLetter`: is occupied by a disk other than expected LUN $Lun."
        Assert-Condition ($assignedVolume.FileSystemLabel -ceq $Label) "Drive $PreferredDriveLetter`: has an unexpected label for LUN $Lun."
        Assert-Condition ([math]::Round([double]$assignedVolume.Size / 1GB) -eq $ExpectedSizeGiB) "Drive $PreferredDriveLetter`: has an unexpected size for LUN $Lun."
    }
    if ($PreflightOnly) {
        if ($disk.PartitionStyle -eq 'RAW') {
            Assert-Condition ($null -eq $assignedVolume -and $null -eq $assignedPartition) "Drive $PreferredDriveLetter`: is already occupied; initialization was refused."
        }
        else {
            Assert-Condition ($disk.PartitionStyle -eq 'GPT') "LUN $Lun is initialized with a conflicting partition style."
            Assert-Condition ($null -ne $assignedVolume -and $null -ne $assignedPartition) "Initialized LUN $Lun is not assigned to mandatory drive $PreferredDriveLetter`: ."
            Assert-Condition ($assignedVolume.FileSystemType -eq 'NTFS' -and [int64]$assignedVolume.AllocationUnitSize -eq 65536) "Drive $PreferredDriveLetter`: does not satisfy the NTFS 64 KiB contract."
        }
        return [pscustomobject]@{ Lun = $Lun; Drive = "$PreferredDriveLetter`:"; Label = $Label; AllocationUnitSize = 65536; SizeGiB = $actualGiB }
    }
    if ($disk.PartitionStyle -eq 'RAW') {
        Assert-Condition ($null -eq $assignedVolume -and $null -eq $assignedPartition) "Drive $PreferredDriveLetter`: is already occupied; initialization was refused."
        if (-not $PSCmdlet.ShouldProcess("Disk $($disk.Number) at LUN $Lun", 'Initialize GPT and format NTFS with a 64 KiB allocation unit')) {
            throw "Disk initialization was declined for LUN $Lun."
        }
        $disk = Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $PreferredDriveLetter
        $null = Format-Volume -Partition $partition -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel $Label -Confirm:$false
    }
    else {
        Assert-Condition ($disk.PartitionStyle -eq 'GPT') "LUN $Lun is initialized with a conflicting partition style."
    }
    $partitions = @(Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter)
    Assert-Condition ($partitions.Count -eq 1) "LUN $Lun has an ambiguous partition layout."
    Assert-Condition ([char]$partitions[0].DriveLetter -eq $PreferredDriveLetter) "LUN $Lun is not assigned to mandatory drive $PreferredDriveLetter`: ."
    $volume = Get-Volume -DriveLetter $PreferredDriveLetter
    Assert-Condition ($volume.FileSystemType -eq 'NTFS') "LUN $Lun is not NTFS."
    Assert-Condition ([int64] $volume.AllocationUnitSize -eq 65536) "LUN $Lun does not use a 64 KiB allocation unit."
    Assert-Condition ($volume.FileSystemLabel -ceq $Label) "LUN $Lun has an unexpected volume label."
    [pscustomobject]@{ Lun = $Lun; Drive = "$PreferredDriveLetter`:"; Label = $Label; AllocationUnitSize = 65536; SizeGiB = $actualGiB }
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
    Assert-Condition ($metadata.compute.location -ieq $payload.ExpectedLocation) 'IMDS VM location does not match.'
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

    $null = Mount-WorkshopDisk -Lun 0 -ExpectedSizeGiB ([int]$payload.DataDiskGiB) -Label SQLData -PreferredDriveLetter F -PreflightOnly -Confirm:$false
    $null = Mount-WorkshopDisk -Lun 1 -ExpectedSizeGiB ([int]$payload.LogDiskGiB) -Label SQLLog -PreferredDriveLetter G -PreflightOnly -Confirm:$false
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

    $tempDbFilesBefore = @(Invoke-LocalSqlQuery -Database tempdb -BootstrapTrust -Query @'
SELECT file_id AS FileId, name AS LogicalName, type_desc AS Type, physical_name AS PhysicalName,
       CONVERT(bigint, size) * 8192 AS SizeBytes
FROM tempdb.sys.database_files
ORDER BY file_id;
'@)
    Assert-Condition ($tempDbFilesBefore.Count -ge 2) 'TempDB must expose at least two files before relocation.'
    Assert-Condition (@($tempDbFilesBefore | Where-Object Type -EQ 'ROWS').Count -ge 1) 'TempDB has no ROWS file.'
    Assert-Condition (@($tempDbFilesBefore | Where-Object Type -EQ 'LOG').Count -ge 1) 'TempDB has no LOG file.'
    $requiredTempDbBytes = [int64](($tempDbFilesBefore | Measure-Object -Property SizeBytes -Sum).Sum) + 1GB
    $resourceMarker = 'D:\DATALOSS_WARNING_README.txt'
    $resourceVolume = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    $resourcePartition = Get-Partition -DriveLetter D -ErrorAction SilentlyContinue
    $tempDbUsesResourceDisk = (Test-Path -LiteralPath $resourceMarker) -and
        $null -ne $resourceVolume -and $null -ne $resourcePartition -and
        $resourceVolume.FileSystemType -eq 'NTFS' -and $resourceVolume.HealthStatus -eq 'Healthy' -and
        -not $resourcePartition.IsBoot -and -not $resourcePartition.IsSystem -and
        [int64]$resourceVolume.SizeRemaining -ge $requiredTempDbBytes
    $tempDbPath = if ($tempDbUsesResourceDisk) { 'D:\SQLTempDB' } else { Join-Path $dataDisk.Drive 'SQLTempDB' }
    $tempDbStorage = if ($tempDbUsesResourceDisk) { 'Temporary' } else { 'ManagedData' }
    $tempDbDeviation = if ($tempDbUsesResourceDisk) { $null } else { 'Azure temporary disk failed marker, volume, partition, health, or capacity validation; TempDB placed on managed data disk.' }
    $selectedTempDbVolume = Get-Volume -DriveLetter ([IO.Path]::GetPathRoot($tempDbPath).TrimEnd(':','\'))
    Assert-Condition ([int64]$selectedTempDbVolume.SizeRemaining -ge $requiredTempDbBytes) 'Approved TempDB root does not have enough free space for all current files plus the safety reserve.'
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
    $firewallRuleReadback = Get-NetFirewallRule -DisplayName 'MCP SQL Workshop 1433' -ErrorAction Stop
    $firewallPortReadback = $firewallRuleReadback | Get-NetFirewallPortFilter
    $firewallAddressReadback = $firewallRuleReadback | Get-NetFirewallAddressFilter
    Assert-Condition ($firewallRuleReadback.Enabled -eq 'True' -and $firewallRuleReadback.Direction -eq 'Inbound' -and $firewallRuleReadback.Action -eq 'Allow') 'Workshop SQL firewall rule state readback failed.'
    Assert-Condition ($firewallPortReadback.Protocol -eq 'TCP' -and @($firewallPortReadback.LocalPort) -contains '1433') 'Workshop SQL firewall port readback failed.'
    Assert-Condition (@($firewallAddressReadback.RemoteAddress).Count -eq 1 -and @($firewallAddressReadback.RemoteAddress)[0] -ceq $adminSubnet) 'Workshop SQL firewall source readback is not the exact administration subnet.'
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
    $certificateThumbprint = ([string]$certificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    Assert-Condition ($certificateThumbprint -match '^[A-F0-9]{40}$') 'SQL TLS certificate thumbprint is not a normalized SHA-1 thumbprint.'
    $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$($rsa.Key.UniqueName)"
    $keyAcl = Get-Acl -LiteralPath $keyPath
    $keyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($service.StartName, 'Read', 'Allow'))
    Set-Acl -LiteralPath $keyPath -AclObject $keyAcl
    $keyAclReadback = Get-Acl -LiteralPath $keyPath
    Assert-Condition ($null -ne ($keyAclReadback.Access | Where-Object {
        $_.IdentityReference.Value -eq $service.StartName -and $_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Read
    } | Select-Object -First 1)) 'SQL service account private-key read ACL was not verified.'
    $null = Export-Certificate -Cert $certificate -FilePath $publicCertificatePath -Force
    $publicCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicCertificatePath)
    $publicCertificateThumbprint = ([string]$publicCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()
    Assert-Condition ($publicCertificateThumbprint -ceq $certificateThumbprint) 'Exported public certificate thumbprint does not match the generated SQL certificate.'
    $null = Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation Cert:\LocalMachine\Root
    Set-ItemProperty -Path $tcpRoot -Name Certificate -Value $certificateThumbprint
    Set-ItemProperty -Path $tcpRoot -Name ForceEncryption -Value 1

    foreach ($tempDbFile in $tempDbFilesBefore) {
        $safeLogicalName = ([string]$tempDbFile.LogicalName -replace '[^A-Za-z0-9._-]', '_')
        $extension = if ($tempDbFile.Type -ceq 'LOG') { '.ldf' } elseif ([int]$tempDbFile.FileId -eq 1) { '.mdf' } else { '.ndf' }
        $prefix = if ($tempDbFile.Type -ceq 'LOG') { 'templog' } else { 'tempdb' }
        $targetFile = Join-Path $tempDbPath ("{0}-{1}-{2}{3}" -f $prefix, $tempDbFile.FileId, $safeLogicalName, $extension)
        $escapedLogicalName = ([string]$tempDbFile.LogicalName).Replace("'", "''")
        $quotedLogicalName = [string](Invoke-LocalSqlScalar -Query "SELECT QUOTENAME(N'$escapedLogicalName');" -BootstrapTrust)
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($quotedLogicalName)) "QUOTENAME rejected TempDB logical file '$($tempDbFile.LogicalName)'."
        $escapedFile = $targetFile.Replace("'", "''")
        $null = Invoke-LocalSqlScalar -Query "ALTER DATABASE tempdb MODIFY FILE (NAME = $quotedLogicalName, FILENAME = N'$escapedFile');" -BootstrapTrust
    }

    Restart-Service -Name $service.Name -Force
    $restarted = Get-Service -Name $service.Name
    Assert-Condition ($restarted.Status -eq 'Running') 'SQL service failed its restart checkpoint.'
    $browserService = Get-CimInstance Win32_Service -Filter "Name='SQLBrowser'"
    Assert-Condition ($null -ne $browserService -and $browserService.StartMode -eq 'Disabled' -and $browserService.State -ne 'Running') 'SQL Browser readback is not disabled and stopped.'
    Assert-Condition ((Get-ItemPropertyValue -Path $ipAll -Name TcpPort) -ceq '1433') 'SQL TCP 1433 readback failed.'
    $registryCertificate = ([string](Get-ItemPropertyValue -Path $tcpRoot -Name Certificate) -replace '\s', '').ToUpperInvariant()
    $forceEncryption = [int](Get-ItemPropertyValue -Path $tcpRoot -Name ForceEncryption)
    Assert-Condition ($registryCertificate -ceq $certificateThumbprint) 'SQL certificate registry readback does not match the generated certificate thumbprint.'
    Assert-Condition ($forceEncryption -eq 1) 'SQL ForceEncryption readback failed.'
    $storeCertificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$certificateThumbprint" -ErrorAction Stop
    Assert-Condition (([string]$storeCertificate.Thumbprint -replace '\s', '').ToUpperInvariant() -ceq $certificateThumbprint -and $storeCertificate.HasPrivateKey) 'SQL certificate store readback failed.'
    $errorLogDirectory = [string](Get-ItemPropertyValue -Path $instanceRoot -Name ErrorLogPath -ErrorAction Stop)
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($errorLogDirectory)) 'SQL instance ErrorLogPath registry readback is empty.'
    $errorLogPath = Join-Path $errorLogDirectory 'ERRORLOG'
    Assert-Condition (Test-Path -LiteralPath $errorLogPath -PathType Leaf) 'Exact SQL instance error log was not found after restart.'
    $errorLogText = Get-Content -LiteralPath $errorLogPath -Raw
    $tlsLoadFailures = @([regex]::Matches($errorLogText, '(?im)^.*(?:(?:failed|failure|could not|unable|not).*(?:load|initialize).*(?:certificate|TLS)|(?:certificate|TLS).*(?:failed|failure|could not|unable|not).*(?:load|initialize)).*$')).Count
    Assert-Condition ($tlsLoadFailures -eq 0) 'SQL error log reports a TLS certificate load failure.'
    $normalizedErrorLog = $errorLogText -replace '\s', ''
    $startupBindingEvidence = if ($normalizedErrorLog -match [regex]::Escape($certificateThumbprint) -and
        $errorLogText -match '(?i)certificate.*(?:successfully loaded|loaded successfully)') { 'ExactThumbprint' } else { 'DeferredRemoteValidation' }
    $tempDbFilesAfter = @(Invoke-LocalSqlQuery -Database tempdb -Query @'
SELECT file_id AS FileId, name AS LogicalName, type_desc AS Type, physical_name AS PhysicalName
FROM tempdb.sys.database_files
ORDER BY file_id;
'@)
    $approvedTempDbPrefix = $tempDbPath.TrimEnd('\') + '\'
    $oldTempDbPaths = @($tempDbFilesAfter | Where-Object { -not ([string]$_.PhysicalName).StartsWith($approvedTempDbPrefix, [StringComparison]::OrdinalIgnoreCase) })
    Assert-Condition ($tempDbFilesAfter.Count -ge 2) 'TempDB exposes fewer than two files after restart.'
    Assert-Condition ($tempDbFilesAfter.Count -eq $tempDbFilesBefore.Count) 'TempDB file count changed during relocation.'
    Assert-Condition ($oldTempDbPaths.Count -eq 0) 'One or more TempDB files remain outside the approved root.'

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Assert-Condition ([string]$payload.AdventureWorksBackupUri -ceq $backupUri) 'Protected payload backup URI is not approved.'
    $backupHash = Get-VerifiedAdventureWorksBackup -Uri $backupUri -Path $backupPath `
        -ExpectedSha256 ([string]$payload.AdventureWorksBackupSha256)

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
    Assert-Condition ($procedureCount -eq 7) 'The exact pre-candidate lab stored-procedure count was not verified.'
    Assert-Condition ($priorMaxServerMemory -gt 0) 'Prior max server memory was not retained.'
    Assert-Condition ($tdsEncryption -ceq 'TRUE') 'Validated private-DNS SQL connection was not encrypted.'

    $readiness = [ordered]@{
        Completed = $true
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        SchemaVersion = '1.0'
        DeploymentId = [string]$payload.DeploymentId
        Evidence = [ordered]@{ Sanitized = $true }
        Repository = [ordered]@{ Commit = [string]$payload.RepositoryCommit }
        Vm = [ordered]@{ Name = $metadata.compute.name; Size = $metadata.compute.vmSize; Location = $metadata.compute.location; PublicIp = $false; SecureBoot = $true; Tpm = $true }
        Sql = [ordered]@{ Version = 16; Edition = $edition; Service = $service.Name; State = [string]$restarted.Status; Port = 1433; BrowserStartupType = [string]$browserService.StartMode; Encryption = 'Forced'; EncryptOption = $tdsEncryption }
        Disks = @($dataDisk, $logDisk)
        TempDb = [ordered]@{ ApprovedRoot = $tempDbPath; Storage = $tempDbStorage; PersistentDataOnTemporaryDisk = $false; Deviation = $tempDbDeviation; EnoughSpace = $true; FileCount = $tempDbFilesAfter.Count; AllFilesUnderApprovedRoot = $true; OldPathCount = $oldTempDbPaths.Count; Files = $tempDbFilesAfter }
        Firewall = [ordered]@{ Rule = [string]$firewallRuleReadback.DisplayName; RemoteAddress = [string]@($firewallAddressReadback.RemoteAddress)[0]; BroadRule = ($broadSqlRules.Count -ne 0) }
        Certificate = [ordered]@{ DnsName = $privateDnsName; Thumbprint = $certificateThumbprint; RegistryCertificate = $registryCertificate; StoreThumbprint = (([string]$storeCertificate.Thumbprint -replace '\s', '').ToUpperInvariant()); ForceEncryption = $forceEncryption; HasPrivateKey = [bool]$storeCertificate.HasPrivateKey; ServerAuthenticationEku = $true; SanVerified = $true; ServiceKeyAclVerified = $true; PublicCertificateThumbprint = $publicCertificateThumbprint; PublicCertificateSha256 = (Get-FileHash -LiteralPath $publicCertificatePath -Algorithm SHA256).Hash; PublicCertificatePath = $publicCertificatePath; PrivateKeyExported = $false; TlsLoadFailures = $tlsLoadFailures; StartupBindingEvidence = $startupBindingEvidence }
        Backup = [ordered]@{ Uri = $backupUri; Sha256 = $backupHash; ExpectedSha256 = [string]$payload.AdventureWorksBackupSha256; ChecksumClassification = 'expected-verified'; VerifyOnly = $true }
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
