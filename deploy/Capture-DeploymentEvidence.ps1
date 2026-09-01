[CmdletBinding()]
param(
    [Parameter(Mandatory)][psobject] $SqlReadiness,
    [Parameter(Mandatory)][psobject] $AdminReadiness,
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

if (-not $SqlReadiness.Completed -or -not $AdminReadiness.Completed) {
    throw 'Both readiness records must be complete before evidence pages are generated.'
}
if ($SqlReadiness.SchemaVersion -cne '1.0' -or $AdminReadiness.SchemaVersion -cne '1.0' -or
    -not $SqlReadiness.Evidence.Sanitized -or -not $AdminReadiness.Evidence.Sanitized -or
    $SqlReadiness.DeploymentId -cne $AdminReadiness.DeploymentId -or
    $SqlReadiness.Repository.Commit -cne $AdminReadiness.Repository.Commit -or
    $SqlReadiness.Certificate.Thumbprint -cne $AdminReadiness.SqlTls.CertificateThumbprint) {
    throw 'Readiness evidence identity, schema, sanitization, commit, or certificate binding does not match.'
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$rows = @(
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'Private boundary'; Status = if ($SqlReadiness.Vm.PublicIp -eq $false) { 'Passed' } else { 'Failed' }; Detail = 'No public IP' }
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'SQL TLS'; Status = if ($SqlReadiness.Sql.Encryption -eq 'Forced') { 'Passed' } else { 'Failed' }; Detail = "Port $($SqlReadiness.Sql.Port), forced encryption" }
    [pscustomobject]@{ Area = 'SQL VM'; Check = 'Backup'; Status = if ($SqlReadiness.Backup.VerifyOnly) { 'Passed' } else { 'Failed' }; Detail = 'Official asset hash observed; VERIFYONLY completed' }
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
    Sanitized = $true
    HtmlPath = $htmlPath
    MarkdownPath = $markdownPath
    ScreenshotsCaptured = $false
}
