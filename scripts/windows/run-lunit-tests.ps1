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
# Matches the working configuration in https://gist.github.com/Flydroid/8b1d5540dd64db50d48cf2d84455ecfe
# (an independent, confirmed-working recipe for this exact container/VIPM combination - see the
# Start-VipmStack comment below for the full story).
$env:CI = "true"
$env:GITHUB_ACTIONS = "true"
$env:NO_COLOR = "1"

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
    # Confirmed on CI: wiresmith_technology_lib_g_cli's VIPM package does NOT install g-cli.exe
    # under National Instruments or JKI - widen to the whole Program Files trees before giving up.
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
# diagnostics from a later CI run showed LabVIEW.exe never launches at all during the hang, and
# VIPM Desktop (the "VI Package Manager" process) sits nearly idle (~4s of CPU burned across 105s
# of wall time) rather than actually computing - a real blocked wait, not a dialog and not slow
# work. The leading theory now: VIPM has driven LabVIEW via VI Server (or the ActiveX equivalent
# on Windows) for package installs for a very long time, and per
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

# Captures every visible top-level window (title + a PrintWindow screenshot) plus a process list,
# so that if `vipm install` hangs again we can actually see what's on screen instead of guessing -
# a Windows container has no interactive desktop, but PrintWindow with PW_RENDERFULLCONTENT can
# still capture a GUI app's window content even so (verified locally against a real window before
# relying on it here). Screenshots land under $DiagDir, which the workflow uploads as an artifact.
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32Diag {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
"@
function Save-WindowScreenshots {
    param([string]$OutDir, [string]$Tag)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = {
        param($hWnd, $lParam)
        if ([Win32Diag]::IsWindowVisible($hWnd)) {
            $len = [Win32Diag]::GetWindowTextLength($hWnd)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 1)
                [Win32Diag]::GetWindowText($hWnd, $sb, $sb.Capacity) | Out-Null
                $procId = 0
                [Win32Diag]::GetWindowThreadProcessId($hWnd, [ref]$procId) | Out-Null
                $windows.Add([PSCustomObject]@{ Handle = $hWnd; Title = $sb.ToString(); ProcessId = $procId })
            }
        }
        return $true
    }
    [Win32Diag]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    Write-Host "[$Tag] Found $($windows.Count) visible titled window(s)"
    foreach ($w in $windows) {
        $procName = (Get-Process -Id $w.ProcessId -ErrorAction SilentlyContinue).ProcessName
        Write-Host "[$Tag] Window: '$($w.Title)' (process: $procName, pid $($w.ProcessId))"
        try {
            $rect = New-Object Win32Diag+RECT
            [Win32Diag]::GetWindowRect($w.Handle, [ref]$rect) | Out-Null
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            if ($width -le 0 -or $height -le 0) { continue }
            $bmp = New-Object System.Drawing.Bitmap $width, $height
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $hdc = $g.GetHdc()
            [Win32Diag]::PrintWindow($w.Handle, $hdc, 2) | Out-Null
            $g.ReleaseHdc($hdc)
            $safeTitle = ($w.Title -replace '[^\w\-]', '_')
            if ($safeTitle.Length -gt 40) { $safeTitle = $safeTitle.Substring(0, 40) }
            $path = Join-Path $OutDir "$Tag--$procName-$($w.ProcessId)--$safeTitle.png"
            $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose(); $bmp.Dispose()
        } catch {
            Write-Host "[$Tag] Failed to capture '$($w.Title)': $_"
        }
    }
    Get-Process | Select-Object Id, ProcessName, CPU, WorkingSet, StartTime | Sort-Object ProcessName |
        Format-Table -AutoSize | Out-String -Width 200 | Out-File (Join-Path $OutDir "$Tag--processes.txt")
}
$DiagDir = "C:\workspace\diagnostics"

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
# (vipm.exe sitting nearly idle, LabVIEW.exe never launching, on every hang). Neither LabVIEW nor
# VIPM Desktop can be left for the CLI to launch on demand in this container; both have to be
# started and confirmed ready BEFORE any `vipm` command runs.
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

# DIAGNOSTIC, not (yet) load-bearing: twice now, applying our own 9-package .vipc has produced
# zero output after "[VIPM] 105.9%" until the liveliness timeout kills it - a prior CI run showed
# this same single-package install ALSO hangs identically, ruling out "our package set is just
# slow to compile." This time, run it as a background process and screenshot every visible window
# every 15s while it runs, to actually see whether LabVIEW is stuck behind a dialog or something
# else entirely.
Write-Host "=== Diagnostic: installing a single small package (oglib_boolean) with a short timeout ==="
$prevTimeout = $env:VIPM_DESKTOP_LIVELINESS_TIMEOUT
$env:VIPM_DESKTOP_LIVELINESS_TIMEOUT = "90"
$smokeArgs = @("install", "oglib_boolean", "--labview-version", $LabviewYear, "--labview-bitness", $LabviewBitness, "-y")
Write-Host "vipm $($smokeArgs -join ' ')"
$smokeProc = Start-Process -FilePath $vipm -ArgumentList $smokeArgs -PassThru -NoNewWindow
$waited = 0
Save-WindowScreenshots -OutDir $DiagDir -Tag "smoketest-0s"
while (-not $smokeProc.HasExited -and $waited -lt 150) {
    Start-Sleep -Seconds 15
    $waited += 15
    Save-WindowScreenshots -OutDir $DiagDir -Tag "smoketest-${waited}s"
}
if (-not $smokeProc.HasExited) {
    Write-Host "Still running after ${waited}s - waiting for it to exit on its own"
}
# .NET quirk: ExitCode can read back empty unless WaitForExit() is called at least once, even if
# HasExited already reads true - confirmed on CI (printed "(exit )" with no code) - so call it
# unconditionally rather than only in the "still running" branch above.
$smokeProc.WaitForExit()
$smokeTestExit = $smokeProc.ExitCode
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

# g-cli launches and manages its OWN LabVIEW instance for the VI it runs, and per
# https://github.com/G-CLI/G-CLI/issues/196 (an almost exact match for this situation - two g-cli
# style invocations in one session, one against Caraya and one against LUnit, on the NI LabVIEW
# container image), a LabVIEW process left running from earlier breaks the connection handshake
# for the next one. `--kill` on the g-cli call below is not a reliable substitute: it most likely
# only tracks/kills processes g-cli itself launched, not the instance Start-VipmStack started by
# calling LabVIEW.exe directly - so that instance (needed only for the VIPM install phase, which
# is done now) has to be stopped ourselves before g-cli gets a clean slate to work with.
Write-Host "=== Stopping LabVIEW/VIPM Desktop before handing off to g-cli ==="
Get-Process -Name "LabVIEW" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process -Name "VI Package Manager" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

# The bare "lunit" alias doesn't resolve correctly: --verbose (added while chasing the previous
# hang) showed g-cli falling back to "Checking in vi.lib/G CLI Tools instead" and launching LabVIEW
# pointed at "...\vi.lib\G CLI Tools\lunit.vi" - a path the sas_workshops_lib_lunit_for_g_cli
# package's Windows install apparently doesn't actually use, so that VI never loads, never calls
# back, and g-cli times out waiting for a connection that was never coming. Same class of problem
# Caraya already had (see below) and the same fix: search for the actual VI and hand g-cli its real
# path directly instead of trusting alias resolution.
$niRoot = "${env:ProgramFiles}\National Instruments"
$lunitVi = $null
if (Test-Path $niRoot) {
    $match = Get-ChildItem -Path $niRoot -Filter "lunit.vi" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) { $lunitVi = $match.FullName }
}
if (-not $lunitVi) {
    throw "lunit.vi not found anywhere under '$niRoot' - the sas_workshops_lib_lunit_for_g_cli package may not have installed correctly."
}
Write-Host "Found lunit.vi: $lunitVi"

Write-Host "=== Running LUnit tests ==="
# --verbose: this failed with zero diagnostic detail last time ("Timed out waiting for app to
# connect to g-cli" and nothing else) - g-cli's own [DEBUG] output (see
# https://github.com/G-CLI/G-CLI/issues/171) shows what it actually launched and whether the
# process even started, which is exactly what's missing to make progress here.
# --timeout 300000: the failure hit at ~90s both times, close to what looks like a short default:
# a cold LabVIEW launch in this container has taken minutes elsewhere in this same script (LabVIEW
# --headless plus VIPM Desktop startup alone took over a minute), so 90s may simply not be enough.
& $gcli --kill --kill-timeout 5000 --timeout 300000 --verbose $lunitVi -- -r $ReportPath $ProjectPath
exit $LASTEXITCODE
