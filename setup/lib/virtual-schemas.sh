#!/usr/bin/env bash
# virtual-schemas.sh — `exakit connect` and `exakit source <action>`: query an
# external database from the local one through an Exasol virtual schema.
#
# Sourced by exakit after common.sh, detect.sh, runtime-personal.sh and
# pyexasol.sh. ⇄ twin: virtual-schemas.ps1. The work is the shared Python
# engine in setup/virtual-schemas/engine, run with the kit's pyexasol
# interpreter; this file supplies the deployment, asks the questions, keeps
# secrets off the command line, and repairs the two things the engine
# reports but cannot fix from inside the database:
#
#   exit 20  Java in the database has no DNS resolver -> personal_slc_dns_repair, retry once
#   exit 21  the Java language container is missing   -> `exasol slc install java` (asked), retry once

# exakit_vs_defs — the folder that holds catalog.json, profiles/, connectors/.
exakit_vs_defs() {
    _evd_root="$(exakit_repo_root 2>/dev/null || true)"
    if [ -n "$_evd_root" ] && [ -f "$_evd_root/setup/virtual-schemas/catalog.json" ]; then
        printf '%s\n' "$_evd_root/setup/virtual-schemas"
        return 0
    fi
    _evd_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    [ -f "$_evd_here/virtual-schemas/catalog.json" ] || return 1
    printf '%s\n' "$_evd_here/virtual-schemas"
}

# exakit_vs_available — can a source be connected from here? The definitions
# are in this kit copy and the kit's pyexasol, which runs the engine, exists.
exakit_vs_available() {
    exakit_vs_defs >/dev/null 2>&1 || return 1
    command -v pyexasol_venv_python >/dev/null 2>&1 || return 1
    _eva_py="$(pyexasol_venv_python 2>/dev/null || true)"
    [ -n "$_eva_py" ] && [ -x "$_eva_py" ]
}

# exakit_vs_connect_wizard — the data-load row: `exakit connect` asking for
# everything. Run in a subshell by the caller, since cmd_connect exits.
exakit_vs_connect_wizard() {
    cmd_connect
}

# exakit_vs_engine <args...> — the engine with this installation's context.
# Its stdin is passed through: that is where a secret travels.
exakit_vs_engine() {
    _eve_defs="$(exakit_vs_defs)" || { error "This kit copy has no setup/virtual-schemas. Update it: exakit update"; return 2; }
    _eve_py=""
    command -v pyexasol_venv_python >/dev/null 2>&1 && _eve_py="$(pyexasol_venv_python 2>/dev/null || true)"
    if [ -z "$_eve_py" ] || [ ! -x "$_eve_py" ]; then
        error "Virtual schemas run with the kit's pyexasol, which is not installed. Repair it: exakit update pyexasol"
        return 2
    fi
    "$_eve_py" "$_eve_defs/engine/cli.py" --defs "$_eve_defs" --kit-home "$EXAKIT_HOME" \
        --deployment-dir "$(manifest_get runtime.deployment_dir 2>/dev/null || true)" \
        --dsn "$(manifest_get runtime.dsn 2>/dev/null || true)" \
        --user "$(manifest_get runtime.user 2>/dev/null || printf sys)" \
        --password-file "$(manifest_get runtime.password_file 2>/dev/null || true)" "$@"
}

# _exakit_vs_render — the engine's event lines in the kit's own marks; the
# RESULT line is kept in EXAKIT_VS_RESULT for the caller.
_exakit_vs_render() {
    EXAKIT_VS_RESULT=""
    while IFS= read -r _evr_line || [ -n "$_evr_line" ]; do
        case "$_evr_line" in
            "OK "*)     ok "${_evr_line#OK }" ;;
            "INFO "*)   info "${_evr_line#INFO }" ;;
            "WARN "*)   warn "${_evr_line#WARN }" ;;
            "FAIL "*)   error "${_evr_line#FAIL }" ;;
            "RESULT "*) EXAKIT_VS_RESULT="${_evr_line#RESULT }" ;;
            *) [ -n "$_evr_line" ] && printf '%s\n' "$_evr_line" ;;
        esac
    done < "$1"
}

# _exakit_vs_read_secret <label> <password-file> — a secret, from the file the
# caller named, else a hidden prompt, else stdin. Never from an argument.
_exakit_vs_read_secret() {
    if [ -n "$2" ]; then
        [ -r "$2" ] || { error "Cannot read $2"; return 1; }
        cat "$2"
        return 0
    fi
    _evs_tty="$(_exakit_prompt_tty)"
    if [ -n "$_evs_tty" ] && [ -r /dev/tty ]; then
        exakit_read_hidden "$1" || { error "The terminal cannot hide input; give the credential with --password-file."; return 1; }
        return 0
    fi
    cat
}

# _exakit_vs_confirm <question> — yes on a terminal answer y, or --yes.
_exakit_vs_confirm() {
    [ "${EXAKIT_VS_ASSUME_YES:-0}" = 1 ] && return 0
    [ -n "$(_exakit_prompt_tty)" ] || return 1
    case "$(prompt_text "$1 [y/N]" "N")" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# _exakit_vs_install_java — the Java language container, with consent: a
# download of about 250 MiB and one database restart, done through the kit's
# own stop/start so add-on services come back and DNS is repaired.
_exakit_vs_install_java() {
    info "Virtual schemas run Java inside the database, and its Java language container is not installed."
    info "Installing it downloads about 250 MiB and restarts the database once (add-on services restart with it)."
    if ! _exakit_vs_confirm "Install the Java language container now?"; then
        info "Install it later with: exasol slc install java --no-restart, then exakit stop and exakit start"
        return 1
    fi
    run_logged "$(personal_cli)" slc install java --no-restart $(personal_auto_approve_flag slc) \
        || { error "The Java language container did not install. Details: exakit logs"; return 1; }
    EXAKIT_STOP_ADDONS=1 "$EXAKIT_BIN_DIR/exakit" stop >/dev/null 2>&1 || true
    "$EXAKIT_BIN_DIR/exakit" start || { error "The database did not come back after installing Java. Run: exakit start"; return 1; }
    # An installed kit's start repairs DNS; this kit copy may be newer than it.
    personal_slc_dns_repair || true
    ok "Java language container installed"
}

# _exakit_vs_run <secret-or-empty> <engine args...> — run the engine once,
# repairing DNS (exit 20) or installing Java (exit 21) and retrying once.
_exakit_vs_run() {
    _evx_secret="$1"; shift
    _evx_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || return 1
    _evx_try=0
    while :; do
        _evx_try=$((_evx_try + 1))
        if [ -n "$_evx_secret" ]; then
            printf '%s' "$_evx_secret" | exakit_vs_engine "$@" > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        else
            exakit_vs_engine "$@" < /dev/null > "$_evx_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        fi
        _evx_rc=$?
        _exakit_vs_render "$_evx_out"
        [ "$_evx_try" -eq 1 ] || break
        case "$_evx_rc" in
            20) info "Giving the database's language containers the deployment's DNS, then trying again"
                personal_slc_dns_repair || { error "DNS could not be repaired. Restart the database (exakit stop, exakit start) and try again."; break; } ;;
            21) _exakit_vs_install_java || break ;;
            *)  break ;;
        esac
    done
    rm -f "$_evx_out"
    return "$_evx_rc"
}

# _exakit_vs_ask_inputs <connector> — prompt for each input the caller did not
# set, defaults offered; appends --set KEY=VALUE pairs to EXAKIT_VS_SETS.
_exakit_vs_ask_inputs() {
    _evi_lines="$(run_python_any - "$(exakit_vs_defs)/connectors/$1/connector.json" <<'PY'
import json, sys
for spec in json.load(open(sys.argv[1]))["inputs"]:
    if spec["kind"] in ("secret", "secret-file"):
        continue
    choices = "/".join(spec.get("choices", []))
    print("%s|%s|%s|%s" % (spec["name"], spec.get("label", spec["name"]), spec.get("default", ""), choices))
PY
)"
    while IFS='|' read -r _evi_name _evi_label _evi_default _evi_choices; do
        [ -n "$_evi_name" ] || continue
        case " $EXAKIT_VS_GIVEN " in *" $_evi_name "*) continue ;; esac
        [ -n "$_evi_choices" ] && _evi_label="$_evi_label ($_evi_choices)"
        _evi_value="$(prompt_text "$_evi_label" "$_evi_default")"
        [ -n "$_evi_value" ] && EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$_evi_name=$_evi_value"
    done <<EOF
$_evi_lines
EOF
}

# cmd_connect [source] [--name N] [--set KEY=VALUE]... [--password-file F]
#             [--dry-run] [--yes] [--json]
cmd_connect() {
    _cc_source=""; _cc_name=""; _cc_pwfile=""; _cc_dry=0; _cc_json=0
    EXAKIT_VS_SETS=""; EXAKIT_VS_GIVEN=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name) _cc_name="${2:-}"; shift ;;
            --name=*) _cc_name="${1#--name=}" ;;
            --set) case "${2:-}" in *=*) ;; *) reject "--set takes KEY=VALUE (exakit help connect)" ;; esac
                   EXAKIT_VS_SETS="$EXAKIT_VS_SETS
--set
$2"; EXAKIT_VS_GIVEN="$EXAKIT_VS_GIVEN ${2%%=*}"; shift ;;
            --password-file) _cc_pwfile="${2:-}"; shift ;;
            --dry-run|-n) _cc_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --json|-j) _cc_json=1 ;;
            --password=*|--password|--secret*|--token*)
                reject "A credential is never taken as an argument (other users can read the process list). Use the hidden prompt, --password-file, or standard input." ;;
            -*) reject "Unknown option '$1' for connect (exakit help connect)." ;;
            *) [ -z "$_cc_source" ] || reject "connect takes one source; got '$_cc_source' and '$1'."; _cc_source="$1" ;;
        esac
        shift
    done
    _require_install "$_cc_json"
    exakit_init_logging
    _cc_tty="$(_exakit_prompt_tty)"
    if [ -z "$_cc_source" ]; then
        [ -n "$_cc_tty" ] || reject "Name the source to connect, e.g. exakit connect postgresql (see: exakit source catalog)."
        _cc_source="$(prompt_text "Which source? (name or alias, e.g. postgresql, mysql, mssql, oracle, snowflake)" "")"
    fi
    _cc_resolved="$(exakit_vs_engine resolve "$_cc_source" 2>/dev/null | sed -n 's/^RESULT {"connector": "\(.*\)"}$/\1/p')"
    if [ -z "$_cc_resolved" ]; then
        exakit_vs_engine resolve "$_cc_source" > "${TMPDIR:-/tmp}/exakit-vs-resolve.$$" 2>&1
        _cc_rc=$?
        _exakit_vs_render "${TMPDIR:-/tmp}/exakit-vs-resolve.$$"; rm -f "${TMPDIR:-/tmp}/exakit-vs-resolve.$$"
        [ "$_cc_rc" -ne 0 ] || _cc_rc=2
        exit "$_cc_rc"
    fi
    if [ -z "$_cc_name" ]; then
        [ -n "$_cc_tty" ] || reject "Give the connection a name with --name (lower case, e.g. sales)."
        _cc_name="$(prompt_text "Name for this connection (lower case, e.g. sales)" "")"
    fi
    [ -n "$_cc_tty" ] && _exakit_vs_ask_inputs "$_cc_resolved"
    # Build the engine's argument list from the newline-separated pairs; bash
    # 3.2 has no arrays worth trusting with this, so the positional
    # parameters carry it.
    set -- "$_cc_resolved" --name "$_cc_name"
    while IFS= read -r _cc_word; do
        [ -n "$_cc_word" ] && set -- "$@" "$_cc_word"
    done <<EOF
$EXAKIT_VS_SETS
EOF
    _cc_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
    exakit_vs_engine plan "$@" < /dev/null > "$_cc_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _cc_rc=$?
    _exakit_vs_render "$_cc_out"; rm -f "$_cc_out"
    [ "$_cc_rc" -eq 0 ] || exit "$_cc_rc"
    _exakit_vs_show_plan "$EXAKIT_VS_RESULT"
    if [ "$_cc_dry" = 1 ]; then
        [ "$_cc_json" = 1 ] && printf '%s\n' "$EXAKIT_VS_RESULT"
        exit 0
    fi
    if [ -n "$_cc_tty" ] && ! _exakit_vs_confirm "Connect now?"; then
        # 5, as every command a person did not confirm: 0 would read as "done".
        info "Nothing was changed."
        exit 5
    fi
    _cc_label="$(run_python_any -c 'import json,sys; c=json.load(open(sys.argv[1])); print(next((s.get("label","password") for s in c["inputs"] if s["kind"] in ("secret","secret-file")), ""))' \
        "$(exakit_vs_defs)/connectors/$_cc_resolved/connector.json" 2>/dev/null)"
    _cc_secret=""
    if [ -n "$_cc_label" ]; then
        _cc_secret="$(_exakit_vs_read_secret "$_cc_label" "$_cc_pwfile")" || exit 2
        [ -n "$_cc_secret" ] || reject "No $(printf '%s' "$_cc_label" | tr 'A-Z' 'a-z') was given (pipe it on standard input or use --password-file)."
    fi
    if [ -n "$_cc_secret" ]; then
        _exakit_vs_run "$_cc_secret" connect "$@" --secret-stdin
    else
        _exakit_vs_run "" connect "$@"
    fi
    _cc_rc=$?
    unset _cc_secret
    if [ "$_cc_rc" -eq 0 ]; then
        ok "Query it like any schema: SELECT * FROM VS_$(printf '%s' "$_cc_name" | tr 'a-z' 'A-Z').<table> LIMIT 10"
        info "Manage it with: exakit source show $_cc_name | check | reauth | refresh | disconnect | remove"
    fi
    exit "$_cc_rc"
}

# _exakit_vs_show_plan <plan-json> — what will happen, before it does.
_exakit_vs_show_plan() {
    [ -n "$1" ] || return 0
    printf '%s' "$1" | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
print("  Plan for %s (%s, %s, %s)" % (p["name"], p["connector"], p["tier"], p["status"]))
for d in p["downloads"]:
    print("    %s %s %s (%.1f MB%s)" % ("reuse" if d["cached"] else "download", d["role"], d["version"], d["bytes"] / 1e6, ", " + d["license"]))
for s in p["steps"]:
    print("    - " + s)
print("    Exposure: " + p["exposure"])
for w in p["warnings"]:
    print("    Warning: " + w)
if p.get("gate"):
    print("    Not available yet: " + p["gate"])' 2>/dev/null
}

# cmd_source <action> [name] [options] — the lifecycle of a connected source.
cmd_source() {
    _cs_action="${1:-list}"; [ "$#" -gt 0 ] && shift
    _cs_json=0; _cs_dry=0; _cs_name=""; _cs_all=0; _cs_status=""; _cs_pwfile=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json|-j) _cs_json=1 ;;
            --dry-run|-n) _cs_dry=1 ;;
            --yes|-y) EXAKIT_VS_ASSUME_YES=1 ;;
            --all|-a) _cs_all=1 ;;
            --status) _cs_status="${2:-}"; shift ;;
            --password-file) _cs_pwfile="${2:-}"; shift ;;
            -*) reject "Unknown option '$1' for source $_cs_action (exakit help source)." ;;
            *) [ -z "$_cs_name" ] || reject "source $_cs_action takes one name."; _cs_name="$1" ;;
        esac
        shift
    done
    _require_install "$_cs_json"
    exakit_init_logging
    case "$_cs_action" in
        list|issues|catalog|show|check|reauth|refresh|disconnect|remove) ;;
        *) reject "Unknown source action '$_cs_action' (list, issues, show, check, reauth, refresh, disconnect, remove, catalog)." ;;
    esac
    case "$_cs_action" in
        show|reauth|refresh|disconnect|remove)
            [ -n "$_cs_name" ] || reject "exakit source $_cs_action needs a source name (see: exakit source list)." ;;
        check) [ -n "$_cs_name" ] || [ "$_cs_all" = 1 ] || reject "exakit source check needs a name or --all." ;;
    esac
    set --
    [ "$_cs_json" = 1 ] && set -- --json
    case "$_cs_action" in
        list)    set -- "$@" list ;;
        catalog) set -- "$@" catalog ;;
        issues)  set -- "$@" issues; [ -n "$_cs_status" ] && set -- "$@" --status "$_cs_status" ;;
        show|refresh) set -- "$@" "$_cs_action" "$_cs_name" ;;
        check)   if [ "$_cs_all" = 1 ]; then set -- "$@" check --all; else set -- "$@" check "$_cs_name"; fi ;;
        disconnect|remove)
            set -- "$@" "$_cs_action" "$_cs_name"
            if [ "$_cs_dry" = 1 ]; then
                set -- "$@" --dry-run
            elif [ "$_cs_json" != 1 ]; then
                exakit_vs_engine "$_cs_action" "$_cs_name" --dry-run < /dev/null 2>/dev/null \
                    | sed -n 's/^RESULT //p' | run_python_any -c 'import json, sys
p = json.load(sys.stdin)
print("  " + "\n  ".join(["drops: " + ", ".join(p["drop"])] + (["keeps: " + ", ".join(p["keep"])] if p.get("keep") else [])
      + (["deletes %d unused file(s); keeps %d still shared" % (len(p.get("delete_files", [])), len(p.get("keep_files", [])))] if "delete_files" in p else [])
      + ["note: " + p["note"]]))' 2>/dev/null
                case "$_cs_action" in disconnect) _cs_verb="Disconnect" ;; *) _cs_verb="Remove" ;; esac
                _exakit_vs_confirm "$_cs_verb $_cs_name?" \
                    || { info "Nothing was changed. Confirm it with --yes."; exit 5; }
            fi ;;
        reauth)
            # The name before the credential: nobody types a password for a
            # source that does not exist.
            _cs_out="$(mktemp "${TMPDIR:-/tmp}/exakit-vs.XXXXXX")" || die "Could not create a temporary file."
            exakit_vs_engine "$@" show "$_cs_name" < /dev/null > "$_cs_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
            _cs_rc=$?
            if [ "$_cs_rc" -ne 0 ]; then
                if [ "$_cs_json" = 1 ]; then cat "$_cs_out"; else _exakit_vs_render "$_cs_out"; fi
                rm -f "$_cs_out"; exit "$_cs_rc"
            fi
            rm -f "$_cs_out"
            _cs_secret="$(_exakit_vs_read_secret "New credential for $_cs_name" "$_cs_pwfile")" || exit 2
            [ -n "$_cs_secret" ] || reject "No credential was given."
            set -- "$@" reauth "$_cs_name" --secret-stdin
            if [ "$_cs_json" = 1 ]; then printf '%s' "$_cs_secret" | exakit_vs_engine "$@"; exit $?; fi
            _exakit_vs_run "$_cs_secret" "$@"; _cs_rc=$?; unset _cs_secret
            [ "$_cs_rc" -eq 0 ] && ok "$_cs_name is ready again with the new credential"
            exit "$_cs_rc" ;;
    esac
    if [ "$_cs_json" = 1 ]; then
        exakit_vs_engine "$@" < /dev/null 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        exit $?
    fi
    _exakit_vs_run "" "$@"
    _cs_rc=$?
    if [ "$_cs_rc" -eq 0 ] && [ "$_cs_dry" != 1 ]; then
        case "$_cs_action" in
            disconnect) ok "$_cs_name disconnected: VS_$(printf '%s' "$_cs_name" | tr 'a-z' 'A-Z') stays, its queries fail until you connect it again with --name $_cs_name"; exit 0 ;;
            remove) ok "$_cs_name removed"; exit 0 ;;
        esac
    fi
    [ -n "$EXAKIT_VS_RESULT" ] && printf '%s' "$EXAKIT_VS_RESULT" | run_python_any -c 'import json, sys
r = json.load(sys.stdin)
rows = r["sources"] if "sources" in r else r.get("issues")
if rows is not None:
    if not rows:
        print("  (none)")
    for s in rows:
        last = (s.get("last_check") or {})
        print("  %-16s %-11s %-14s %-14s %s" % (s["name"], s["connector"], s["schema"], s["status"],
              (last.get("at") or "never checked") + ((" - " + s["remedy"]) if s.get("remedy") else "")))
elif "connectors" in r:
    for c in r["connectors"]:
        print("  %-12s %-18s %-5s %-10s aliases: %s" % (c["id"], c["name"], c["tier"], c["status"], ", ".join(c.get("aliases", []))))
elif "drop" in r:
    print("  drops: " + ", ".join(r["drop"]))
    if r.get("keep"):
        print("  keeps: " + ", ".join(r["keep"]))
    if "delete_files" in r:
        print("  deletes %d unused file(s); keeps %d still shared" % (len(r["delete_files"]), len(r.get("keep_files", []))))
    print("  note: " + r["note"])
elif "checks" in r:
    if not r["checks"]:
        print("  (none)")
    for c in r["checks"]:
        print("  %-16s %s %s" % (c["name"], c["status"], c.get("evidence") or c.get("remedy") or ""))
else:
    for k in ("name", "connector", "status", "objects", "inputs", "pins", "tables", "last_check", "evidence", "remedy"):
        if r.get(k) not in (None, "", {}):
            print("  %-11s %s" % (k, json.dumps(r[k]) if isinstance(r[k], (dict, list)) else r[k]))' 2>/dev/null
    exit "$_cs_rc"
}
