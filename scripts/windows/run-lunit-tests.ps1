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

# UNVERIFIED GUESS, not yet confirmed from a log line: `vipm install` reached "[VIPM] 105.9%" and
# then produced literally zero further output for the full 600s liveliness timeout - a genuine
# hang, not slow progress. VIPM Desktop launches LabVIEW itself to actually apply packages; the
# leading theory, by analogy with the Linux job's setup_container.sh (which writes labview.conf
# keys like autoerr=3 for exactly this reason - see
# https://forums.ni.com/t5/Continuous-Integration/Preemptively-disable-internal-error-dialog/td-p/4407330),
# is that LabVIEW hit an internal dialog with no one to click it in a headless container. This
# pre-seeds the Windows equivalent (LabVIEW.ini) with the same keys before anything launches
# LabVIEW. If the hang recurs anyway, this theory was wrong and the ini edit did nothing harmful.
function Set-LabviewDialogSuppression {
    param([int]$LabviewYear)
    $labviewDir = "${env:ProgramFiles}\National Instruments\LabVIEW $LabviewYear"
    if (-not (Test-Path $labviewDir)) {
        Write-Host "LabVIEW install dir not found at '$labviewDir' - skipping dialog suppression"
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
    }
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
    Write-Host "Updated $iniPath with dialog-suppression keys"
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

Install-Vipm
$vipm = Find-Tool -Name "vipm.exe"
Set-LabviewDialogSuppression -LabviewYear $LabviewYear

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
    $smokeProc.WaitForExit()
}
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

$reportDir = Split-Path -Parent $ReportPath
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
if (Test-Path $ReportPath) { Remove-Item $ReportPath -Force }

Write-Host "=== Running LUnit tests ==="
& $gcli --kill --kill-timeout 5000 lunit -- -r $ReportPath $ProjectPath
exit $LASTEXITCODE
