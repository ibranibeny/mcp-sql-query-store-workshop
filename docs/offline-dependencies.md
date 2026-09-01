# Offline development dependencies

The repository installer is offline-first. Its default behavior never contacts PyPI or
PowerShell Gallery, never upgrades `pip`, and does not install anything when the existing
tools satisfy the bounded versions in `requirements-dev.txt`.

Python supports repository site generation and tests only. The Azure VM workshop runtime
does not require Python or PyPI. GitHub Pages publishes the generated static HTML, CSS, and
JavaScript output; it does not install Python packages at runtime.

## Supported corporate routes

### 1. Preprovisioned environment

Preinstall the bounded Python packages, Pester, and PSScriptAnalyzer through the corporate
software-distribution process. Then run:

```powershell
./build/Install-DevDependencies.ps1
```

The script verifies package metadata in `.venv` and exits without invoking `pip` or
`Install-Module` when all versions are acceptable. If `.venv` is absent, it creates one
using an available local Python installation without downloading anything.

### 2. Local or internal wheelhouse

Provide an existing local directory populated by an approved internal process:

```powershell
./build/Install-DevDependencies.ps1 -WheelhousePath C:\Approved\workshop-wheels
```

The directory and every traversed path component must not be a symbolic link or reparse
point. Installation uses `--no-index` and `--find-links`; public indexes remain disabled.

### 3. Internal configured package index

Set the approved internal index in the environment, then opt in explicitly:

```powershell
$env:PIP_INDEX_URL = 'https://packages.corporate.example/simple'
./build/Install-DevDependencies.ps1 -AllowConfiguredPackageIndex
```

The installer does not print the configured URL. Do not place credentials in commands,
documentation, or repository files; use the corporate credential provider.

If PowerShell modules are not preprovisioned, select an approved registered internal
repository separately:

```powershell
./build/Install-DevDependencies.ps1 -PowerShellRepositoryName CorporatePS
```

`-AllowPublicPackageIndex` and `-AllowPowerShellGallery` are explicit noncorporate/CI
escape hatches. They are never enabled by default and should not be used on the corporate
network.

## Validation without installation

Repository validation checks the current virtual environment when it exists, but does not
install packages:

```powershell
./.venv/Scripts/python.exe ./build/Test-PythonDependencies.py --requirements ./requirements-dev.txt
./build/Test-Repository.ps1
```

Verifier output is limited to the package name, required bounds, detected version, and
status. It does not print environment variables, index URLs, proxy settings, or credentials.