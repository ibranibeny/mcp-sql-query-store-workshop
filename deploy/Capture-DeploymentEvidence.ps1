[CmdletBinding()]
param(
    [Parameter(Mandatory)][psobject] $SqlReadiness,
    [Parameter(Mandatory)][psobject] $AdminReadiness,
    [Parameter(Mandatory)][psobject] $ReadinessResult,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-RedactedEvidenceText {
    param([AllowNull()][object] $Value)
    $text = [string] $Value
    $text = [regex]::Replace($text, '(?i)(password|pwd|secret|token|sas)\s*[=:]\s*[^;\s<]+', '$1=[REDACTED]')
    $text = [regex]::Replace($text, '(?i)(public\s*ip|publicIpAddress)\s*[=:]\s*\d{1,3}(?:\.\d{1,3}){3}', '$1=[REDACTED]')
    $text
}

function Get-EvidencePropertyValue {
    param([AllowNull()][object] $Record, [Parameter(Mandatory)][string] $Name)
    if ($null -eq $Record) { return $null }
    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

$readinessCommand = Get-Command Test-WorkshopReadiness -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $readinessCommand) {
    Import-Module (Join-Path $PSScriptRoot 'Workshop.Azure.psd1') -ErrorAction Stop
    $readinessCommand = Get-Command Test-WorkshopReadiness -CommandType Function -ErrorAction Stop
}
$verifiedReadiness = & $readinessCommand -SqlReadiness $SqlReadiness -AdminReadiness $AdminReadiness
$providedChecks = @(Get-EvidencePropertyValue $ReadinessResult 'Checks')
$verifiedChecks = @($verifiedReadiness.Checks)
$checksMatch = $providedChecks.Count -eq $verifiedChecks.Count
if ($checksMatch) {
    for ($index = 0; $index -lt $verifiedChecks.Count; $index++) {
        foreach ($propertyName in @('Name', 'Status', 'Detail', 'Remediation')) {
            if ([string](Get-EvidencePropertyValue $providedChecks[$index] $propertyName) -cne
                [string](Get-EvidencePropertyValue $verifiedChecks[$index] $propertyName)) {
                $checksMatch = $false
                break
            }
        }
        if (-not $checksMatch) { break }
    }
}
$providedHashes = Get-EvidencePropertyValue $ReadinessResult 'SourceHashes'
$hashesMatch = $null -ne $providedHashes -and
    (Get-EvidencePropertyValue $providedHashes 'Algorithm') -ceq 'SHA-256' -and
    (Get-EvidencePropertyValue $providedHashes 'Canonicalization') -ceq 'SortedObjectPropertiesUtf8JsonV1' -and
    (Get-EvidencePropertyValue $providedHashes 'SqlReadinessSha256') -cmatch '^[A-F0-9]{64}$' -and
    (Get-EvidencePropertyValue $providedHashes 'SqlReadinessSha256') -ceq $verifiedReadiness.SourceHashes.SqlReadinessSha256 -and
    (Get-EvidencePropertyValue $providedHashes 'AdminReadinessSha256') -cmatch '^[A-F0-9]{64}$' -and
    (Get-EvidencePropertyValue $providedHashes 'AdminReadinessSha256') -ceq $verifiedReadiness.SourceHashes.AdminReadinessSha256
$allContractChecksPassed = @($verifiedChecks | Where-Object Status -EQ 'Failed').Count -eq 0
if ((Get-EvidencePropertyValue $ReadinessResult 'Passed') -isnot [bool] -or
    -not (Get-EvidencePropertyValue $ReadinessResult 'Passed') -or
    $verifiedReadiness.Passed -isnot [bool] -or -not $verifiedReadiness.Passed -or
    -not $allContractChecksPassed -or -not $checksMatch -or -not $hashesMatch) {
    throw 'A current validated readiness result with all contract checks passed and matching canonical source hashes is required before evidence pages are generated.'
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$rows = @(
    [pscustomobject]@{ Area = 'Provenance'; Check = 'SQL readiness source SHA-256'; Status = 'Passed'; Detail = $verifiedReadiness.SourceHashes.SqlReadinessSha256 }
    [pscustomobject]@{ Area = 'Provenance'; Check = 'Admin readiness source SHA-256'; Status = 'Passed'; Detail = $verifiedReadiness.SourceHashes.AdminReadinessSha256 }
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'Private boundary'; Status = if ($SqlReadiness.Vm.PublicIp -eq $false) { 'Passed' } else { 'Failed' }; Detail = 'No public IP' }
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'SQL TLS'; Status = if ($SqlReadiness.Sql.Encryption -eq 'Forced') { 'Passed' } else { 'Failed' }; Detail = "Port $($SqlReadiness.Sql.Port), forced encryption" }
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'Backup'; Status = if ($SqlReadiness.Backup.VerifyOnly -and $SqlReadiness.Backup.ChecksumClassification -ceq 'expected-verified') { 'Passed' } else { 'Failed' }; Detail = 'Official asset digest matched the reviewed expectation; VERIFYONLY completed' }
    [pscustomobject]@{ Area = 'Admin VM'; Check = 'SQL TLS'; Status = if ($AdminReadiness.SqlTls.EncryptOption -eq 'TRUE') { 'Passed' } else { 'Failed' }; Detail = 'Private DNS and certificate validation' }
    [pscustomobject]@{ Area = 'Admin VM'; Check = 'MCP allowlist'; Status = if ($AdminReadiness.Mcp.ConfigValid -and -not $AdminReadiness.Mcp.ForbiddenMutationTools) { 'Passed' } else { 'Failed' }; Detail = ($AdminReadiness.Mcp.ToolNames -join ', ') }
    [pscustomobject]@{ Area = 'Admin VM'; Check = 'GitHub CLI authentication'; Status = $AdminReadiness.Auth.GitHubCliAuthStatus; Detail = 'Observed without emitting command output' }
    [pscustomobject]@{ Area = 'Admin VM'; Check = 'Copilot authentication'; Status = $AdminReadiness.Auth.CopilotAuthStatus; Detail = 'Interactive sign-in is intentionally not automated' }
) | ForEach-Object {
    [pscustomobject]@{
        Area = ConvertTo-RedactedEvidenceText $_.Area
        Check = ConvertTo-RedactedEvidenceText $_.Check
        Status = ConvertTo-RedactedEvidenceText $_.Status
        Detail = ConvertTo-RedactedEvidenceText $_.Detail
    }
}

$html = $rows | ConvertTo-Html -Title 'MCP SQL Workshop deployment evidence' -PreContent @'
<h1>MCP SQL Workshop deployment evidence</h1>
<p>Sanitized readiness summary prepared for later deployment evidence capture.</p>
'@
$htmlPath = Join-Path $OutputDirectory 'deployment-readiness.html'
$html | Set-Content -LiteralPath $htmlPath -Encoding UTF8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# MCP SQL Workshop deployment evidence')
$markdown.Add('')
$markdown.Add('| Area | Check | Status | Detail |')
$markdown.Add('|---|---|---|---|')
foreach ($row in $rows) {
    $markdown.Add("| $($row.Area) | $($row.Check) | $($row.Status) | $($row.Detail) |")
}
$markdownPath = Join-Path $OutputDirectory 'deployment-readiness.md'
$markdown | Set-Content -LiteralPath $markdownPath -Encoding UTF8

[pscustomobject][ordered]@{
    Completed = $true
    SchemaVersion = '1.0'
    DeploymentId = ConvertTo-RedactedEvidenceText $SqlReadiness.DeploymentId
    RepositoryCommit = ConvertTo-RedactedEvidenceText $SqlReadiness.Repository.Commit
    CertificateThumbprint = ConvertTo-RedactedEvidenceText $SqlReadiness.Certificate.Thumbprint
    SqlReadinessSha256 = $verifiedReadiness.SourceHashes.SqlReadinessSha256
    AdminReadinessSha256 = $verifiedReadiness.SourceHashes.AdminReadinessSha256
    Sanitized = $true
    HtmlPath = $htmlPath
    MarkdownPath = $markdownPath
    ScreenshotsCaptured = $false
}
