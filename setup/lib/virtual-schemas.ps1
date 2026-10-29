# virtual-schemas.ps1 - `exakit connect` and `exakit source <action>`: query an
# external database from the local one through an Exasol virtual schema.
#
# Twin of virtual-schemas.sh. Dot-sourced by exakit.ps1 after
# exakit-common.ps1, runtime-personal.ps1 and pyexasol.ps1. The work is the
# shared Python engine in setup\virtual-schemas\engine, run with the kit's
# pyexasol interpreter; this file supplies the deployment, asks the questions,
# keeps secrets off the command line, and repairs what the engine reports but
# cannot fix from inside the database:
#
#   exit 20  Java in the database has no DNS resolver -> Repair-PersonalSlcDns, retry once
#   exit 21  the Java language container is missing   -> `exasol slc install java` (asked), retry once

function Get-ExakitVsDefs {
    $root = Get-ExakitRepoRoot
    if ($root) {
        $defs = Join-ExakitCorePath $root "setup" "virtual-schemas"
        if (Test-Path -LiteralPath (Join-Path $defs "catalog.json")) { return $defs }
    }
    $here = Join-Path (Split-Path -Parent $PSScriptRoot) "virtual-schemas"
    if (Test-Path -LiteralPath (Join-Path $here "catalog.json")) { return $here }
    return $null
}

# Test-ExakitVsAvailable - can a source be connected from here? Twin of
# exakit_vs_available: the definitions are present and the kit's pyexasol,
# which runs the engine, is installed.
function Test-ExakitVsAvailable {
    if (-not (Get-ExakitVsDefs)) { return $false }
    if (-not (Get-Command Get-PyexasolVenvPython -ErrorAction SilentlyContinue)) { return $false }
    return (Test-Path -LiteralPath (Get-PyexasolVenvPython))
}

# Invoke-ExakitVsEngine - the engine with this installation's context. The
# secret, when there is one, goes to its stdin base64-encoded (and
# --secret-stdin becomes --secret-stdin-base64): Windows PowerShell 5.1
# re-encodes what it pipes to a native program - measured on CI, a
# byte-order mark added and every non-ASCII character turned into '?' even
# with $OutputEncoding set to UTF-8 - and plain ASCII survives every code
# page. Returns @{ Code; Lines }.
function Invoke-ExakitVsEngine {
    param([string[]]$Arguments = @(), [string]$Secret = "")
    $defs = Get-ExakitVsDefs
    if (-not $defs) { return [pscustomobject]@{ Code = 2; Lines = @("FAIL This kit copy has no setup\virtual-schemas. Update it: exakit update") } }
    $python = Get-PyexasolVenvPython
    if (-not (Test-Path -LiteralPath $python)) {
        return [pscustomobject]@{ Code = 2; Lines = @("FAIL Virtual schemas run with the kit's pyexasol, which is not installed. Repair it: exakit update pyexasol") }
    }
    $argv = @((Join-ExakitCorePath $defs "engine" "cli.py"), "--defs", $defs, "--kit-home", $script:ExakitHome)
    # An empty value is never passed: 5.1 drops it and the option before it
    # would swallow the next one.
    foreach ($pair in @(@("--deployment-dir", "runtime.deployment_dir"), @("--dsn", "runtime.dsn"),
                        @("--user", "runtime.user"), @("--password-file", "runtime.password_file"))) {
        $value = "" + (Get-ExakitManifestValue $pair[1])
        if ($value) { $argv += @($pair[0], $value) }
    }
    if ($Secret) {
        $argv += @($Arguments | ForEach-Object { if ($_ -eq "--secret-stdin") { "--secret-stdin-base64" } else { $_ } })
    } else {
        $argv += $Arguments
    }
    $errFile = [System.IO.Path]::GetTempFileName()
    $previous = $ErrorActionPreference
    $previousEncoding = $OutputEncoding
    try {
        $ErrorActionPreference = "Continue"
        if ($Secret) {
            $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Secret))
            $lines = @($encoded | & $python @argv 2> $errFile)
            $encoded = $null
        } else {
            $lines = @(& $python @argv 2> $errFile)
        }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        $OutputEncoding = $previousEncoding
    }
    foreach ($line in @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)) {
        if ("$line".Trim()) { Write-ExakitLog "VS" "$line" }
    }
    Remove-Item -Force -LiteralPath $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $code; Lines = @($lines | ForEach-Object { "$_" }) }
}

# Show-ExakitVsLines - the engine's event lines in the kit's own marks; the
# RESULT object is returned, parsed, or $null.
function Show-ExakitVsLines {
    param([string[]]$Lines = @())
    $result = $null
    foreach ($line in $Lines) {
        if ($line -like "OK *") { Ok $line.Substring(3) }
        elseif ($line -like "INFO *") { Info $line.Substring(5) }
        elseif ($line -like "WARN *") { Warn2 $line.Substring(5) }
        elseif ($line -like "FAIL *") { Write-Host ("  {0} {1}" -f $script:UiCross, $line.Substring(5)) -ForegroundColor Red; Write-ExakitLog "ERROR" $line.Substring(5) }
        elseif ($line -like "RESULT *") { try { $result = $line.Substring(7) | ConvertFrom-Json } catch { } }
        elseif ("$line".Trim()) { Write-Host $line }
    }
    return $result
}

function Read-ExakitVsSecret {
    param([string]$Label, [string]$PasswordFile = "", [string]$Kind = "secret")
    if ($PasswordFile) {
        if (-not (Test-Path -LiteralPath $PasswordFile)) { Deny-ExakitInput "Cannot read $PasswordFile" }
        return ((Get-Content -Raw -LiteralPath $PasswordFile) -replace "[\r\n]+$", "")
    }
    if (-not (Test-ExakitInteractive)) { Deny-ExakitInput "No $Label was given: use --password-file (a credential is never taken as an argument)." }
    if ($Kind -eq "secret-file") {
        # A key file is asked for by its path - nobody pastes a JSON key into a hidden prompt.
        $path = Read-ExakitPrompt "$Label - path to the file" ""
        if ($path -like "~*") { $path = $HOME + $path.Substring(1) }
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { Deny-ExakitInput "Cannot read $path" }
        return ((Get-Content -Raw -LiteralPath $path) -replace "[\r\n]+$", "")
    }
    Write-Host ("    {0}?{1} {2} (input hidden): " -f $script:UiAsk, $script:UiReset, $Label) -NoNewline
    $secure = Read-Host -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# Get-ExakitVsSecretKind - the kind of a connector's credential input (secret
# or secret-file), empty when it has none. Twin of _exakit_vs_secret_kind.
function Get-ExakitVsSecretKind {
    param([string]$Connector)
    $defs = Get-ExakitVsDefs
    if (-not $defs -or -not $Connector) { return "" }
    $file = Join-ExakitCorePath $defs "connectors" $Connector "connector.json"
    if (-not (Test-Path -LiteralPath $file)) { return "" }
    $spec = @((Get-Content -Raw -LiteralPath $file | ConvertFrom-Json).inputs) | Where-Object { $_.kind -in @("secret", "secret-file") } | Select-Object -First 1
    if ($spec) { return "" + $spec.kind }
    return ""
}

function Confirm-ExakitVs {
    param([string]$Question)
    if ($script:ExakitVsAssumeYes) { return $true }
    if (-not (Test-ExakitInteractive)) { return $false }
    $answer = Read-ExakitPrompt "$Question [y/N]" "N"
    return ($answer -match '^(y|yes)$')
}

# Install-ExakitVsJava - the Java language container, with consent: about 250
# MiB and one restart, through the exakit command's own stop/start so add-on
# services come back. Twin of _exakit_vs_install_java.
# Install-ExakitVsRust - the Rust language container a native adapter
# (Profile D) runs in, with consent: the exasol-labs build pinned for this CPU
# in profiles\rust-native, size- and SHA-256-checked, registered as the RUST
# alias, then one restart. Twin of _exakit_vs_install_rust.
function Install-ExakitVsRust {
    $defs = Get-ExakitVsDefs
    $custom = (Get-Content -Raw -LiteralPath (Join-ExakitCorePath $defs "profiles" "rust-native" "profile.json") | ConvertFrom-Json).slc.custom
    $arch = "x86_64"
    if ("$env:PROCESSOR_ARCHITECTURE" -eq "ARM64") { $arch = "aarch64" }
    $pin = $custom.arch.$arch
    if (-not $pin) { Write-Host "  There is no Rust language container build for this CPU ($arch)." -ForegroundColor Red; return $false }
    Info "This source runs a native adapter inside the database, and its Rust language container is not installed."
    Info ("Installing it downloads {0} {1} (about {2} MiB, checksum-pinned) and restarts the database once (add-on services restart with it)." -f $custom.upstream, $custom.version, [int]([double]$pin.size / 1048576))
    if (-not (Confirm-ExakitVs "Install the Rust language container now?")) {
        Info "Nothing was installed. Run the same exakit connect again when you are ready."
        return $false
    }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-rust-" + [guid]::NewGuid().ToString("N"))
    $file = Join-Path $dir $pin.asset
    try {
        Get-ExakitFile -Url $pin.url -Dest $file
        $size = (Get-Item -LiteralPath $file).Length
        if ("$size" -ne "$($pin.size)") {
            Write-Host ("  The Rust language container download is {0} bytes, not the pinned {1}; nothing was installed." -f $size, $pin.size) -ForegroundColor Red
            return $false
        }
        if ((Get-ExakitSha256 -Path $file) -ne "$($pin.sha256)") {
            Write-Host "  The Rust language container download does not match its pinned checksum; nothing was installed." -ForegroundColor Red
            return $false
        }
        $slcArgs = @("slc", "custom", "install", "--source", $file, "--alias", "RUST", "--language", "rust", "--no-restart")
        $flag = Get-PersonalAutoApproveFlag "slc"
        if ($flag) { $slcArgs += $flag }
        if ((Invoke-ExakitLogged (Get-PersonalCli) @slcArgs) -ne 0) {
            Write-Host ("  {0} The Rust language container did not install. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red
            return $false
        }
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
    }
    $exakit = Join-Path $script:BinDir "exakit.cmd"
    $previousStop = $env:EXAKIT_STOP_ADDONS
    try {
        $env:EXAKIT_STOP_ADDONS = "1"
        & $exakit stop *> $null
    } finally { $env:EXAKIT_STOP_ADDONS = $previousStop }
    & $exakit start | Out-Host
    Ok "Rust language container installed"
    return $true
}

function Install-ExakitVsJava {
    Info "Virtual schemas run Java inside the database, and its Java language container is not installed."
    Info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
    if (-not (Confirm-ExakitVs "Install the Java language container now?")) {
        Info "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
        return $false
    }
    $slcArgs = @("slc", "install", "java", "--no-restart")
    $flag = Get-PersonalAutoApproveFlag "slc"
    if ($flag) { $slcArgs += $flag }
    if ((Invoke-ExakitLogged (Get-PersonalCli) @slcArgs) -ne 0) {
        Write-Host ("  {0} The Java language container did not install. Details: exakit logs" -f $script:UiCross) -ForegroundColor Red
        return $false
    }
    $exakit = Join-Path $script:BinDir "exakit.cmd"
    $previousStop = $env:EXAKIT_STOP_ADDONS
    try {
        $env:EXAKIT_STOP_ADDONS = "1"
        & $exakit stop *> $null
    } finally { $env:EXAKIT_STOP_ADDONS = $previousStop }
    & $exakit start | Out-Host
    try { [void](Repair-PersonalSlcDns) } catch { }
    Ok "Java language container installed"
    return $true
}

# Invoke-ExakitVsRun - the engine once, repairing DNS (exit 20) or installing
# Java (exit 21) and retrying once. Twin of _exakit_vs_run.
function Invoke-ExakitVsRun {
    param([string[]]$Arguments, [string]$Secret = "")
    $script:ExakitVsResult = $null
    for ($try = 1; $try -le 2; $try++) {
        $run = Invoke-ExakitVsEngine -Arguments $Arguments -Secret $Secret
        $script:ExakitVsResult = Show-ExakitVsLines -Lines $run.Lines
        if ($try -eq 2) { break }
        if ($run.Code -eq 20) {
            Info "Giving the database's language containers the deployment's DNS, then trying again"
            if (-not (Repair-PersonalSlcDns)) { Write-Host "  DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again." -ForegroundColor Red; break }
        } elseif ($run.Code -eq 21) {
            if (-not (Install-ExakitVsJava)) { break }
        } elseif ($run.Code -eq 23) {
            if (-not (Install-ExakitVsRust)) { break }
        } else { break }
    }
    return $run.Code
}

# Show-ExakitVsDropPlan - what disconnect or remove drops, keeps and deletes.
# Twin of the "drop" branch of the renderer in cmd_source.
function Show-ExakitVsDropPlan {
    param($Plan)
    Write-Host ("  drops: " + (@($Plan.drop) -join ", "))
    if ($Plan.keep) { Write-Host ("  keeps: " + (@($Plan.keep) -join ", ")) }
    if ($Plan.PSObject.Properties["delete_files"]) {
        Write-Host ("  deletes {0} unused file(s); keeps {1} still shared" -f @($Plan.delete_files).Count, @($Plan.keep_files).Count)
    }
    Write-Host ("  note: " + $Plan.note)
}

function Show-ExakitVsPlan {
    param($Plan)
    if ($null -eq $Plan) { return }
    Write-Host ("  Plan for {0} ({1}, {2}, {3})" -f $Plan.name, $Plan.connector, $Plan.tier, $Plan.status)
    foreach ($d in @($Plan.downloads)) {
        $verb = "download"
        if ($d.cached) { $verb = "reuse" }
        Write-Host ("    {0} {1} {2} ({3:N1} MB, {4})" -f $verb, $d.role, $d.version, ($d.bytes / 1e6), $d.license)
    }
    foreach ($step in @($Plan.steps)) { Write-Host "    - $step" }
    Write-Host "    Exposure: $($Plan.exposure)"
    foreach ($w in @($Plan.warnings)) { if ($w) { Write-Host "    Warning: $w" } }
    if ($Plan.gate) { Write-Host "    Not available yet: $($Plan.gate)" }
}
