#!/usr/bin/env bash
# Language container DNS on Exasol Personal: the official script language
# containers ship etc/resolv.conf and etc/hosts EMPTY, so Java in the database
# (every virtual schema adapter) resolves no hostname. The kit points them at
# /conf after every database start, because every start rebuilds them.
#
# A stand-in podman keeps each container's etc/ as a real tar stream, so both
# routes are exercised byte for byte: the Python helper (Linux, WSL, Windows)
# and the POSIX sh script fed to the launcher VM's shell (macOS).
#
#   bash tests/personal-slc-dns.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' "$1" "$2" "$3"; fi; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fake podman: `ps` names the container unless FAKE_NO_CTR=1; `cp CTR:/exa/slc/F/etc -`
# streams $WORK/ctr/F/etc as tar; `cp - CTR:/exa/slc/F/etc/` extracts stdin there.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<EOF
#!/usr/bin/env python3
import io, os, sys, tarfile
root = "$WORK/ctr"
a = sys.argv[1:]
if a[0] == "ps":
    print("" if os.environ.get("FAKE_NO_CTR") == "1" else "exasol-db-test")
    sys.exit(0)
if a[0] == "cp" and a[2] == "-":
    flavor = a[1].split("/exa/slc/")[1].split("/")[0]
    path = os.path.join(root, flavor, "etc")
    if not os.path.isdir(path): sys.exit(1)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as t: t.add(path, arcname="etc")
    sys.exit(0)
if a[0] == "cp" and a[1] == "-":
    if os.environ.get("FAKE_CP_FAILS") == "1": sys.exit(1)
    flavor = a[2].split("/exa/slc/")[1].split("/")[0]
    with tarfile.open(fileobj=io.BytesIO(sys.stdin.buffer.read())) as t:
        for m in t.getmembers():
            dest = os.path.join(root, flavor, "etc", m.name)
            if os.path.lexists(dest): os.remove(dest)
            os.symlink(m.linkname, dest)
    sys.exit(0)
sys.exit(2)
EOF
chmod +x "$WORK/bin/podman"
ctr() { rm -rf "$WORK/ctr"; mkdir -p "$WORK/ctr/java-17/etc" "$WORK/ctr/python-3.12/etc"; : > "$WORK/ctr/java-17/etc/resolv.conf"; : > "$WORK/ctr/java-17/etc/hosts"; printf 'nameserver 9.9.9.9\n' > "$WORK/ctr/python-3.12/etc/resolv.conf"; }
link() { readlink "$WORK/ctr/$1/etc/$2" 2>/dev/null || echo "regular"; }
HELPER="$ROOT/setup/lib/personal-slc-dns.py"

printf '\n== the Python helper (Linux, WSL, Windows) ==\n'
ctr
OUT="$(PATH="$WORK/bin:$PATH" python3 "$HELPER" java-17 python-3.12 r-4.4)"; RC=$?
check "an empty resolv.conf is repaired" "EXAKIT_SLC_DNS java-17 repaired" "$(printf '%s\n' "$OUT" | grep java-17)"
check "...both files now point at /conf" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
check "a container that already has DNS is left alone" "EXAKIT_SLC_DNS python-3.12 ok regular" "$(printf '%s\n' "$OUT" | grep python) $(link python-3.12 resolv.conf)"
check "a flavor that is not there is absent, not an error" "EXAKIT_SLC_DNS r-4.4 absent" "$(printf '%s\n' "$OUT" | grep r-4.4)"
check "...exit 0" "0" "$RC"
OUT="$(PATH="$WORK/bin:$PATH" python3 "$HELPER" java-17)"
check "a second run changes nothing" "EXAKIT_SLC_DNS java-17 ok" "$OUT"
ctr; OUT="$(FAKE_CP_FAILS=1 PATH="$WORK/bin:$PATH" python3 "$HELPER" java-17)"; RC=$?
check "a copy that fails is reported, exit 1" "EXAKIT_SLC_DNS java-17 failed 1" "$OUT $RC"
OUT="$(FAKE_NO_CTR=1 PATH="$WORK/bin:$PATH" python3 "$HELPER" java-17)"
check "no database container: said, not guessed" "EXAKIT_SLC_DNS - nocontainer" "$OUT"

printf '\n== the sh script for the launcher VM (macOS) ==\n'
GEN="$(bash -c '. "$1/setup/lib/common.sh"; . "$1/setup/lib/detect.sh"; . "$1/setup/lib/runtime-personal.sh"; personal_slc_dns_script java-17 python-3.12 r-4.4' _ "$ROOT")"
ctr
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "the same outcomes from the VM script" \
    "EXAKIT_SLC_DNS java-17 repaired|EXAKIT_SLC_DNS python-3.12 ok|EXAKIT_SLC_DNS r-4.4 absent|" "$(printf '%s\n' "$OUT" | tr '\n' '|')"
check "...the same two links" "/conf/resolv.conf /conf/hosts" "$(link java-17 resolv.conf) $(link java-17 hosts)"
OUT="$(printf '%s\n' "$GEN" | PATH="$WORK/bin:$PATH" sh)"
check "...and idempotent" "EXAKIT_SLC_DNS java-17 ok" "$(printf '%s\n' "$OUT" | grep java-17)"

printf '\n== wiring ==\n'
check "every start repairs (bash)" "1" "$(sed -n '/^personal_start()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh" | grep -c '^ *personal_slc_dns_repair || true')"
check "every start repairs (PowerShell)" "1" "$(sed -n '/^function Start-Personal/,/^function Get-PersonalSlcInstalledFlavors/p' "$ROOT/setup/lib/runtime-personal.ps1" | grep -c 'try { \[void\](Repair-PersonalSlcDns) }')"
check "macOS feeds the VM shell inside the bounded command (stdin survives a background job)" "1" \
    "$(grep -c "exakit_run_bounded 90 sh -c 'exec \"\$0\" shell container < \"\$1\"'" "$ROOT/setup/lib/runtime-personal.sh")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
