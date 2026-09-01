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

function Get-RepositoryEvidenceJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    return @(
        Get-RepositoryFile -RepositoryRoot $RepositoryRoot -PathSpec 'evidence/*.json' |
            Where-Object { $_ -ne 'evidence/evidence-schema.json' }
    ) | Sort-Object
}

function Test-ApprovedPasswordValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $expression = $Value.Trim()
    $candidate = $expression.TrimEnd(';').Trim().Trim("'", '"')
    $sqlReferencePattern = '(?:@[A-Za-z_][A-Za-z0-9_]*|\$\([A-Za-z_][A-Za-z0-9_.-]*\)|(?i:SESSION_CONTEXT)\(\s*N?''[^'']+''\s*\))'
    $escapedSqlPasswordPattern = "(?i:REPLACE)\(\s*$sqlReferencePattern\s*,\s*N?''''\s*,\s*N?''''''\s*\)"
    $delimitedEscapedSqlPasswordPattern = "^\s*N?'''\s*\+\s*$escapedSqlPasswordPattern\s*\+\s*N?''''\s*;?\s*$"
    return (
        [string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^(?i:SET_LOCALLY_ON_ADMIN_VM|WORKSHOP-PLACEHOLDER|<password>)$' -or
        $candidate -match '^\$\{[^}]+\}$' -or
        $candidate -match '^\$\([A-Za-z_][A-Za-z0-9_.-]*\)$' -or
        $candidate -match '^@env\([^)]+\)$' -or
        $candidate -match '^@[A-Za-z_][A-Za-z0-9_]*$' -or
        $candidate -match '^\$(?:env:)?[A-Za-z_][A-Za-z0-9_:]*$' -or
        $candidate -match '^\[(?:System\.)?Environment\]::GetEnvironmentVariable\((?:''[^'']+''|"[^"]+")\)$' -or
        $candidate -match '^(?i:Read-Host)\b' -or
        $expression -match "^$sqlReferencePattern\s*;?$" -or
        $expression -match "^\s*$escapedSqlPasswordPattern\s*;?\s*$" -or
        $expression -match $delimitedEscapedSqlPasswordPattern
    )
}

function Get-RepositoryPasswordExpression {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $InitialValue,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $ContentLines,

        [Parameter(Mandatory)]
        [int] $NextLineIndex
    )

    $expression = [System.Text.StringBuilder]::new()
    $inBlockComment = $false
    $lines = @($InitialValue)
    if ($NextLineIndex -lt $ContentLines.Count) {
        $lines += $ContentLines[$NextLineIndex..($ContentLines.Count - 1)]
    }

    for ($lineIndex = 0; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        $code = [System.Text.StringBuilder]::new()
        $quote = [char] 0
        $index = 0
        while ($index -lt $line.Length) {
            if ($inBlockComment) {
                if ($index + 1 -lt $line.Length -and $line.Substring($index, 2) -eq '*/') {
                    $inBlockComment = $false
                    $index += 2
                }
                else {
                    $index++
                }
                continue
            }

            $character = $line[$index]
            if ($quote -ne [char] 0) {
                [void] $code.Append($character)
                if ($character -eq $quote) {
                    if ($index + 1 -lt $line.Length -and $line[$index + 1] -eq $quote) {
                        [void] $code.Append($line[$index + 1])
                        $index += 2
                        continue
                    }
                    $quote = [char] 0
                }
                $index++
                continue
            }

            if ($character -eq "'" -or $character -eq '"') {
                $quote = $character
                [void] $code.Append($character)
                $index++
                continue
            }
            if ($index + 1 -lt $line.Length) {
                $pair = $line.Substring($index, 2)
                if ($pair -eq '--') {
                    break
                }
                if ($pair -eq '/*') {
                    $inBlockComment = $true
                    $index += 2
                    continue
                }
            }

            [void] $code.Append($character)
            $index++
        }

        $cleanedLine = $code.ToString().Trim()
        if ($lineIndex -eq 0) {
            [void] $expression.Append($cleanedLine)
            continue
        }
        if ([string]::IsNullOrWhiteSpace($cleanedLine)) {
            continue
        }
        if ($cleanedLine -notmatch '^\+') {
            break
        }

        [void] $expression.Append(' ')
        [void] $expression.Append($cleanedLine)
    }

    return $expression.ToString()
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

    $fixtureBypassIsAllowed = $normalizedPath -match '^(?i:tests/fixtures/secrets/)'
    $fixtureMarkerPattern = '(?i)(?:^|\s)#\s*repository-secret-scan:\s*allow-test-fixture\s*$'
    $fixtureMarkerOnlyPattern = '(?i)^\s*#\s*repository-secret-scan:\s*allow-test-fixture\s*$'
    $contentLines = @($Content -split '\r?\n')
    $standaloneFixtureMarkerLines = [System.Collections.Generic.HashSet[int]]::new()
    $inlineFixtureMarkerIndexes = [System.Collections.Generic.Dictionary[int, int]]::new()
    if ($fixtureBypassIsAllowed) {
        for ($index = 0; $index -lt $contentLines.Count; $index++) {
            $fixtureMarker = [regex]::Match($contentLines[$index], $fixtureMarkerPattern)
            if (-not $fixtureMarker.Success) {
                continue
            }

            if ($contentLines[$index] -match $fixtureMarkerOnlyPattern) {
                # A standalone marker suppresses only the first finding on the immediately following line.
                [void] $standaloneFixtureMarkerLines.Add($index + 2)
            }
            else {
                # An inline marker suppresses only the finding whose value/header immediately precedes it.
                $inlineFixtureMarkerIndexes[$index + 1] =
                    $fixtureMarker.Index + $fixtureMarker.Value.IndexOf('#')
            }
        }
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
        $findingLine = 1 + ([regex]::Matches($Content.Substring(0, $match.Index), '\r?\n')).Count
        if (Test-ApprovedPasswordValue -Value $match.Groups['value'].Value) {
            continue
        }
        if ($standaloneFixtureMarkerLines.Remove($findingLine)) {
            continue
        }

        [pscustomobject]@{
            Path = $Path
            Type = 'Password assignment'
            Line = $findingLine
        }
    }

    $lineNumber = 0
    foreach ($line in $contentLines) {
        $lineNumber++
        $reportedAssignments = [System.Collections.Generic.HashSet[int]]::new()
        $candidates = [System.Collections.Generic.List[object]]::new()

        foreach ($match in [regex]::Matches($line, $privateKeyPattern)) {
            $candidates.Add([pscustomobject]@{
                Id = "Private key:$($match.Index)"
                Type = 'Private key'
                Index = $match.Index
                EndIndex = $match.Index + $match.Length
            })
        }

        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($line, $pattern)) {
                $valueForApproval = Get-RepositoryPasswordExpression `
                    -InitialValue $match.Groups['value'].Value `
                    -ContentLines $contentLines `
                    -NextLineIndex $lineNumber
                $passwordToken = [regex]::Match($match.Value, '(?i)(?:password|pwd)')
                $assignmentIndex = if ($passwordToken.Success) {
                    $match.Index + $passwordToken.Index
                }
                else {
                    $match.Groups['value'].Index
                }
                if (Test-ApprovedPasswordValue -Value $valueForApproval) {
                    [void] $reportedAssignments.Add($assignmentIndex)
                    continue
                }
                if (-not $reportedAssignments.Add($assignmentIndex)) {
                    continue
                }

                $valueGroup = $match.Groups['value']
                $valueEndIndex = $valueGroup.Index + $valueGroup.Length
                if ($inlineFixtureMarkerIndexes.ContainsKey($lineNumber)) {
                    $markerIndex = $inlineFixtureMarkerIndexes[$lineNumber]
                    if ($valueGroup.Index -lt $markerIndex -and $valueEndIndex -gt $markerIndex) {
                        $valueEndIndex = $markerIndex
                    }
                }
                while (
                    $valueEndIndex -gt $valueGroup.Index -and
                    [char]::IsWhiteSpace($line[$valueEndIndex - 1])
                ) {
                    $valueEndIndex--
                }

                $candidates.Add([pscustomobject]@{
                    Id = "Password assignment:$assignmentIndex"
                    Type = 'Password assignment'
                    Index = $assignmentIndex
                    EndIndex = $valueEndIndex
                })
            }
        }

        $orderedCandidates = @($candidates | Sort-Object Index, Type)
        $suppressedCandidateIds = [System.Collections.Generic.HashSet[string]]::new()
        if ($standaloneFixtureMarkerLines.Remove($lineNumber) -and $orderedCandidates.Count -gt 0) {
            [void] $suppressedCandidateIds.Add($orderedCandidates[0].Id)
        }

        if ($inlineFixtureMarkerIndexes.ContainsKey($lineNumber)) {
            $markerIndex = $inlineFixtureMarkerIndexes[$lineNumber]
            $inlineCandidate = $orderedCandidates |
                Where-Object {
                    $_.EndIndex -le $markerIndex -and
                    $line.Substring($_.EndIndex, $markerIndex - $_.EndIndex) -match '^\s*$'
                } |
                Sort-Object EndIndex -Descending |
                Select-Object -First 1
            if ($null -ne $inlineCandidate) {
                [void] $suppressedCandidateIds.Add($inlineCandidate.Id)
            }
        }

        foreach ($candidate in $orderedCandidates) {
            if ($suppressedCandidateIds.Contains($candidate.Id)) {
                continue
            }

            [pscustomobject]@{
                Path = $Path
                Type = $candidate.Type
                Line = $lineNumber
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
    'Get-RepositoryEvidenceJsonFile',
    'Get-RepositoryFile',
    'Get-RepositoryJsonFile',
    'Resolve-RepositoryDiffBase',
    'Test-RepositoryWhitespace'
)
