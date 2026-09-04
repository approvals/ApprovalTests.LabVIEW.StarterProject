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

# ASSUMPTION, unverified against a real container run: NI's prebuilt Windows image ships VIPM CLI
# and g-cli preinstalled and on PATH (per https://github.com/ni/labview-for-containers
# docs/windows-prebuilt.md - "NI Package Manager and NI Package Manager CLI" is listed as
# preinstalled). Falls back to a couple of likely Program Files locations if not.
function Find-Tool {
    param([string]$Name, [string[]]$FallbackPaths)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $FallbackPaths) {
        if (Test-Path $p) { return $p }
    }
    throw "Could not locate $Name on PATH or in: $($FallbackPaths -join ', ')"
}

$vipm = Find-Tool -Name "vipm.exe" -FallbackPaths @(
    "${env:ProgramFiles}\National Instruments\VI Package Manager\VIPM.exe",
    "${env:ProgramFiles(x86)}\National Instruments\VI Package Manager\VIPM.exe"
)
$gcli = Find-Tool -Name "g-cli.exe" -FallbackPaths @(
    "${env:ProgramFiles}\National Instruments\g-cli\g-cli.exe"
)

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

# ASSUMPTION, unverified: default install location for a per-tag LabVIEW install inside the container.
$labviewDir = "${env:ProgramFiles}\National Instruments\LabVIEW $LabviewYear"
$carayaEngine = Join-Path $labviewDir 'vi.lib\addons\_JKI Toolkits\Caraya\CarayaCLIExecutionEngine.vi'
if (-not (Test-Path $carayaEngine)) {
    throw "CarayaCLIExecutionEngine.vi not found at '$carayaEngine' - confirm the container's actual LabVIEW install path and update `$labviewDir above."
}

$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

Write-Host "=== Running Caraya tests ==="
& $gcli --kill --kill-timeout 5000 --lv-ver $LabviewYear $carayaEngine -- -s $TestPath -x $ReportPath
exit $LASTEXITCODE
