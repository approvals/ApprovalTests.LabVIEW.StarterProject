# Runs inside the nationalinstruments/labview:<tag>-windows container (one docker run per job -
# there is no persistent container across steps like the Linux job container has, so this single
# script does everything: install packages, run the suite, write the report).
#
# Unlike LUnit (which registers a named g-cli alias, "lunit", via the
# sas_workshops_lib_lunit_for_g_cli package), Caraya's g-cli plugin (lvos_lib_caraya_cli_extension)
# has no alias - it's invoked by pointing g-cli straight at Caraya's own CarayaCLIExecutionEngine.vi,
# per https://github.com/LabVIEW-Open-Source/Caraya-CLI-extension:
#   g-cli --lv-ver <year> "<LabVIEW dir>\vi.lib\addons\_JKI Toolkits\Caraya\CarayaCLIExecutionEngine.vi" -- -s <source> -x <report>
param(
    [Parameter(Mandatory)] [int]$LabviewYear,
    [Parameter(Mandatory)] [int]$LabviewBitness,
    [Parameter(Mandatory)] [string]$VipcPath,
    [Parameter(Mandatory)] [string]$TestPath,
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

# Confirmed on 2026-09-04 CI run (against the LUnit job, same image): the "NI Package Manager CLI"
# preinstalled in this image is nipkg.exe (NI's own .nipkg-feed package manager) - NOT the classic
# VIPM CLI (vipm.exe) that understands the .vip/.vipc files this project's dependency stack is
# distributed as. So, same as the Linux job downloading VIPM's .deb before use, VIPM CLI has to be
# installed here first. Exact command from https://docs.vipm.io/preview/installation/
# (Windows / silent install / PowerShell).
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

# The installer's own process can exit (satisfying Start-Process -Wait) before VIPM has finished
# writing its default Settings.ini in the background - seen directly in CI (against the LUnit job,
# same image): the very same install sequence loaded Settings.ini fine on one run and failed with
# "file not found" on another. Poll with a harmless command instead of assuming ready-to-use the
# instant the installer returns.
Write-Host "=== Waiting for VIPM CLI to become ready ==="
$ready = $false
for ($i = 1; $i -le 15; $i++) {
    & $vipm --version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Write-Host "vipm not ready yet (attempt $i/15, exit $LASTEXITCODE) - waiting 2s"
    Start-Sleep -Seconds 2
}
if (-not $ready) {
    throw "vipm.exe never became ready after installing (still failing after 15 attempts)"
}
Write-Host "vipm is ready: $(& $vipm --version)"

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

# Locate the Caraya CLI extension VI by searching rather than guessing the LabVIEW install path
# (the equivalent guess for vipm.exe/g-cli.exe above was wrong on the first real CI run).
$niRoot = "${env:ProgramFiles}\National Instruments"
$carayaEngine = $null
if (Test-Path $niRoot) {
    $match = Get-ChildItem -Path $niRoot -Filter "CarayaCLIExecutionEngine.vi" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { $carayaEngine = $match.FullName }
}
if (-not $carayaEngine) {
    throw "CarayaCLIExecutionEngine.vi not found anywhere under '$niRoot' - the Caraya g-cli extension (lvos_lib_caraya_cli_extension) may not have installed correctly."
}
Write-Host "Found CarayaCLIExecutionEngine.vi: $carayaEngine"

$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

Write-Host "=== Running Caraya tests ==="
& $gcli --kill --kill-timeout 5000 --lv-ver $LabviewYear $carayaEngine -- -s $TestPath -x $ReportPath
exit $LASTEXITCODE
