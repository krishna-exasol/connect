#!/usr/bin/env bash
# The SQL preprocessor framework's life inside the kit, end to end against a
# simulated database (tests/lib/fake-exapump.py): install, session trial,
# activation, fresh-connection verification, and every way each of those can
# go wrong.
#
# The invariants worth a suite:
#   1. The slot is only ever changed for the kit's own dispatcher, and only
#      after a session using it ran ordinary SQL and a scoped module.
#   2. A failure after the database default changed puts the previous setting
#      back - the database is never left with a preprocessor that broke it.
#   3. release.sql is clean-install only, so it is never replayed over an
#      existing framework; only the kit's OWN interrupted install is dropped,
#      and never one that carries someone's rules.
#   4. Anything the kit does not manage - another script in the slot, a
#      framework someone installed by hand - is left exactly as it was.
#   5. A package that does not match the pin is never executed, and an
#      installed framework is verified without the network.
#
# Then the shell bridge: the installer step renders the coordinator's lines,
# fetches the package only when a fresh install asks for it, records the core
# task only after the checks pass, and books a failure in the closing summary.
#
#   bash tests/preprocessor-lifecycle.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$2" "$3"; fi
}
has() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '         missing: %s\n         in: %.300s\n' "$2" "$3" ;; esac
}
lacks() {
    case "$3" in *"$2"*) fail "$1"; printf '         unexpected: %s\n' "$2" ;; *) pass "$1" ;; esac
}

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for this suite"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY="$ROOT/setup/preprocessor/manage.py"
FAKE="$ROOT/tests/lib/fake-exapump.py"

# The stand-in exapump: a script, so manage.py runs it exactly as it runs the
# real binary.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/exapump" <<EOF
#!/bin/sh
exec python3 "$FAKE" "\$@"
EOF
chmod +x "$WORK/bin/exapump"

# A small release.sql with the real one's shape: an unguarded CREATE ROLE, the
# two schemas, the scripts the kit checks for, the Python module resolver a
# local deployment cannot create, the seed rule, the refresh.
PKG="$WORK/release.sql"
{
    printf 'CREATE ROLE PREPROC_ADMIN;\nCREATE SCHEMA IF NOT EXISTS PREPROC;\nCREATE SCHEMA IF NOT EXISTS PREPROC_RT;\n'
    for s in PREPROC_RT.MASTER PREPROC_RT.CONTROL_SUGAR_V1 PREPROC.REFRESH_CORE PREPROC.REFRESH \
             PREPROC.STATUS PREPROC.RULE_ENSURE PREPROC.RULE_DROP PREPROC.RULE_LIST; do
        printf -- '--/\nCREATE OR REPLACE LUA SCRIPT %s() AS\nlocal a = "x;y"\n/\n' "$s"
    done
    printf -- '\n--/\n-- the registry resolver: fetches modules from a URL\nCREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1(src VARCHAR(2000)) EMITS (s VARCHAR(10)) AS\ndef run(ctx):\n    ctx.emit("OK")\n/\n'
    printf -- '--/\nCREATE OR REPLACE LUA SCRIPT PREPROC.MODULE_INSTALL() AS\nlocal r = "PREPROC.MODULE_RESOLVER_V1"\n/\n'
    printf 'INSERT INTO PREPROC.CONFIG (rule_id) SELECT 1;\nEXECUTE SCRIPT PREPROC.REFRESH;\n'
} > "$PKG"
SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PKG")"
CORE="$(python3 "$PY" derive --package "$PKG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')"

printf '\n== the core-only package ==\n'
_derived="$(python3 "$PY" derive --package "$PKG" --out "$WORK/core.sql")"
has "derive leaves out the Python resolver, and only it" '"left_out": ["PREPROC.MODULE_RESOLVER_V1"]' "$_derived"
lacks "...no PYTHON3 statement is left" "CREATE OR REPLACE PYTHON3" "$(cat "$WORK/core.sql")"
has "...the Lua script that names it is kept" "CREATE OR REPLACE LUA SCRIPT PREPROC.MODULE_INSTALL" "$(cat "$WORK/core.sql")"
# The only change is one contiguous deletion: the resolver's "--/" opener, its
# comment, its body and its closing "/". Nothing added, nothing else removed.
_diff="$(diff "$PKG" "$WORK/core.sql")"
check "...and the only change is that block, deleted whole" "1 0 6" \
    "$(printf '%s\n' "$_diff" | grep -c '^[0-9]') $(printf '%s\n' "$_diff" | grep -c '^>') $(printf '%s\n' "$_diff" | grep -c '^<')"
has "...and it is the Python script" "< CREATE OR REPLACE PYTHON3 SET SCRIPT PREPROC.MODULE_RESOLVER_V1" "$_diff"

# scenario <name> [state-json] — a fresh database state and manifest.
scenario() {
    D="$WORK/$1"
    mkdir -p "$D"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$D/state.json"; else printf '{}\n' > "$D/state.json"; fi
    printf '{"components": {}, "steps_completed": []}\n' > "$D/manifest.json"
}
# ensure [extra args...] — run the coordinator against the current scenario.
ensure() {
    FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" ensure --exapump "$WORK/bin/exapump" \
        --profile starter-kit --manifest "$D/manifest.json" --admin-user sys \
        --pin-version 0.9.1 --pin-ref v0.9.1 --pin-sha256 "$SHA" --pin-core-sha256 "$CORE" \
        --log "$D/log" "$@" > "$D/out" 2>&1
    RC=$?
    OUT="$(cat "$D/out")"
}
st()  { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v.get(k) if isinstance(v,dict) else None
print(json.dumps(v) if not isinstance(v,str) else v)' "$D/state.json" "$1"; }
rec() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("components",{}).get("preprocessor",{}).get(sys.argv[2])
print(json.dumps(v) if not isinstance(v,str) else v)' "$D/manifest.json" "$1"; }
calls() { python3 -c 'import json,sys; print("\n".join(s for c in json.load(open(sys.argv[1]))["calls"] for s in c))' "$D/state.json"; }
reset_calls() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"; }
fault() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("faults",[]).append(sys.argv[2]); json.dump(d,open(p,"w"))' "$D/state.json" "$1"; }
set_rec() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("components",{})["preprocessor"]=json.loads(sys.argv[2]); json.dump(d,open(p,"w"))' "$D/manifest.json" "$1"; }

printf '\n== a fresh database: the package is asked for, then installed, tried, activated ==\n'
scenario fresh
ensure
check "no package on hand: exit 10, a fresh install needs it" "10" "$RC"
check "...and nothing was created" "[]" "$(st schemas)"
lacks "...and the slot was not touched" "ALTER SYSTEM" "$(calls)"

ensure --package "$WORK/nowhere.sql"
check "a package path that does not exist is the same answer" "10" "$RC"

printf 'tampered\n' >> "$WORK/tampered.sql"; cat "$PKG" >> "$WORK/tampered.sql"
ensure --package "$WORK/tampered.sql"
check "a package that does not match the pin: exit 11" "11" "$RC"
has "...naming both digests" "does not match the pinned SHA-256" "$OUT"
lacks "...and it never reached the database" "CREATE ROLE" "$(calls)"

reset_calls
ensure --package "$PKG"
check "with the pinned package: ready, on a database that has no Python" "0" "$RC"
lacks "...the Python resolver never reached it" "PYTHON3" "$(calls)"
check "...recorded as the core-only package" "core-only $CORE" "$(rec package) $(rec core_sha256)"
check "...naming what it left out" '["PREPROC.MODULE_RESOLVER_V1"]' "$(rec left_out)"
check "the dispatcher holds the slot" "PREPROC_RT.MASTER" "$(st system_slot)"
check "both schemas exist" '["PREPROC", "PREPROC_RT"]' "$(st schemas)"
_install_first="$(python3 -c 'import json,sys; print(next(c[0] for c in json.load(open(sys.argv[1]))["calls"] if any(s.startswith("CREATE ROLE") for s in c)))' "$D/state.json")"
check "the install ran in a session that bypasses any preprocessor" "ALTER SESSION SET sql_preprocessor_script = ''" "$_install_first"
_seq="$(calls | grep -n -E "^ALTER SESSION SET sql_preprocessor_script = PREPROC_RT.MASTER|^ALTER SYSTEM SET sql_preprocessor_script = PREPROC_RT.MASTER" | cut -d: -f2- | awk '{print $1, $2}' | tr '\n' '|')"
check "the session trial comes before the database default" "ALTER SESSION|ALTER SYSTEM|" "$_seq"
check "the probe module is gone afterwards" "false" "$(python3 -c 'import json,sys; print(str("PREPROC_RT.EXAKIT_PROBE_V1" in json.load(open(sys.argv[1]))["scripts"]).lower())' "$D/state.json")"
check "...and so is its rule" '[{"id": 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"}]' "$(st rules)"
check "recorded: active" "active" "$(rec state)"
check "recorded: validated" "true" "$(rec validated)"
check "recorded: the pinned version" "0.9.1" "$(rec version)"
check "recorded: the verified digest" "$SHA" "$(rec sha256)"
check "recorded: the setting to restore" "" "$(rec previous_setting)"
has "the screen line names the version" "OK SQL preprocessor framework 0.9.1 installed, tested and activated" "$OUT"
has "...and ordinary SQL" "OK Ordinary SQL verified with the framework active" "$OUT"
if grep -q "$SHA" "$D/log" 2>/dev/null || ! grep -q 'PREPROC \[' "$D/log" 2>/dev/null; then
    fail "exapump's progress lines reach the log (and nothing else does)"
else
    pass "exapump's progress lines reach the log (and nothing else does)"
fi

scenario core-pin
ensure --package "$PKG" --pin-core-sha256 "$(printf '0%.0s' $(seq 1 64))"
check "a derived package that does not match its own pin: exit 11" "11" "$RC"
has "...said as such" "core-only package derived from the verified download does not match" "$OUT"
check "...and nothing ran" "[]" "$(st schemas)"

D="$WORK/fresh"
printf '\n== every later pass verifies, and never replays release.sql ==\n'
reset_calls
ensure
check "an active framework verifies without the package" "0" "$RC"
lacks "release.sql was not run again" "CREATE ROLE" "$(calls)"
lacks "the default was not touched" "ALTER SYSTEM" "$(calls)"
has "the screen says so" "OK SQL preprocessor framework 0.9.1 verified and active" "$OUT"

printf '\n== what the kit does not manage is left alone ==\n'
scenario conflict '{"system_slot": "MYSCHEMA.MY_PREPROCESSOR"}'
ensure --package "$PKG"
check "another script in the slot: conflict, exit 3" "3" "$RC"
check "...the slot still holds it" "MYSCHEMA.MY_PREPROCESSOR" "$(st system_slot)"
lacks "...nothing was installed" "CREATE ROLE" "$(calls)"
has "...and the reason names it" "MYSCHEMA.MY_PREPROCESSOR" "$OUT"
has "...with the step before the retry" "clear the slot (ALTER SYSTEM SET sql_preprocessor_script = NULL), then run the command below" "$OUT"

scenario foreign '{"schemas": ["PREPROC", "PREPROC_RT"], "role": true, "scripts": ["PREPROC_RT.MASTER"]}'
ensure --package "$PKG"
check "a framework someone else installed and left inactive: exit 3" "3" "$RC"
lacks "...not dropped" "DROP SCHEMA" "$(calls)"
lacks "...not activated" "ALTER SYSTEM" "$(calls)"

ALL_SCRIPTS='"PREPROC_RT.MASTER", "PREPROC_RT.CONTROL_SUGAR_V1", "PREPROC.REFRESH_CORE", "PREPROC.REFRESH", "PREPROC.STATUS", "PREPROC.RULE_ENSURE", "PREPROC.RULE_DROP", "PREPROC.RULE_LIST"'
scenario adopted "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS]}"
ensure
check "a framework someone installed AND activated is verified" "0" "$RC"
check "...and recorded as pre-existing" "pre-existing" "$(rec origin)"
lacks "...without reinstalling it" "CREATE ROLE" "$(calls)"

printf '\n== the kit recovers its own interrupted install, and only that ==\n'
scenario interrupted '{"schemas": ["PREPROC"], "role": true, "scripts": []}'
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure
check "without the package: exit 10, nothing dropped yet" "10" "$RC"
lacks "...no DROP issued" "DROP SCHEMA" "$(calls)"
ensure --package "$PKG"
check "with the package: cleaned up and installed" "0" "$RC"
has "...it dropped its own schemas first" "DROP SCHEMA IF EXISTS PREPROC CASCADE" "$(calls)"
has "...and its role" "DROP ROLE IF EXISTS PREPROC_ADMIN CASCADE" "$(calls)"
check "...and the framework is active" "PREPROC_RT.MASTER" "$(st system_slot)"

scenario interrupted-with-rules '{"schemas": ["PREPROC"], "role": true, "scripts": [], "rules": [{"id": 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"}, {"id": 2, "script": "PREPROC_RT.SOMEONES_MODULE_V1"}]}'
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure --package "$PKG"
check "an interrupted install that carries someone's rules is refused" "1" "$RC"
has "...naming the rule's script" "PREPROC_RT.SOMEONES_MODULE_V1" "$OUT"
has "...and what a person can do about it" "Keep them by activating the framework" "$OUT"
lacks "...and nothing is dropped" "DROP SCHEMA" "$(calls)"

scenario activated-by-hand "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS]}"
set_rec '{"state": "installing", "version": "0.9.1"}'
ensure
check "an interrupted install someone activated by hand is verified and recorded active" "0 active" "$RC $(rec state)"
lacks "...without reinstalling" "CREATE ROLE" "$(calls)"

scenario stale-resolution "{\"system_slot\": \"PREPROC_RT.MASTER\", \"schemas\": [\"PREPROC\", \"PREPROC_RT\"], \"role\": true, \"scripts\": [$ALL_SCRIPTS], \"stale\": true}"
set_rec '{"state": "active", "version": "0.9.1"}'
ensure
check "a user created since the last refresh: the run refreshes the rule resolution" "0 1" \
    "$RC $(printf '%s\n' "$(calls)" | grep -c 'EXECUTE SCRIPT PREPROC.REFRESH')"
has "...and says so" "Rule resolution refreshed" "$OUT"
reset_calls; ensure
lacks "...once: a current resolution is left alone" "PREPROC.REFRESH" "$(calls)"

scenario install-dies
fault "fail_on:PREPROC.REFRESH_CORE"
ensure --package "$PKG"
check "an install that dies part way: exit 1" "1" "$RC"
check "...the slot is untouched" "" "$(st system_slot)"
check "...and the record says installing, for the next run to recover" "installing" "$(rec state)"
has "...the database's own message reaches the reason" "injected failure on PREPROC.REFRESH_CORE" "$OUT"

printf '\n== activation is tried in one session before the default changes ==\n'
scenario no-dispatch
fault "no_dispatch"
ensure --package "$PKG"
check "a dispatcher that does not run the scoped module: exit 1" "1" "$RC"
check "...the database default was never changed" "" "$(st system_slot)"
lacks "...no ALTER SYSTEM at all" "ALTER SYSTEM" "$(calls)"
check "...recorded installed, not active" "installed" "$(rec state)"
check "...and the probe was cleaned up" "false" "$(python3 -c 'import json,sys; print(str("PREPROC_RT.EXAKIT_PROBE_V1" in json.load(open(sys.argv[1]))["scripts"]).lower())' "$D/state.json")"
# The next pass, with the fault gone, finishes the activation without
# reinstalling.
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["faults"]=[]; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
ensure
check "the next pass activates the installed framework" "0" "$RC"
lacks "...without reinstalling" "CREATE ROLE" "$(calls)"

scenario alter-system-refused
fault "fail_alter_system"
ensure --package "$PKG"
check "a refused ALTER SYSTEM: exit 1" "1" "$RC"
check "...slot unchanged" "" "$(st system_slot)"

printf '\n== a failure after the default changed restores the previous setting ==\n'
scenario breaks-ordinary
fault "fail_on:SELECT COUNT(*) AS N FROM PREPROC_RT.MY_PIPELINE"
ensure --package "$PKG"
check "fresh connections failing after activation: exit 1" "1" "$RC"
check "...the previous (empty) setting is back" "" "$(st system_slot)"
has "...restored with ALTER SYSTEM ... NULL" "ALTER SYSTEM SET sql_preprocessor_script = NULL" "$(calls)"
check "...recorded installed and not validated" "installed false" "$(rec state) $(rec validated)"
has "...and the reason says the restore worked" "previous setting was restored and ordinary SQL works" "$OUT"

scenario active-breaks
ensure --package "$PKG"
reset_calls
fault "fail_on:SELECT COUNT(*) AS N FROM PREPROC_RT.MY_PIPELINE"
ensure
check "an active framework that stops verifying is deactivated" "1" "$RC"
check "...slot restored" "" "$(st system_slot)"

printf '\n== an active framework with objects missing is never overwritten ==\n'
scenario objects-missing
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["scripts"]=[s for s in d["scripts"] if s!="PREPROC.STATUS"]; d["calls"]=[]; json.dump(d,open(p,"w"))' "$D/state.json"
ensure --package "$PKG"
check "a missing script: exit 1" "1" "$RC"
has "...named" "PREPROC.STATUS" "$OUT"
lacks "...and release.sql is not replayed" "CREATE ROLE" "$(calls)"

printf '\n== a cleared slot is reactivated; a newer pin is reported, not forced ==\n'
scenario cleared
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["system_slot"]=""; json.dump(d,open(p,"w"))' "$D/state.json"
ensure
check "an installed framework whose slot was cleared is activated again" "0 PREPROC_RT.MASTER" "$RC $(st system_slot)"
has "...and the screen says why" "no longer active - activating it again" "$OUT"

scenario upgrade
ensure --package "$PKG"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["components"]["preprocessor"]["version"]="0.9.0"; json.dump(d,open(p,"w"))' "$D/manifest.json"
reset_calls
ensure --package "$PKG"
check "an older installed framework still verifies" "0" "$RC"
has "...with the pending upgrade named" "WARN Framework 0.9.0 is installed and this kit pins 0.9.1" "$OUT"
lacks "...and nothing is reinstalled" "CREATE ROLE" "$(calls)"

scenario down
fault "down"
ensure --package "$PKG"
check "a database that does not answer: exit 1" "1" "$RC"
has "...said plainly" "the database could not be inspected" "$OUT"

printf '\n== inspect is read-only ==\n'
scenario inspect-only '{"system_slot": "X.Y"}'
_insp="$(FAKE_EXAPUMP_STATE="$D/state.json" python3 "$PY" inspect --exapump "$WORK/bin/exapump" --profile p --manifest "$D/manifest.json")"
has "inspect reports the slot" '"slot": "X.Y"' "$_insp"
lacks "...and writes nothing" "ALTER" "$(calls)"

printf '\n== the installer step: the shell bridge ==\n'
# A sandboxed kit: its own home, manifest and versions document pinning the
# test package, the stand-in exapump, and a fetch that copies the package
# instead of downloading it.
B="$WORK/bridge"
mkdir -p "$B/home" "$B/kit"
python3 - "$ROOT/versions.json" "$B/kit/versions.json" "$SHA" "$CORE" <<'PYV'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["preprocessor"]["sha256"]["release-sql"] = sys.argv[3]
doc["components"]["preprocessor"]["sha256"]["core-only"] = sys.argv[4]
json.dump(doc, open(sys.argv[2], "w"), indent=2)
PYV
printf '{}\n' > "$B/state.json"
bridge() {
    ( EXAKIT_HOME="$B/home"
      EXAKIT_MANIFEST="$B/home/manifest.json"
      EXAKIT_BIN_DIR="$B/home/bin"
      EXAKIT_LOG_FILE="$B/home/setup.log"
      EXAKIT_EXAPUMP_BIN="$WORK/bin/exapump"
      EXAKIT_EXAPUMP_CONFIG_DIR="$B/home/.exapump"
      FAKE_EXAPUMP_STATE="$B/state.json"
      export FAKE_EXAPUMP_STATE
      . "$ROOT/setup/lib/common.sh"
      . "$ROOT/setup/lib/detect.sh"
      . "$ROOT/setup/lib/runtime-personal.sh"
      . "$ROOT/setup/lib/exapump.sh"
      . "$ROOT/setup/lib/core-setup.sh"
      _EXAKIT_VERSIONS_DOC="$B/kit/versions.json"
      _EXAKIT_VERSIONS_SOURCE="baked"
      [ -f "$EXAKIT_MANIFEST" ] || manifest_init >/dev/null 2>&1
      manifest_set kit.version 0.3.0 >/dev/null 2>&1
      fetch() { printf 'FETCH %s\n' "$1" >> "$B/fetches"; cp "$PKG" "$2"; }
      "$@" )
}
# The kit's copy of setup/core and setup/preprocessor is the checkout itself.
B_OUT="$(bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" 2>&1)"
has "the step announces itself" "Step 4/7  Configure database features" "$B_OUT"
has "the coordinator's OK lines are rendered" "SQL preprocessor framework 0.9.1 installed, tested and activated" "$B_OUT"
check "the package was fetched once, from the pinned release asset" \
    "FETCH https://github.com/exasol-labs/preprocessor-framework/releases/download/v0.9.1/release.sql" "$(cat "$B/fetches")"
check "...into the content-addressed cache" "yes" "$([ -f "$B/home/cache/preprocessor/$SHA/release.sql" ] && echo yes || echo no)"
check "the core task is recorded only now" '["preprocessor"]' "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["core_tasks"]["completed"]))' "$B/home/manifest.json")"
lacks "...and the step itself never joins steps_completed" "db_features" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("steps_completed"))' "$B/home/manifest.json")"

rm -f "$B/fetches"
B_OUT="$(bridge exakit_core_database_step "Step 4/7  Configure database features" "$ROOT" 2>&1)"
has "a second pass verifies" "verified and active" "$B_OUT"
check "...without fetching anything" "no" "$([ -f "$B/fetches" ] && echo yes || echo no)"

# A conflict is booked in the closing summary, with the reason and the retry.
printf '{"system_slot": "OTHER.SCRIPT"}\n' > "$B/state.json"
rm -rf "$B/home"; mkdir -p "$B/home"
B_OUT="$(bridge eval 'exakit_core_database_step "Step 4/7  Configure database features" "'"$ROOT"'"; exakit_print_soft_failures; printf "COMPLETED=%s\n" "$(manifest_get core_tasks.completed 2>/dev/null)"' 2>&1)"
has "a conflict is in the closing summary" "the SQL preprocessor framework is not installed" "$B_OUT"
has "...with the slot's holder named" "OTHER.SCRIPT" "$B_OUT"
has "...and the retry command" "exakit update" "$B_OUT"
has "...and the task is not recorded" "COMPLETED=" "$B_OUT"
lacks "...not even partly" '"preprocessor"' "$(grep COMPLETED= <<<"$B_OUT")"
check "...and the slot still holds the other script" "OTHER.SCRIPT" "$(D="$B"; st system_slot)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
