Set-StrictMode -Version Latest

function Invoke-RepositoryGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter()]
        [string] $Operation = 'command'
    )

    $output = @(& git -C $RepositoryRoot @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $Operation failed with exit code $exitCode."
    }

    return @($output | ForEach-Object { $_.ToString() })
}

function Test-RepositoryGitRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $Ref
    )

    & git -C $RepositoryRoot rev-parse --verify --quiet "$Ref^{commit}" *> $null
    return $LASTEXITCODE -eq 0
}

function Get-RepositoryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter()]
        [string[]] $PathSpec = @()
    )

    $arguments = @('ls-files', '--cached', '--others', '--exclude-standard')
    if ($PathSpec.Count -gt 0) {
        $arguments += '--'
        $arguments += $PathSpec
    }

    return @(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -ArgumentList $arguments -Operation 'ls-files') |
        Where-Object { $_ }
}

function Get-RepositoryJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    return @(Get-RepositoryFile -RepositoryRoot $RepositoryRoot -PathSpec '*.json') | Sort-Object
}

function Test-ApprovedPasswordValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $candidate = $Value.Trim().Trim("'", '"')
    return (
        [string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^(?i:SET_LOCALLY_ON_ADMIN_VM|WORKSHOP-PLACEHOLDER|<password>)$' -or
        $candidate -match '^\$\{[^}]+\}$' -or
        $candidate -match '^\$\([A-Za-z_][A-Za-z0-9_.-]*\)$' -or
        $candidate -match '^@env\([^)]+\)$' -or
        $candidate -match '^@[A-Za-z_][A-Za-z0-9_]*$' -or
        $candidate -match '^\$(?:env:)?[A-Za-z_][A-Za-z0-9_:]*$' -or
        $candidate -match '^\[(?:System\.)?Environment\]::GetEnvironmentVariable\((?:''[^'']+''|"[^"]+")\)$' -or
        $candidate -match '^(?i:Read-Host)\b'
    )
}

function Find-RepositorySecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Content
    )

    $normalizedPath = $Path.Replace('\', '/')
    if ($normalizedPath -ieq 'build/RepositoryValidation.psm1') {
        return
    }

    $fixtureBypassIsAllowed = (
        $normalizedPath -match '^(?i:tests/fixtures/)' -or
        $normalizedPath -ieq 'tests/repository/RepositoryValidation.Tests.ps1'
    )
    if ($fixtureBypassIsAllowed -and
        $Content -match 'repository-secret-scan:\s*allow-test-fixture') {
        return
    }

    $privateKeyPattern = '-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'
    $patterns = @(
        '(?i)"(?:password|pwd)"\s*:\s*(?<value>"(?:\\.|[^"\\])*")',
        '(?i)(?:^|[;\s])(?:password|pwd)\s*=\s*(?<value>[^;\r\n]+)',
        '(?i)^\s*(?:password|pwd)\s*:\s*(?<value>[^#\r\n]+)',
        '(?i)(?:^|[,{])\s*(?:password|pwd)\s*:\s*(?<value>''[^'']*''|"[^"]*"|\$\{[^}]+\}|[^#,}\r\n]+)',
        '(?i)-(?:password|pwd)\s+(?<value>''[^'']*''|"[^"]*"|[^\s;,)]+)',
        '(?i)(?:^|[;{])\s*(?:password|pwd)\s*=\s*(?<value>''[^'']*''|"[^"]*"|[^;},\r\n]+)',
        '(?i)^\s*\$(?:password|pwd)\s*=\s*(?<value>''[^'']*''|"[^"]*"|[^;\r\n]+)',
        '(?i)ConvertTo-SecureString\s+(?<value>''[^'']*''|"[^"]*")'
    )

    $multilineJsonPattern = '(?im)"(?:password|pwd)"\s*:\s*\r?\n\s*(?<value>"(?:\\.|[^"\\])*")'
    foreach ($match in [regex]::Matches($Content, $multilineJsonPattern)) {
        if (-not (Test-ApprovedPasswordValue -Value $match.Groups['value'].Value)) {
            [pscustomobject]@{
                Path = $Path
                Type = 'Password assignment'
                Line = 1 + ([regex]::Matches($Content.Substring(0, $match.Index), '\r?\n')).Count
            }
        }
    }

    $lineNumber = 0
    foreach ($line in ($Content -split '\r?\n')) {
        $lineNumber++
        $reportedAssignments = [System.Collections.Generic.HashSet[int]]::new()
        if ($fixtureBypassIsAllowed -and
            $line -match 'repository-secret-scan:\s*allow-test-fixture') {
            continue
        }
        if ($line -match $privateKeyPattern) {
            [pscustomobject]@{
                Path = $Path
                Type = 'Private key'
                Line = $lineNumber
            }
        }

        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($line, $pattern)) {
                if (Test-ApprovedPasswordValue -Value $match.Groups['value'].Value) {
                    continue
                }

                $passwordToken = [regex]::Match($match.Value, '(?i)(?:password|pwd)')
                $assignmentIndex = if ($passwordToken.Success) {
                    $match.Index + $passwordToken.Index
                }
                else {
                    $match.Groups['value'].Index
                }
                if (-not $reportedAssignments.Add($assignmentIndex)) {
                    continue
                }

                [pscustomobject]@{
                    Path = $Path
                    Type = 'Password assignment'
                    Line = $lineNumber
                }
            }
        }
    }
}

function Resolve-RepositoryDiffBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter()]
        [string] $BaseRef
    )

    if ($BaseRef) {
        if (-not (Test-RepositoryGitRef -RepositoryRoot $RepositoryRoot -Ref $BaseRef)) {
            throw "Base ref '$BaseRef' is not a valid commit."
        }
        return $BaseRef
    }

    $eventBefore = $env:GITHUB_EVENT_BEFORE
    if ($eventBefore -and $eventBefore -notmatch '^0{40}$' -and
        (Test-RepositoryGitRef -RepositoryRoot $RepositoryRoot -Ref $eventBefore)) {
        return $eventBefore
    }

    $currentBranch = @(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -ArgumentList @(
        'branch', '--show-current'
    ) -Operation 'branch lookup')[0]
    foreach ($mainRef in @('origin/main', 'main')) {
        if ($currentBranch -ne 'main' -and
            (Test-RepositoryGitRef -RepositoryRoot $RepositoryRoot -Ref $mainRef)) {
            $mergeBase = @(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -ArgumentList @(
                'merge-base', 'HEAD', $mainRef
            ) -Operation 'merge-base')[0]
            if ($mergeBase) {
                return $mergeBase
            }
        }
    }

    if (Test-RepositoryGitRef -RepositoryRoot $RepositoryRoot -Ref 'HEAD^') {
        return 'HEAD^'
    }

    return 'HEAD'
}

function Invoke-RepositoryDiffCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [Parameter(Mandatory)]
        [string] $Description
    )

    $output = @(& git -C $RepositoryRoot diff @ArgumentList 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $detail = @($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Git whitespace check failed for $Description (exit code $exitCode).`n$detail"
    }
}

function Test-RepositoryWhitespace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter()]
        [string] $BaseRef
    )

    $resolvedBase = Resolve-RepositoryDiffBase -RepositoryRoot $RepositoryRoot -BaseRef $BaseRef
    Invoke-RepositoryDiffCheck -RepositoryRoot $RepositoryRoot -ArgumentList @(
        '--check', "$resolvedBase...HEAD"
    ) -Description 'base-to-HEAD range'
    Invoke-RepositoryDiffCheck -RepositoryRoot $RepositoryRoot -ArgumentList @('--check') `
        -Description 'working tree'
    Invoke-RepositoryDiffCheck -RepositoryRoot $RepositoryRoot -ArgumentList @('--cached', '--check') `
        -Description 'index'
}

function Get-PSScriptAnalyzerGateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool] $AnalyzerAvailable,

        [Parameter()]
        [switch] $Required
    )

    if ($AnalyzerAvailable) {
        return [pscustomobject]@{
            Failed = $false
            Skipped = $false
            Message = 'PASS: PSScriptAnalyzer'
        }
    }

    if ($Required) {
        return [pscustomobject]@{
            Failed = $true
            Skipped = $false
            Message = 'PSScriptAnalyzer is required but not installed; run build/Install-DevDependencies.ps1.'
        }
    }

    return [pscustomobject]@{
        Failed = $false
        Skipped = $true
        Message = 'SKIP: PSScriptAnalyzer (not installed; run build/Install-DevDependencies.ps1)'
    }
}

Export-ModuleMember -Function @(
    'Find-RepositorySecret',
    'Get-PSScriptAnalyzerGateResult',
    'Get-RepositoryFile',
    'Get-RepositoryJsonFile',
    'Resolve-RepositoryDiffBase',
    'Test-RepositoryWhitespace'
)
