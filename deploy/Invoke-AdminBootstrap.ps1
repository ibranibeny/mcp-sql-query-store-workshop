[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ProtectedPayloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$exitCode = 1

try {
    if ($env:MCP_SQL_ADMIN_BOOTSTRAP_PWSH -ceq '1') {
        throw 'Administration bootstrap handoff recursion was detected.'
    }
    if (-not (Test-Path -LiteralPath $ProtectedPayloadPath -PathType Leaf)) {
        throw 'Protected bootstrap payload is unavailable.'
    }

    $wingetPath = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        $wingetPath = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' `
            -ErrorAction SilentlyContinue | Sort-Object FullName -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ([string]::IsNullOrWhiteSpace($wingetPath)) {
        throw 'winget.exe is required to install PowerShell 7.'
    }

    & $wingetPath install --id Microsoft.PowerShell --exact --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements --source winget
    if ($LASTEXITCODE -ne 0) {
        throw 'The official PowerShell 7 package installation failed.'
    }

    $pwshPath = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        $candidate = 'C:\Program Files\PowerShell\7\pwsh.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $pwshPath = $candidate }
    }
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
        throw 'pwsh.exe is unavailable after installing the official PowerShell package.'
    }

    $mainScript = Join-Path $PSScriptRoot 'Initialize-AdminVm.ps1'
    $env:MCP_SQL_ADMIN_BOOTSTRAP_PWSH = '1'
    & $pwshPath -NoProfile -NonInteractive -File $mainScript -ProtectedPayloadPath $ProtectedPayloadPath
    $exitCode = $LASTEXITCODE
}
finally {
    $env:MCP_SQL_ADMIN_BOOTSTRAP_PWSH = $null
    Remove-Item -LiteralPath $ProtectedPayloadPath -Force -ErrorAction SilentlyContinue
}

exit $exitCode