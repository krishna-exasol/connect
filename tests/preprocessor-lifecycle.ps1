#!/usr/bin/env pwsh
# preprocessor-lifecycle.ps1 - the Windows bridge to the SQL preprocessor
# framework coordinator, run against the same simulated database as
# tests/preprocessor-lifecycle.sh (tests/lib/fake-exapump.py). The coordinator
# itself is the real setup\preprocessor\manage.py; that suite covers its every
# branch, so this one covers what the PowerShell side owns:
#
#   - the pin: the advertised one, or this kit copy's when the advertised one
#     needs a newer kit
#   - the package is fetched only when a fresh install asks for it, verified,
#     and cached by digest
#   - the coordinator's lines are rendered, and a FAIL line becomes the reason
#     the closing summary prints
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/preprocessor-lifecycle.ps1
#   pwsh -NoProfile -File tests/preprocessor-lifecycle.ps1
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

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-preproc-ps-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py3) { Write-Host "python is required for this suite"; exit 1 }
    $shim = Join-Path $work "shim"
    New-Item -ItemType Directory -Force -Path $shim | Out-Null
    New-Item -ItemType SymbolicLink -Path (Join-Path $shim "python") -Target $py3.Source | Out-Null
    $env:PATH = $shim + [System.IO.Path]::PathSeparator + $env:PATH
}
$pythonExe = (Get-Command python).Source

# The stand-in exapump, runnable the way manage.py runs the real binary.
$fake = Join-Path $repo (Join-Path "tests" (Join-Path "lib" "fake-exapump.py"))
if ($isWin) {
    $exapump = Join-Path $work "exapump.cmd"
    Set-Content -LiteralPath $exapump -Value "@echo off`r`n`"$pythonExe`" `"$fake`" %*`r`n" -Encoding ASCII
} else {
    $exapump = Join-Path $work "exapump"
    Set-Content -LiteralPath $exapump -Value "#!/bin/sh`nexec `"$pythonExe`" `"$fake`" `"`$@`"`n" -Encoding ASCII
    & chmod +x $exapump
}

# A small package with the real release.sql's shape.
$pkg = Join-Path $work "release.sql"
$sql = "CREATE ROLE PREPROC_ADMIN;`nCREATE SCHEMA IF NOT EXISTS PREPROC;`nCREATE SCHEMA IF NOT EXISTS PREPROC_RT;`n"
foreach ($s in @("PREPROC_RT.MASTER", "PREPROC_RT.CONTROL_SUGAR_V1", "PREPROC.REFRESH_CORE", "PREPROC.REFRESH",
                 "PREPROC.STATUS", "PREPROC.RULE_ENSURE", "PREPROC.RULE_DROP", "PREPROC.RULE_LIST")) {
    $sql += "--/`nCREATE OR REPLACE LUA SCRIPT $s() AS`nlocal a = 1`n/`n"
}
$sql += "--/`nCREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1(s VARCHAR(10)) EMITS (r VARCHAR(10)) AS`ndef run(ctx):`n    ctx.emit('OK')`n/`n"
$sql += "INSERT INTO PREPROC.CONFIG (rule_id) SELECT 1;`n"
[System.IO.File]::WriteAllText($pkg, $sql)
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pkg).Hash.ToLowerInvariant()
$derive = & $pythonExe (Join-Path $repo (Join-Path "setup" (Join-Path "preprocessor" "manage.py"))) derive --package $pkg
$core = ($derive | ConvertFrom-Json).sha256

# A kit copy: the real coordinators, and a versions.json pinning the package.
$kit = Join-Path $work "kit"
$kitSetup = Join-Path $kit "setup"
New-Item -ItemType Directory -Force -Path $kitSetup | Out-Null
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "core")) $kitSetup
Copy-Item -Recurse -Force (Join-Path $repo (Join-Path "setup" "preprocessor")) $kitSetup
$versions = Get-Content -Raw -LiteralPath (Join-Path $repo "versions.json") | ConvertFrom-Json
$versions.components.preprocessor.sha256."release-sql" = $sha
$versions.components.preprocessor.sha256."core-only" = $core
$versions | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $kit "versions.json") -Encoding ASCII
# The "advertised" document: the same pin, unless a test says otherwise.
$advertised = Join-Path $work "advertised.json"
Copy-Item -Force (Join-Path $kit "versions.json") $advertised

# --- the kit around the module, replaced -------------------------------------
$script:ExakitHome = Join-Path $work "home"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:LogFile = Join-Path $work "setup.log"
$script:ExapumpProfile = "starter-kit"
$script:ManagedPythonVersion = "3.12"
New-Item -ItemType Directory -Force -Path $script:ExakitHome | Out-Null
$script:events = New-Object System.Collections.ArrayList
$script:fetches = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$script:events.Add($Text) }
function Test-ExakitSystemPython { return $true }
function Install-ExakitUv { throw "uv must not be needed here" }
function Write-ExakitLog { param($Level, $Msg) Add-Content -LiteralPath $script:LogFile -Value "$Level $Msg" }
function Info([string]$Msg) { Note "INFO $Msg" }
function OkStep([string]$Msg) { Note "OKSTEP $Msg" }
function Warn2([string]$Msg) { Note "WARN $Msg" }
function Set-ExakitFailureReason { param([string]$Reason) $script:reason = $Reason }
function Get-ExakitManifestValue { param([string]$Path) if ($Path -eq "runtime.user") { return "sys" }; return $null }
function Get-ExapumpCli { return $exapump }
function Get-ExakitComponentCurrent { param([string]$Component) return "0.3.0" }
function Test-ExakitVersionNewer {
    param([string]$Latest, [string]$Current)
    return ([version]($Latest -replace '[^0-9.]', '') -gt [version]($Current -replace '[^0-9.]', ''))
}
function Get-ExakitVersionsValue {
    param([string]$Path, [string]$DocPath = "")
    if (-not $DocPath) { $DocPath = $advertised }
    $node = Get-Content -Raw -LiteralPath $DocPath | ConvertFrom-Json
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $null }
        $node = $node.$part
    }
    return $node
}
function Invoke-ExakitWithSpinner { param($Label, $Body) return (& $Body) }
function Get-ExakitFile {
    param([string]$Url, [string]$Dest)
    [void]$script:fetches.Add($Url)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
    Copy-Item -Force -LiteralPath $pkg -Destination $Dest
}
function Test-ExakitSha256 {
    param([string]$Path, [string]$Expected)
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() -ne $Expected) { throw "checksum mismatch" }
}

. (Join-Path $repo (Join-Path "setup" (Join-Path "lib" "core-setup.ps1")))

$state = Join-Path $work "state.json"
$env:FAKE_EXAPUMP_STATE = $state
function Reset-Db([string]$Json = "{}") {
    Set-Content -LiteralPath $state -Value $Json -Encoding ASCII
    Set-Content -LiteralPath $script:ManifestPath -Value '{"components": {}}' -Encoding ASCII
    $script:events.Clear(); $script:fetches.Clear(); $script:reason = ""
}
function Get-Db([string]$Key) { return ((Get-Content -Raw -LiteralPath $state | ConvertFrom-Json).$Key) }

Write-Host ""
Write-Host "== the pin =="
$pin = Get-ExakitCorePreprocessorPin -KitRoot $kit
Check "the advertised pin is used, both digests" "0.9.1 v0.9.1 release.sql exasol-labs/preprocessor-framework $sha $core" "$($pin.Version) $($pin.Ref) $($pin.Asset) $($pin.Repo) $($pin.Sha256) $($pin.CoreSha256)"
$ahead = Get-Content -Raw -LiteralPath $advertised | ConvertFrom-Json
$ahead.components.preprocessor.version = "0.10.0"
$ahead.components.preprocessor.min_kit_version = "0.9.0"
$ahead | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $advertised -Encoding ASCII
$pin = Get-ExakitCorePreprocessorPin -KitRoot $kit
Check "an advertised pin that needs a newer kit falls back to this kit copy's" "0.9.1" $pin.Version
Copy-Item -Force (Join-Path $kit "versions.json") $advertised

Write-Host ""
Write-Host "== a fresh database =="
Reset-Db
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "installed, tested and activated" $true $ok
Check "the package was fetched once, from the pinned release asset" "https://github.com/exasol-labs/preprocessor-framework/releases/download/v0.9.1/release.sql" ($script:fetches -join "|")
$cached = Join-ExakitCorePath $script:ExakitHome "cache" "preprocessor" $sha "release.sql"
Check "...into the digest-keyed cache" $true (Test-Path -LiteralPath $cached)
Has "the coordinator's lines are rendered" "OKSTEP SQL preprocessor framework 0.9.1 installed, tested and activated" ($script:events -join "|")
Check "the dispatcher holds the slot" "PREPROC_RT.MASTER" (Get-Db "system_slot")
Check "...on a database with no Python: the resolver was left out" $false ((Get-Db "scripts") -contains "PREPROC.MODULE_RESOLVER_V1")

Write-Host ""
Write-Host "== a second pass =="
$script:events.Clear(); $script:fetches.Clear()
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "verifies" $true $ok
Check "...without fetching anything" 0 $script:fetches.Count
Has "...and says so" "verified and active" ($script:events -join "|")

Write-Host ""
Write-Host "== a slot someone else holds =="
Reset-Db '{"system_slot": "OTHER.SCRIPT"}'
$ok = @(Invoke-ExakitCoreTaskPreprocessor -KitRoot $kit)[-1]
Check "is a failure for the summary" $false $ok
Has "...whose reason names the holder" "OTHER.SCRIPT" $script:reason
Check "...and the slot is untouched" "OTHER.SCRIPT" (Get-Db "system_slot")

Remove-Item Env:\FAKE_EXAPUMP_STATE
Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:PASS, $script:FAIL)
if ($script:FAIL -gt 0) { exit 1 }
exit 0
