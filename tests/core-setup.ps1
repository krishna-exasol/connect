#!/usr/bin/env pwsh
# core-setup.ps1 - the Windows twin of tests/core-setup.sh, run rather than
# grepped: setup\lib\core-setup.ps1 is dot-sourced as-is and the kit around it
# is replaced by stubs. The Python coordinators under setup\core are the REAL
# ones, so what is pending, what gets recorded and how the installer is rerun
# are exactly what a Windows machine runs.
#
#   1. tasks / pending / complete through Invoke-ExakitPythonFile, including
#      that no empty argument ever reaches a native command.
#   2. The database step: the handler's LAST output is its verdict, and a task
#      is recorded only after its step passed.
#   3. `exakit update`'s pending-task check: scoped updates, reruns and a
#      stopped database are left alone; a pending task reruns the installer
#      once, pinned to the installed versions, and the pins do not leak.
#   4. The handover: the new exakit.ps1 runs once, its --json rows are merged
#      back, and the environment is restored.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/core-setup.ps1
#   pwsh -NoProfile -File tests/core-setup.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$expected>, got <$actual>" }
}
function Has($label, $needle, $haystack) {
    if ("$haystack".Contains($needle)) { $script:PASS++; Write-Host "  ok   $label" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected <$needle> in <$haystack>" }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-core-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

# The kit runs `python`. Where only python3 exists (macOS, many Linux images),
# a shim directory supplies the name.
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py3) { Write-Host "python is required for this suite"; exit 1 }
    $shim = Join-Path $work "shim"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $shim "python") -Target $py3.Source | Out-Null
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
}

# --- the kit around the module, replaced -------------------------------------
$script:ExakitHome = Join-Path $work "home"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:LogFile = Join-Path $work "setup.log"
$script:ManagedPythonVersion = "3.12"
$script:ExakitUpdateJson = $false
New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
$script:events = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$script:events.Add($Text) }
function Test-ExakitSystemPython { return $true }
function Install-ExakitUv { throw "uv must not be needed here" }
function Write-ExakitLog { param($Level, $Msg) Add-Content -LiteralPath $script:LogFile -Value "$Level $Msg" }
function Info([string]$Msg) { Note "INFO $Msg" }
function Ok([string]$Msg) { Note "OK $Msg" }
function OkStep([string]$Msg) { Note "OKSTEP $Msg" }
function Warn2([string]$Msg) { Note "WARN $Msg" }
function Get-ExakitManifestValue {
    param([string]$Path)
    $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    $node = $doc
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
function Get-ExakitComponentCurrent { param([string]$Component) if ($Component -eq "personal") { return "2.3.0" }; return $null }
function Test-PersonalDeploymentRunning { return ($env:FAKE_DB_UP -ne "0") }
function Get-ExakitRepoRoot { return (Join-Path $script:ExakitHome "kit") }
$script:notes = New-Object System.Collections.ArrayList
function Add-ExakitUpdateNote {
    param([string]$Component, [string]$Outcome, [string]$From = "", [string]$To = "", [string]$Remedy = "")
    [void]$script:notes.Add("$Component|$Outcome|$From|$To|$Remedy")
}

. (Join-Path $repo (Join-Path "setup" (Join-Path "lib" "core-setup.ps1")))

function New-Manifest { Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {}, "kit": {"source": "exasol-labs/kit@main"}}' -Encoding ASCII }
function Get-Completed {
    $doc = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
    if (-not $doc.PSObject.Properties["core_tasks"]) { return "" }
    return (@($doc.core_tasks.completed) -join ",")
}

Write-Host ""
Write-Host "== the handler map and the task list =="
foreach ($name in $script:ExakitCoreTaskHandlers.Keys) {
    Check "handler for $name is a function in core-setup.ps1" $true ([bool](Get-Command $script:ExakitCoreTaskHandlers[$name] -ErrorAction SilentlyContinue))
}
Check "the shipped list's database tasks" "preprocessor" ((Get-ExakitCoreTasks -KitRoot $repo -Scope "database") -join ",")
Check "...and nothing else in the kit scope" "" ((Get-ExakitCoreTasks -KitRoot $repo -Scope "kit") -join ",")

Write-Host ""
Write-Host "== pending and complete through the real manage.py =="
New-Manifest
Check "a fresh manifest: the preprocessor is pending" "preprocessor" ((Get-ExakitCorePending -KitRoot $repo) -join ",")
Check "complete records it" $true (Complete-ExakitCoreTask -KitRoot $repo -Name "preprocessor")
Check "...and nothing is pending any more" "" ((Get-ExakitCorePending -KitRoot $repo) -join ",")
$script:events.Clear()
Check "an unknown task is refused" $false (Complete-ExakitCoreTask -KitRoot $repo -Name "nope")
Has "...with a warning that names it" "nope" ($script:events -join "|")
Check "a kit copy without setup\core reads as unknown, not as nothing pending" $true ($null -eq (Get-ExakitCorePending -KitRoot $work))

Write-Host ""
Write-Host "== the database step =="
function Begin-ExakitStep { param($Name, $Description) Note "STEP $Description"; return $true }
function Register-ExakitSoftFailure { param($Component, $Repair, $Reason = "", $Label = "") Note "SOFT $Component|$Repair|$Reason" }
function Set-ExakitFailureReason { param([string]$Reason) $script:reason = $Reason }
function Get-ExakitFailureReason { $r = $script:reason; $script:reason = ""; return $r }
function Invoke-ExakitSoftStep {
    param($Component, $Repair, $Body, $Label = "")
    $result = & $Body
    if ($result -is [bool] -and -not $result) { Register-ExakitSoftFailure -Component $Component -Repair $Repair -Reason (Get-ExakitFailureReason); return $false }
    return $true
}
New-Manifest
$script:events.Clear()
function Invoke-ExakitCoreTaskPreprocessor { param($KitRoot) "a leaked pipeline object"; Set-ExakitFailureReason "the slot is taken"; return $false }
Invoke-ExakitCoreDatabaseStep -Label "Step 4/7  Configure database features" -KitRoot $repo
Has "a handler that leaked output and then failed is a failure" "SOFT preprocessor|exakit update|the slot is taken" ($script:events -join "|")
Check "...and nothing is recorded" "" (Get-Completed)
function Invoke-ExakitCoreTaskPreprocessor { param($KitRoot) OkStep "fake framework ready"; return $true }
$script:events.Clear()
Invoke-ExakitCoreDatabaseStep -Label "Step 4/7  Configure database features" -KitRoot $repo
Has "the step announces itself" "STEP Step 4/7  Configure database features" ($script:events -join "|")
Check "a passing handler records the task" "preprocessor" (Get-Completed)

Write-Host ""
Write-Host "== exakit update: the pending-task check =="
$kit = Join-Path $script:ExakitHome "kit"
$kitSetup = Join-Path $kit "setup"
New-Item -ItemType Directory -Force -Path $kitSetup | Out-Null
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "core")) $kitSetup
$calls = Join-Path $work "installer-calls"
$fakeInstaller = @'
param()
Add-Content -LiteralPath '__CALLS__' -Value ("ran " + $env:EXAKIT_CORE_RERUN + " " + $env:EXAKIT_PERSONAL_VERSION + " " + $env:EXAKIT_KIT_SOURCE)
if ($env:FAKE_TASK_FAILS -ne "1") {
    & python (Join-Path (Join-Path (Join-Path '__KIT__' 'setup') 'core') 'manage.py') complete --tasks (Join-Path (Join-Path (Join-Path '__KIT__' 'setup') 'core') 'tasks.json') --manifest '__MANIFEST__' preprocessor
}
exit 0
'@
$fakeInstaller = $fakeInstaller.Replace("__CALLS__", $calls).Replace("__KIT__", $kit).Replace("__MANIFEST__", $script:ManifestPath)
Set-Content -LiteralPath (Join-Path $kitSetup "setup-windows.ps1") -Value $fakeInstaller -Encoding ASCII

function Reset-Update { New-Manifest; Remove-Item -Force -LiteralPath $calls -ErrorAction SilentlyContinue; $script:notes.Clear(); $script:events.Clear() }

Reset-Update
Check "a scoped update leaves it alone" $true (Invoke-ExakitCoreUpdateCheck -Target "exapump")
Check "...nothing ran" $false (Test-Path -LiteralPath $calls)

Reset-Update
$env:EXAKIT_CORE_RERUN = "1"
[void](Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\EXAKIT_CORE_RERUN
Check "so does a check inside a rerun" $false (Test-Path -LiteralPath $calls)

Reset-Update
$env:FAKE_DB_UP = "0"
Check "a stopped database defers" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\FAKE_DB_UP
Check "...without running the installer" $false (Test-Path -LiteralPath $calls)
Check "...booked as deferred with the remedy" "core-setup|deferred||preprocessor|exakit start && exakit update" ($script:notes -join ";")
Check "...and counted as work" $true $script:ExakitCoreUpdateActed

Reset-Update
$env:EXAKIT_EXAPUMP_VERSION = "9.9.9-mine"
Check "a pending task reruns the installer and completes" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Check "...exactly once, as a rerun, pinned, with the kit source" "ran 1 2.3.0 exasol-labs/kit@main" ((Get-Content -LiteralPath $calls) -join "|")
Check "...booked as updated" "core-setup|updated||preprocessor|" ($script:notes -join ";")
Check "...the pins it set do not outlive the rerun" "" "$env:EXAKIT_PERSONAL_VERSION"
Check "...and a pin the caller set is left as it was" "9.9.9-mine" "$env:EXAKIT_EXAPUMP_VERSION"
Remove-Item Env:\EXAKIT_EXAPUMP_VERSION

Remove-Item -Force -LiteralPath $calls -ErrorAction SilentlyContinue
$script:notes.Clear()
Check "with nothing pending, nothing runs" $true (Invoke-ExakitCoreUpdateCheck -Target "all")
Check "...no installer" $false (Test-Path -LiteralPath $calls)
Check "...not counted as work" $false $script:ExakitCoreUpdateActed

Reset-Update
$env:FAKE_TASK_FAILS = "1"
Check "a rerun that leaves the task pending fails the check" $false (Invoke-ExakitCoreUpdateCheck -Target "all")
Remove-Item Env:\FAKE_TASK_FAILS
Check "...booked as failed with the retry" "core-setup|failed||preprocessor|exakit update" ($script:notes -join ";")

Write-Host ""
Write-Host "== exakit update: the handover =="
$handoverCalls = Join-Path $work "handover-calls"
$fakeExakit = @'
Add-Content -LiteralPath '__CALLS__' -Value ("new " + ($args -join " ") + " handover=" + $env:EXAKIT_UPDATE_HANDOVER)
if ($env:EXAKIT_UPDATE_RESULTS_FILE) { Add-Content -LiteralPath $env:EXAKIT_UPDATE_RESULTS_FILE -Value "exapump|updated|1.0|2.0|" }
exit 3
'@
Set-Content -LiteralPath (Join-Path $kitSetup "exakit.ps1") -Value $fakeExakit.Replace("__CALLS__", $handoverCalls) -Encoding ASCII
$script:ExakitUpdateJson = $true
$script:ExakitUpdateResults = New-Object System.Collections.ArrayList
$code = Invoke-ExakitUpdateHandover -Target "all" -AssumeYes $true
$script:ExakitUpdateJson = $false
Check "the new exakit.ps1 runs once, with the target and --yes" "new update all --yes handover=1" ((Get-Content -LiteralPath $handoverCalls) -join "|")
Check "...its exit code comes back" 3 $code
Check "...its --json rows are merged into this run's" "exapump|updated|1.0|2.0|" (($script:ExakitUpdateResults | ForEach-Object { "$($_.component)|$($_.outcome)|$($_.from)|$($_.to)|$($_.remedy)" }) -join ";")
Check "...and the handover variables are gone again" "|" ("$env:EXAKIT_UPDATE_HANDOVER|$env:EXAKIT_UPDATE_RESULTS_FILE")
Remove-Item -Force -LiteralPath (Join-Path $kitSetup "exakit.ps1")
Check "no new exakit.ps1: no handover" $true ($null -eq (Invoke-ExakitUpdateHandover -Target "all"))

Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
