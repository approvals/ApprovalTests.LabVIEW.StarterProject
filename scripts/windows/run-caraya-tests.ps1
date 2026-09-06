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
# Matches the working configuration in https://gist.github.com/Flydroid/8b1d5540dd64db50d48cf2d84455ecfe
# (an independent, confirmed-working recipe for this exact container/VIPM combination - see the
# Start-VipmStack comment below for the full story).
$env:CI = "true"
$env:GITHUB_ACTIONS = "true"
$env:NO_COLOR = "1"

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
    # Confirmed on CI against the LUnit job: wiresmith_technology_lib_g_cli's VIPM package does NOT
    # install g-cli.exe under National Instruments or JKI - widen to the whole Program Files trees
    # before giving up.
    $wideRoots = @("${env:ProgramFiles}", "${env:ProgramFiles(x86)}") | Where-Object { $_ -and (Test-Path $_) }
    Write-Host "$Name not found under NI/JKI roots either - widening search to: $($wideRoots -join ', ')"
    $found = @($wideRoots | ForEach-Object { Get-ChildItem -Path $_ -Filter $Name -Recurse -File -ErrorAction SilentlyContinue })
    if ($found.Count -gt 0) {
        Write-Host "Found $($found.Count) candidate(s): $($found.FullName -join ', ')"
        return $found[0].FullName
    }
    throw "Could not locate $Name on PATH or under: $($roots -join ', '), $($wideRoots -join ', ')"
}

# The dialog-suppression theory (below) turned out to be moot either way: window/process
# diagnostics from a CI run against the LUnit job (same image) showed LabVIEW.exe never launches
# at all during the hang, and VIPM Desktop (the "VI Package Manager" process) sits nearly idle
# (~4s of CPU burned across 105s of wall time) rather than actually computing - a real blocked
# wait, not a dialog and not slow work. The leading theory now: VIPM has driven LabVIEW via VI
# Server (or the ActiveX equivalent on Windows) for package installs for a very long time, and per
# https://github.com/ni/labview-for-containers' own windows-custom-images.md, the DIY custom-image
# build process has to explicitly drop in a LabVIEW.ini "to enable VI Server and other required
# INI tokens" and warns that skipping it "will break LabVIEWCLI operations" - implying a stock
# install's default ini does NOT have VI Server on. If it's off, VIPM Desktop can't ask LabVIEW to
# do anything and would plausibly sit exactly like this: alive, blocked on an unanswered
# connection, with no reason to ever even launch LabVIEW.exe.
#
# This function never actually confirmed VI Server's prior state - if LabVIEW.ini didn't already
# exist, the old version of this function would have CREATED it containing only the
# dialog-suppression keys below, with no VI Server keys at all. It now logs the full before/after
# content (so that question has a real answer in the log) and adds the standard VI Server
# enablement keys alongside dialog suppression. Port 3363 and "+*" access are LabVIEW's
# long-standing conventional defaults for these tokens; unlike the other keys here, this hasn't
# been confirmed against this specific image's documentation.
function Set-LabviewIniConfig {
    param([int]$LabviewYear)
    $labviewDir = "${env:ProgramFiles}\National Instruments\LabVIEW $LabviewYear"
    if (-not (Test-Path $labviewDir)) {
        Write-Host "LabVIEW install dir not found at '$labviewDir' - skipping ini config"
        return
    }
    $iniPath = Join-Path $labviewDir "LabVIEW.ini"
    $keys = [ordered]@{
        "autoerr"                      = "3"
        "NIERShowFatalDialog"          = "False"
        "NIERFatalAutoSend"            = "True"
        "NIERNonFatalAutoSend"         = "True"
        "NIERShowNonFatalDialogOnExit" = "False"
        "NIERSendDialogClose"          = "True"
        "DWarnDialog"                  = "False"
        "promoteDWarnInternals"        = "False"
        "server.tcp.enabled"           = "True"
        "server.tcp.port"              = "3363"
        "server.tcp.access"            = "+*"
        "server.vi.callsEnabled"       = "True"
    }
    Write-Host "=== $iniPath BEFORE edit ==="
    if (Test-Path $iniPath) { Get-Content -Path $iniPath | ForEach-Object { Write-Host $_ } } else { Write-Host "(file does not exist yet)" }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $iniPath) { (Get-Content -Path $iniPath) | ForEach-Object { $lines.Add($_) } }
    $sectionIndex = ($lines | Select-String -Pattern '^\s*\[LabVIEW\]\s*$' -SimpleMatch:$false).LineNumber
    if (-not $sectionIndex) {
        $lines.Add("[LabVIEW]")
        $sectionIndex = $lines.Count
    }
    $sectionStart = $sectionIndex - 1
    $sectionEnd = $lines.Count
    for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim().StartsWith("[")) { $sectionEnd = $i; break }
    }
    foreach ($key in $keys.Keys) {
        $found = $false
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match "^\s*$key\s*=") {
                $lines[$i] = "$key=$($keys[$key])"
                $found = $true
                break
            }
        }
        if (-not $found) {
            $lines.Insert($sectionEnd, "$key=$($keys[$key])")
            $sectionEnd++
        }
    }
    Set-Content -Path $iniPath -Value $lines
    Write-Host "=== $iniPath AFTER edit ==="
    Get-Content -Path $iniPath | ForEach-Object { Write-Host $_ }
}

# Finds LabVIEW.exe itself (not vipm.exe/g-cli.exe - Find-Tool searches by filename across NI/JKI
# roots generically, but Start-VipmStack below needs the actual LabVIEW.exe path to launch it and
# to read its version resource).
function Find-LabviewExe {
    $roots = @(
        "${env:ProgramFiles}\National Instruments",
        "${env:ProgramFiles(x86)}\National Instruments"
    ) | Where-Object { Test-Path $_ }
    foreach ($root in $roots) {
        $candidate = Get-ChildItem -Path $root -Directory -Filter "LabVIEW*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "LabVIEW.exe" } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($candidate) { return $candidate }
    }
    throw "Could not locate LabVIEW.exe under: $($roots -join ', ')"
}

# THE actual root cause, per https://github.com/vipm-io/vipm-desktop-issues/issues/108 (filed
# independently against this exact nationalinstruments/labview:*-windows + VIPM CLI combination -
# same "Failed to load Settings.ini" error, then the same "'library_list' timed out" hang we saw
# after papering over that) and the working recipe in
# https://gist.github.com/Flydroid/8b1d5540dd64db50d48cf2d84455ecfe:
#
# An EMPTY Settings.ini (the earlier fix in this file's history) gets past "file not found", but
# leaves VIPM Desktop with no registered LabVIEW [Targets] entry to connect to - so it waits
# forever for a target that was never configured. And per the gist: "VIPM engine (the CLI attaches
# to it; if the CLI has to start it itself it hangs)" - exactly what our own diagnostics showed
# against the LUnit job (vipm.exe sitting nearly idle, LabVIEW.exe never launching, on every hang).
# Neither LabVIEW nor VIPM Desktop can be left for the CLI to launch on demand in this container;
# both have to be started and confirmed ready BEFORE any `vipm` command runs.
function Start-VipmStack {
    param([string]$LvExePath)
    $fi = (Get-Item $LvExePath).VersionInfo
    $ver = "{0}.{1} (64-bit)" -f $fi.ProductMajorPart, $fi.ProductMinorPart
    $lvIniPath = "/" + (($LvExePath -replace ":", "") -replace "\\", "/")

    $settingsDir = "C:\ProgramData\JKI\VIPM"
    $settingsFile = Join-Path $settingsDir "Settings.ini"
    if (-not (Test-Path $settingsFile)) {
        New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
        @"
[General]
check for updates on startup?="FALSE"
Check new ver. of App. on startup?="FALSE"
Suppress Download warning?="TRUE"
Mass Compile After Package Install?="FALSE"
IsFirstLaunch="FALSE"

[Targets]
Names.<size(s)>="1"
Names 0="LabVIEW"
Versions.<size(s)>="1"
Versions 0="$ver"
Locations.<size(s)>="1"
Locations 0="$lvIniPath"
Ports="<size(s)=1> 3363"
Tested.<size(s)>="1"
Tested 0="TRUE"
Disabled.<size(s)>="1"
Disabled 0="FALSE"
Connection Timeout="120"
Active Target.Name="LabVIEW"
Active Target.Version="$ver"
CommunityEdition.<size(s)>="1"
CommunityEdition 0="TRUE"
"@ | Set-Content -Path $settingsFile -Encoding ASCII
        Write-Host "Seeded $settingsFile with a [Targets] entry for LabVIEW $ver"
    } else {
        Write-Host "$settingsFile already exists, leaving it alone"
    }

    if (-not (Get-Process -Name "LabVIEW" -ErrorAction SilentlyContinue)) {
        Write-Host "Starting $LvExePath --headless"
        Start-Process -FilePath $LvExePath -ArgumentList "--headless"
        $deadline = (Get-Date).AddSeconds(180)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect("127.0.0.1", 3363)
                if ($client.Connected) { $client.Close(); $ready = $true; break }
            } catch {
                Start-Sleep -Seconds 3
            }
        }
        if ($ready) { Write-Host "LabVIEW VI Server ready on port 3363" } else { Write-Host "WARNING: port 3363 never opened after 180s" }
    } else {
        Write-Host "LabVIEW already running"
    }

    if (-not (Get-Process -Name "VI Package Manager" -ErrorAction SilentlyContinue)) {
        $vipmDesktopExe = "C:\Program Files\JKI\VI Package Manager\VI Package Manager.exe"
        Write-Host "Starting $vipmDesktopExe"
        Start-Process -FilePath $vipmDesktopExe
        Write-Host "Waiting 45s for VIPM Desktop to initialize..."
        Start-Sleep -Seconds 45
    } else {
        Write-Host "VIPM Desktop already running"
    }
}

Install-Vipm
$vipm = Find-Tool -Name "vipm.exe"
Set-LabviewIniConfig -LabviewYear $LabviewYear
$lvExePath = Find-LabviewExe
Write-Host "Found LabVIEW.exe: $lvExePath"
Start-VipmStack -LvExePath $lvExePath

# Recommended by https://docs.vipm.io/preview/cli/docker/ before every install, to avoid stale
# caches.
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

# DIAGNOSTIC, not (yet) load-bearing: against the LUnit job (same image), applying its .vipc has
# twice produced zero output after "[VIPM] 105.9%" until the liveliness timeout kills it -
# indistinguishable, at this verbosity, between "genuinely deadlocked" and "cold-compiling many
# packages with no progress reporting for that phase." Installing one tiny, well-known package
# (the exact one NI's own docs use as an example) with a short timeout answers that cheaply: if
# THIS also hangs, the problem is VIPM Desktop/LabVIEW communication itself, not this job's package
# set. Non-fatal either way - the real install below still runs regardless of this result.
Write-Host "=== Diagnostic: installing a single small package (oglib_boolean) with a short timeout ==="
$prevTimeout = $env:VIPM_DESKTOP_LIVELINESS_TIMEOUT
$env:VIPM_DESKTOP_LIVELINESS_TIMEOUT = "90"
& $vipm install oglib_boolean --labview-version $LabviewYear --labview-bitness $LabviewBitness -y
$smokeTestExit = $LASTEXITCODE
$env:VIPM_DESKTOP_LIVELINESS_TIMEOUT = $prevTimeout
if ($smokeTestExit -eq 0) {
    Write-Host "Diagnostic install SUCCEEDED - VIPM Desktop/LabVIEW communication works for a trivial package"
} else {
    Write-Host "Diagnostic install FAILED/HUNG (exit $smokeTestExit) - problem is not specific to our .vipc's package set"
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
