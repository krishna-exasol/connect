"""A stand-in for `exapump sql -p <profile> -f json`, backed by a JSON state file.

Simulates exactly the slice of Exasol the preprocessor setup touches: the
SQL_PREPROCESSOR_SCRIPT slot (system and session), the PREPROC/PREPROC_RT
schemas, their scripts, the PREPROC_ADMIN role, the rules in PREPROC.CONFIG,
and whether a statement is dispatched to the kit's probe module. One
invocation is one session, as with the real tool.

Like exapump: statements end at ';', a script body runs from its CREATE line
to a lone '/', execution stops at the first failing statement with exit 1 and
an "Error: ..." line on stderr, and each SELECT prints one JSON array.

    FAKE_EXAPUMP_STATE=/path/state.json python3 fake-exapump.py sql -p P -f json

state.json keys (all optional): system_slot, schemas, scripts, role, rules,
faults (list), calls (appended: one list of statements per invocation).
Faults: fail_on:<substring>, no_dispatch, break_ordinary_when_active,
fail_alter_system, down. Like a local deployment with no script language
container, a PYTHON3 script cannot be created unless state has "python": true.
"""

import json
import os
import re
import sys

DISPATCHER = "PREPROC_RT.MASTER"
PROBE = "PREPROC_RT.EXAKIT_PROBE_V1"


def load(path):
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        doc = {}
    doc.setdefault("system_slot", "")
    doc.setdefault("schemas", [])
    doc.setdefault("scripts", [])
    doc.setdefault("role", False)
    doc.setdefault("rules", [])
    doc.setdefault("faults", [])
    doc.setdefault("calls", [])
    return doc


def split(text):
    statements, current, in_script = [], [], False
    for line in text.splitlines():
        stripped = line.strip()
        if in_script:
            if stripped == "/":
                statements.append("\n".join(current).strip())
                current, in_script = [], False
            else:
                current.append(line)
            continue
        if not current and (stripped.startswith("--") or not stripped):
            continue
        current.append(line)
        if re.match(r"(?i)^\s*CREATE\s+(OR\s+REPLACE\s+)?(LUA|PYTHON3)\b", "\n".join(current)):
            in_script = True
            continue
        if stripped.endswith(";"):
            statements.append("\n".join(current).strip().rstrip(";").strip())
            current = []
    if current and "\n".join(current).strip():
        statements.append("\n".join(current).strip().rstrip(";").strip())
    return statements


class Fail(Exception):
    pass


def norm(value):
    value = (value or "").strip().strip("'").replace('"', "").upper()
    return "" if value in ("", "NULL") else value


def run(doc, sql, out):
    up = sql.upper()
    session = doc["_session"]
    effective = session if session is not None else doc["system_slot"]
    active = effective == DISPATCHER and DISPATCHER in doc["scripts"]
    for fault in doc["faults"]:
        if fault.startswith("fail_on:") and fault[len("fail_on:"):] in sql:
            raise Fail("injected failure on %s" % fault[len("fail_on:"):])
    m = re.match(r"(?is)^ALTER\s+(SESSION|SYSTEM)\s+SET\s+sql_preprocessor_script\s*=\s*(.*)$", sql)
    if m:
        value = norm(m.group(2))
        if m.group(1).upper() == "SYSTEM":
            if "fail_alter_system" in doc["faults"]:
                raise Fail("insufficient privileges for ALTER SYSTEM")
            doc["system_slot"] = value
        else:
            doc["_session"] = value
        return
    if up.startswith("SELECT 'EXAKIT_PP_ORDINARY'"):
        if active and "break_ordinary_when_active" in doc["faults"]:
            raise Fail("preprocessor error: ordinary statement rewritten badly")
        out.append([{"R": "EXAKIT_PP_ORDINARY"}])
        return
    if up.startswith("SELECT 'EXAKIT_PP_PROBE_IN'"):
        dispatched = (active and "no_dispatch" not in doc["faults"] and PROBE in doc["scripts"]
                      and any(rule["script"] == PROBE for rule in doc["rules"]))
        out.append([{"R": "EXAKIT_PP_PROBE_OUT" if dispatched else "EXAKIT_PP_PROBE_IN"}])
        return
    if "FROM EXA_PARAMETERS" in up:
        out.append([{"S": doc["system_slot"]}] if doc["system_slot"] else [{}])
        return
    if "FROM EXA_SCHEMAS" in up:
        out.append([{"N": name} for name in doc["schemas"]])
        return
    if "FROM EXA_ALL_SCRIPTS" in up:
        out.append([{"N": name} for name in doc["scripts"]])
        return
    if "FROM EXA_DBA_ROLES" in up:
        out.append([{"N": "PREPROC_ADMIN"}] if doc["role"] else [])
        return
    if "FROM PREPROC.CONFIG" in up:
        if "PREPROC" not in doc["schemas"]:
            raise Fail("object PREPROC.CONFIG not found")
        if "DISTINCT SCRIPT_NAME" in up:
            out.append([{"N": name} for name in sorted(set(r["script"] for r in doc["rules"]))])
        else:
            wanted = re.search(r"SCRIPT_NAME\s*=\s*'([^']*)'", sql).group(1)
            out.append([{"ID": r["id"]} for r in doc["rules"] if r["script"] == wanted])
        return
    if "FROM PREPROC_RT.MY_PIPELINE" in up:
        if "PREPROC_RT" not in doc["schemas"]:
            raise Fail("object PREPROC_RT.MY_PIPELINE not found")
        out.append([{"N": 0}])
        return
    if up.startswith("CREATE ROLE"):
        if doc["role"]:
            raise Fail("role PREPROC_ADMIN already exists")
        doc["role"] = True
        return
    m = re.match(r"(?i)^CREATE SCHEMA (IF NOT EXISTS )?(\w+)", sql)
    if m:
        if m.group(2).upper() not in doc["schemas"]:
            doc["schemas"].append(m.group(2).upper())
        return
    m = re.match(r"(?is)^CREATE\s+(OR\s+REPLACE\s+)?(LUA|PYTHON3)[\w\s]*?SCRIPT\s+([\w.]+)", sql)
    if m and m.group(2).upper() == "PYTHON3" and not doc.get("python"):
        raise Fail("No usable script language container is installed for the requested language.")
    if m:
        name = m.group(3).upper()
        if name.split(".")[0] not in doc["schemas"]:
            raise Fail("schema %s not found" % name.split(".")[0])
        if name not in doc["scripts"]:
            doc["scripts"].append(name)
        return
    if up.startswith("INSERT INTO PREPROC.CONFIG"):
        doc["rules"].append({"id": len(doc["rules"]) + 1, "script": "PREPROC_RT.CONTROL_SUGAR_V1"})
        return
    m = re.match(r"(?is)^EXECUTE SCRIPT PREPROC.RULE_ENSURE\((.*)\)$", sql)
    if m:
        script = re.findall(r"'([^']*)'", m.group(1))[3].upper()
        if script not in doc["scripts"]:
            raise Fail("script %s does not exist" % script)
        existing = [r for r in doc["rules"] if r["script"] == script]
        if not existing:
            existing = [{"id": max([r["id"] for r in doc["rules"]] or [0]) + 1, "script": script}]
            doc["rules"].append(existing[0])
        out.append([{"RULE_ID": existing[0]["id"]}])
        return
    m = re.match(r"(?i)^EXECUTE SCRIPT PREPROC.RULE_DROP\((\d+)", sql)
    if m:
        doc["rules"] = [r for r in doc["rules"] if r["id"] != int(m.group(1))]
        out.append([{"DROPPED": 1}])
        return
    m = re.match(r"(?i)^DROP SCRIPT (IF EXISTS )?([\w.]+)", sql)
    if m:
        doc["scripts"] = [s for s in doc["scripts"] if s != m.group(2).upper()]
        return
    m = re.match(r"(?i)^DROP SCHEMA (IF EXISTS )?(\w+)", sql)
    if m:
        schema = m.group(2).upper()
        doc["schemas"] = [s for s in doc["schemas"] if s != schema]
        doc["scripts"] = [s for s in doc["scripts"] if not s.startswith(schema + ".")]
        if schema == "PREPROC":
            doc["rules"] = []
        return
    if up.startswith("DROP ROLE"):
        doc["role"] = False
        return
    if up.startswith("EXECUTE SCRIPT PREPROC.STATUS"):
        stale = bool(doc.get("stale"))
        out.append([{"IS_STALE": stale, "VERDICT": "STALE" if stale else "CURRENT", "LAST_REFRESH": "2026-10-27 21:21:09"}])
        return
    if up.startswith("EXECUTE SCRIPT PREPROC.REFRESH"):
        doc["stale"] = False
        out.append([{"REFRESHED": True}])
        return
    if up.startswith("EXECUTE SCRIPT"):
        out.append([])
        return
    # Anything else (GRANT, ALTER SCHEMA, CREATE TABLE, SELECT 1 ...) succeeds.
    if up.startswith("SELECT"):
        out.append([{"X": 1}])


def main():
    path = os.environ["FAKE_EXAPUMP_STATE"]
    doc = load(path)
    args = sys.argv[1:]
    sql = args[-1] if args and args[0] == "sql" and not args[-1].startswith("-") and args[-1] != "json" else None
    text = sql if sql is not None else sys.stdin.read()
    statements = split(text)
    doc["calls"].append(statements)
    if "down" in doc["faults"]:
        with open(path, "w") as handle:
            json.dump(doc, handle, indent=1)
        sys.stderr.write("Error: Connection refused\n")
        return 1
    doc["_session"] = None
    out, rc = [], 0
    for index, statement in enumerate(statements, 1):
        sys.stderr.write("[%d/%d] %s\n" % (index, len(statements), statement[:60].replace("\n", " ")))
        try:
            run(doc, statement, out)
        except Fail as error:
            sys.stderr.write("Error in statement %d:\n  %s\n\n  Query execution failed: %s\n" % (index, statement[:60], error))
            sys.stderr.write("Error: Query execution failed: %s (Session: 1)\n" % error)
            rc = 1
            break
    doc.pop("_session", None)
    with open(path, "w") as handle:
        json.dump(doc, handle, indent=1)
    sys.stdout.write("\n".join(json.dumps(result) for result in out))
    return rc


if __name__ == "__main__":
    sys.exit(main())
