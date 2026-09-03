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

    # winget cannot run as SYSTEM in a Custom Script Extension (MSIX activation fails with
    # STATUS_DLL_NOT_FOUND), so install the official PowerShell 7 MSI directly with msiexec.
    $powerShellMsiUri = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi'
    $powerShellMsiPath = Join-Path $env:TEMP 'mcp-powershell-7.msi'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $powerShellInstall = $null
    try {
        Invoke-WebRequest -Uri $powerShellMsiUri -OutFile $powerShellMsiPath -UseBasicParsing
        $powerShellInstall = Start-Process -FilePath 'msiexec.exe' `
            -ArgumentList @('/i', "`"$powerShellMsiPath`"", '/qn', '/norestart') -Wait -PassThru
    }
    finally {
        Remove-Item -LiteralPath $powerShellMsiPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $powerShellInstall -or $powerShellInstall.ExitCode -ne 0) {
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