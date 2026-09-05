# Runs inside the nationalinstruments/labview:<tag>-windows container (one docker run per job -
# there is no persistent container across steps like the Linux job container has, so this single
# script does everything: install packages, run the suite, write the report).
param(
    [Parameter(Mandatory)] [int]$LabviewYear,
    [Parameter(Mandatory)] [int]$LabviewBitness,
    [Parameter(Mandatory)] [string]$VipcPath,
    [Parameter(Mandatory)] [string]$ProjectPath,
    [Parameter(Mandatory)] [string]$ReportPath,
    [string]$PackageDir = ""
)
$ErrorActionPreference = "Stop"

# VIPM Community Edition shells out to git to check a package repository's visibility, and this
# image has no git of its own - the workflow bind-mounts the host runner's own Git for Windows
# install (C:\Program Files\Git on GitHub-hosted windows-latest) into the container at C:\Git, so
# just put it on PATH here instead of downloading/installing another copy of git.
if (Test-Path "C:\Git\cmd\git.exe") {
    $env:PATH = "C:\Git\cmd;$env:PATH"
}

# Confirmed on 2026-09-04 CI run: the "NI Package Manager CLI" preinstalled in this image is
# nipkg.exe (NI's own .nipkg-feed package manager) - NOT the classic VIPM CLI (vipm.exe) that
# understands the .vip/.vipc files this project's whole dependency stack (LUnit, Caraya, g-cli,
# JSONtext, ApprovalTests itself) is distributed as. So, same as the Linux job downloading VIPM's
# .deb before use, VIPM CLI has to be installed here first. Exact command from
# https://docs.vipm.io/preview/installation/ (Windows / silent install / PowerShell).
function Install-Vipm {
    if (Get-Command vipm.exe -ErrorAction SilentlyContinue) { return }
    Write-Host "=== Installing VIPM CLI ==="
    $installer = "$env:TEMP\vipm-setup.exe"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "https://traffic.libsyn.com/secure/jkinc/vipm-26.3.4025-windows-setup.exe" -OutFile $installer
    Start-Process -Wait -FilePath $installer -ArgumentList "/exenoui /qn"
    Remove-Item $installer -Force
}

# The VIPM installer's PATH change (via setx) doesn't reach this already-running process, so
# locate vipm.exe/g-cli.exe by searching the plausible install trees rather than assuming PATH -
# printing what's found either way for diagnostics.
function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "Found $Name on PATH: $($cmd.Source)"
        return $cmd.Source
    }
    $roots = @(
        "${env:ProgramFiles}\National Instruments",
        "${env:ProgramFiles(x86)}\National Instruments",
        "${env:ProgramFiles}\JKI",
        "${env:ProgramFiles(x86)}\JKI",
        "${env:ProgramData}\National Instruments",
        "${env:LOCALAPPDATA}\National Instruments"
    ) | Where-Object { $_ -and (Test-Path $_) }
    Write-Host "$Name not on PATH - searching: $($roots -join ', ')"
    $found = @($roots | ForEach-Object { Get-ChildItem -Path $_ -Filter $Name -Recurse -File -ErrorAction SilentlyContinue })
    if ($found.Count -gt 0) {
        Write-Host "Found $($found.Count) candidate(s): $($found.FullName -join ', ')"
        return $found[0].FullName
    }
    throw "Could not locate $Name on PATH or under: $($roots -join ', ')"
}

Install-Vipm
$vipm = Find-Tool -Name "vipm.exe"

# Root cause, found by inspecting the Linux .deb this same project's Linux job installs: its
# postinst script explicitly creates an EMPTY Settings.ini (`install -m 664 /dev/null
# ".../Settings.ini"`) if one doesn't already exist - that's VIPM CLI's entire "first run"
# bootstrap on Linux. The Windows installer has no equivalent step, so on a truly fresh install
# `vipm install` fails with "Failed to load Settings.ini: ... cannot find the file specified."
# (vipm refresh degrades this to a warning and limps on, which is what made it look like a timing
# race in earlier debugging - it never was one). Fix: create the same empty placeholder ourselves.
$vipmSettingsDir = "C:\ProgramData\JKI\VIPM"
$vipmSettingsFile = Join-Path $vipmSettingsDir "Settings.ini"
if (-not (Test-Path $vipmSettingsFile)) {
    New-Item -ItemType Directory -Force -Path $vipmSettingsDir | Out-Null
    New-Item -ItemType File -Force -Path $vipmSettingsFile | Out-Null
    Write-Host "Created empty $vipmSettingsFile (mirrors the Linux .deb postinst's bootstrap)"
}

# Recommended by https://docs.vipm.io/preview/cli/docker/ before every install, to avoid stale
# caches. Not fatal if it warns (see comment above) - the real gate is Settings.ini existing.
Write-Host "=== vipm refresh ==="
& $vipm refresh
if ($LASTEXITCODE -ne 0) { Write-Host "vipm refresh failed with exit $LASTEXITCODE (non-fatal)" }

function Invoke-Vipm {
    param([string[]]$VipmArgs)
    Write-Host "vipm $($VipmArgs -join ' ')"
    & $vipm @VipmArgs
    if ($LASTEXITCODE -ne 0) {
        throw "vipm $($VipmArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Write-Host "=== Installing packages from $VipcPath ==="
Invoke-Vipm @("install", $VipcPath, "--labview-version", $LabviewYear, "--labview-bitness", $LabviewBitness, "--show-progress")

if ($PackageDir -and (Test-Path $PackageDir)) {
    $package = Get-ChildItem -Path $PackageDir -Filter *.vip -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($package) {
        Write-Host "=== Installing freshly built package: $($package.FullName) ==="
        Invoke-Vipm @("install", $package.FullName, "--labview-version", $LabviewYear, "--labview-bitness", $LabviewBitness, "--show-progress")
    }
}

Write-Host "=== Installed packages ==="
& $vipm list --installed
if ($LASTEXITCODE -ne 0) { Write-Host "vipm list --installed failed (non-fatal)" }

# g-cli.exe only exists after the .vipc install above (wiresmith_technology_lib_g_cli), so it
# can't be located any earlier than this.
$gcli = Find-Tool -Name "g-cli.exe"

$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

Write-Host "=== Running LUnit tests ==="
& $gcli --kill --kill-timeout 5000 lunit -- -r $ReportPath $ProjectPath
exit $LASTEXITCODE
