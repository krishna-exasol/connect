#!/usr/bin/env bash
# The virtual schema engine (setup/virtual-schemas/engine) against a simulated
# Exasol (tests/lib/fake-exasol-vs.py) and a fake Personal deployment folder.
#
# The invariants worth a suite:
#   1. A secret travels on stdin into CREATE/ALTER CONNECTION and nowhere else:
#      not into argv, the source records, the registry, the output or errors.
#   2. A failed connect leaves nothing it created - objects or files - and
#      never touches what another source uses or what the kit did not make.
#   3. Shared files are reference-counted: removing one source keeps what
#      another still needs, and the last one out cleans up - without ever
#      removing a bucket the kit did not create.
#   4. disconnect drops only the CONNECTION; remove drops the owned objects.
#   5. Failures are classified (auth, tls, unreachable, dns, no Java) with an
#      exit code or status the shell and `exakit source issues` act on.
#   6. Every input is validated before it reaches a template.
#
#   bash tests/virtual-schemas.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '         expected: %s\n         actual:   %.400s\n' "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1"; printf '         missing: %s\n         in: %.400s\n' "$2" "$3" ;; esac; }
lacks() { case "$3" in *"$2"*) fail "$1"; printf '         unexpected: %s\n' "$2" ;; *) pass "$1" ;; esac; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
DEFS="$WORK/defs"; HOME_K="$WORK/kit"; DEPLOY="$WORK/deploy"; EXA="$DEPLOY/local/runtime/exa"
cp -R "$ROOT/setup/virtual-schemas" "$DEFS"
mkdir -p "$HOME_K" "$EXA/bucketfs/bfsdefault/default" "$EXA/jdbc"
printf 'kept\n' > "$EXA/jdbc/java.security"
SECRET='s3cr3t-Pa55'"'"'word'
NEWSECRET='n3w-T0ken-value'

# Small stand-in artifacts with real digests, pinned into the copied
# definitions and placed in the cache, so nothing is downloaded.
python3 - "$DEFS" "$HOME_K" <<'PY'
import hashlib, io, json, os, sys, zipfile
defs, home = sys.argv[1:3]
def seed(pin, data):
    pin["size"], pin["sha256"] = len(data), hashlib.sha256(data).hexdigest()
    folder = os.path.join(home, "cache", "virtual-schemas", pin["sha256"])
    os.makedirs(folder, exist_ok=True)
    open(os.path.join(folder, pin["asset"]), "wb").write(data)
for cid in ("postgresql", "mysql", "sqlserver", "oracle", "snowflake", "bigquery"):
    path = os.path.join(defs, "connectors", cid, "connector.json")
    doc = json.load(open(path))
    seed(doc["adapter"], ("adapter-" + cid).encode())
    if doc["driver"].get("bundle") == "zip":
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("GoogleBigQueryJDBC42.jar", b"a"); z.writestr("dep.jar", b"b"); z.writestr("EULA.txt", b"c")
        seed(doc["driver"], buf.getvalue())
    else:
        seed(doc["driver"], ("driver-" + cid).encode())
    json.dump(doc, open(path, "w"), indent=2)
PY

STATE="$WORK/db.json"
db() { printf '%s\n' "$1" > "$STATE"; }
dbq() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2], {"d": d}); print(json.dumps(v) if not isinstance(v, str) else v)' "$STATE" "$1"; }
eng() {
    EXAKIT_VS_FAKE_DB="$ROOT/tests/lib/fake-exasol-vs.py" FAKE_VS_STATE="$STATE" \
        python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$DEFS" --kit-home "$HOME_K" \
        --deployment-dir "$DEPLOY" --dsn 127.0.0.1:8563 --user sys --password-file /nonexistent "$@"
}
run() { OUT="$(eng "$@" 2>&1)"; RC=$?; }
run_secret() { local s="$1"; shift; OUT="$(printf '%s' "$s" | eng "$@" 2>&1)"; RC=$?; }
PG_SET="--set host=pg.example.com --set database=sales --set user=reader"

printf '\n== search and plan ==\n'
run resolve mssql; has "an alias resolves" '"connector": "sqlserver"' "$OUT"
run resolve sql; check "an ambiguous search is refused, exit 2" "2" "$RC"; has "...with the choices" "choices: postgresql, mysql, sqlserver" "$OUT"
db '{}'
run plan pg --name sales $PG_SET
check "plan: exit 0" "0" "$RC"
has "...names the objects" '"connection": "EXAKIT_SRC_SALES"' "$OUT"
has "...states the MCP exposure" "MCP read-only user can read every table of VS_SALES" "$OUT"
check "...and changes nothing" "[]" "$(dbq 'd.get("statements", [])')"

printf '\n== input validation ==\n'
for bad in "--set host=pg.example.com;DROP --set database=x --set user=u" "--set host=h --set port=70000 --set database=x --set user=u" \
           "--set host=h --set database=x --set user=u --set colour=red" "--set host=h --set database=x' --set user=u" \
           "--set host=h --set database=x --set user=u --set tls=sometimes"; do
    # shellcheck disable=SC2086
    run plan postgresql --name bad $bad
    check "refused with exit 2: $bad" "2" "$RC"
done
run plan postgresql --name Bad-Name $PG_SET; check "a source name outside [a-z][a-z0-9_] is refused" "2" "$RC"
for loop in localhost 127.0.0.1 ::1 LOCALHOST; do
    run plan postgresql --name sales --set host=$loop --set database=x --set user=u
    check "host=$loop is refused (it is the database itself)" "2" "$RC"
done
has "...with the address to use instead" "on macOS 192.168.64.1, on Linux and WSL host.containers.internal" "$OUT"
V6="$(python3 - "$ROOT" <<'PYV6'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
c = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas").connector("postgresql")
for given in ("2001:db8::1", "[2001:db8::1]"):
    v = plan.validate_inputs(c, {"host": given, "database": "d", "user": "u"})
    print(plan.jdbc_url(c, v).split("?")[0])
PYV6
)"
check "an IPv6 host is bracketed in the URL, written either way" \
    "jdbc:postgresql://[2001:db8::1]:5432/d|jdbc:postgresql://[2001:db8::1]:5432/d|" "$(printf '%s\n' "$V6" | tr '\n' '|')"

run plan postgresql --name sales --set host=h --set user=u; has "a missing required input is named" "database is required" "$OUT"

printf '\n== every connector, every TLS mode: the templates build ==\n'
TEMPLATES="$(python3 - "$ROOT" <<'PYT'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import plan
defs = plan.Definitions(sys.argv[1] + "/setup/virtual-schemas")
samples = {"host": "db.example.com", "database": "sales", "schema": "public", "user": "reader", "service": "ORCLPDB1",
           "account": "myorg-acct1", "warehouse": "COMPUTE_WH", "project": "my-proj", "dataset": "analytics"}
for entry in defs.entries():
    c = defs.connector(entry["id"])
    given = {s["name"]: samples[s["name"]] for s in c["inputs"] if s["name"] in samples}
    tls = next((s for s in c["inputs"] if s["name"] == "tls"), None)
    for mode in (tls["choices"] if tls else [None]):
        g = dict(given, **({"tls": mode} if mode else {}))
        try:
            v = plan.validate_inputs(c, g)
            url = plan.jdbc_url(c, v, {"key_path": "/buckets/x/key.json"})
            [t.format(**v) for t in c["vs_properties"].values()]
            ok = url.startswith("jdbc:") and "{" not in url and plan.source_host(c, v)
            print("%s/%s %s" % (c["id"], mode or "-", "ok" if ok else "BAD " + url))
        except Exception as e:
            print("%s/%s BAD %s" % (c["id"], mode or "-", e))
PYT
)"
check "13 connector/TLS combinations build a URL, properties and a probe host" "13 0" \
    "$(printf '%s\n' "$TEMPLATES" | grep -c ' ok$') $(printf '%s\n' "$TEMPLATES" | grep -c ' BAD')"

printf '\n== failure classes, from real driver messages ==\n'
CLASSES="$(python3 - "$ROOT" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
for text in [
    "E-VSPG-3: Unable to create PostgreSQL remote metadata reader. Caused by: 'The connection attempt failed.'",
    "E-VSMYSQL-1: Unable to create MySQL remote metadata reader. Caused by: Communications link failure",
    "E-VSSQLS-2: ... The TCP/IP connection to the host 192.168.64.1, port 55432 has failed. Error: \"The driver received an unexpected pre-login response.",
    "E-VSORA-1: Unable to create Oracle remote metadata reader. Caused by: ORA-17800: Got minus one from a read call.",
    'FATAL: password authentication failed for user "reader"',
    "ORA-01017: invalid username/password; logon denied",
    "PKIX path building failed: unable to find valid certification path to requested target",
    "No usable script language container is installed for the requested language.",
    "java.net.UnknownHostException: db.example.com",
]:
    print(sql.classify(text))
PYC
)"
check "each real message lands in its class" "unreachable|unreachable|unreachable|unreachable|auth|auth|tls|nojava|dns|" \
    "$(printf '%s\n' "$CLASSES" | tr '\n' '|')"
# Measured live: a rotated source password. The summary line is the
# adapter's generic "Unable to create ... reader"; the cause is lines below.
RAW_AUTH='Query execution failed: Protocol error: VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006:
com.exasol.adapter.jdbc.RemoteMetadataReaderException: E-VSEXA-4: Unable to create Exasol remote metadata reader.
	at com.exasol.adapter.dialects.exasol.ExasolSqlDialect.createRemoteMetadataReader(ExasolSqlDialect.java:212)
	at com.exasol.ssl.TlsHelper.wrap(TlsHelper.java:9)
Caused by: java.sql.SQLInvalidAuthorizationSpecException: Connection exception - authentication failed.'
check "a cause on a later line still classifies (auth), not the generic summary" "auth" \
    "$(python3 - "$ROOT" "$RAW_AUTH" <<'PYC'
import sys; sys.path.insert(0, sys.argv[1] + "/setup/virtual-schemas/engine")
import sql
raw = sys.argv[2]
print(sql.classify_raw(sql.summarize(raw), raw))
PYC
)"

printf '\n== connect: the happy path ==\n'
db '{"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"]}}}'
run connect postgresql --name sales $PG_SET --secret-stdin </dev/null
check "no secret on stdin: refused, exit 2" "2" "$RC"
run_secret "$SECRET" connect postgresql --name sales $PG_SET --secret-stdin
check "connect: exit 0" "0" "$RC"
has "...reports the tables and the bounded read" "Virtual schema VS_SALES: 2 table(s); a bounded read succeeded" "$OUT"
check "...the CONNECTION carries the credential" "$SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
check "...and verified TLS in its URL" "jdbc:postgresql://pg.example.com:5432/sales?sslmode=verify-full&sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory" \
    "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["url"]')"
check "...adapter script and virtual schema exist" '["EXAKIT_VS.EXAKIT_DNS_PROBE_V2", "EXAKIT_VS.ADAPTER_SALES"] ["ORDERS", "CUSTOMERS"]' \
    "$(dbq 'd["scripts"]') $(dbq 'd["virtual"]["VS_SALES"]["tables"]')"
ADAPTER_SQL="$(dbq '[s for s in d["statements"] if "ADAPTER SCRIPT" in s][0]')"
has "...the adapter script lists the staged adapter" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar;" "$ADAPTER_SQL"
has "...and the driver" "%jar /buckets/bfsdefault/default/exakit/vs/postgresql/driver-42.7.14/postgresql-42.7.14.jar;" "$ADAPTER_SQL"
has "...with telemetry off" "%env EXASOL_TELEMETRY_DISABLE=1;" "$ADAPTER_SQL"
has "the virtual schema has the dialect's properties" "CATALOG_NAME = 'sales' SCHEMA_NAME = 'public'" "$(dbq '[s for s in d["statements"] if s.startswith("CREATE VIRTUAL SCHEMA")][0]')"
check "files staged where SQL reads them" "yes yes" \
    "$([ -f "$EXA/bucketfs/bfsdefault/default/exakit/vs/postgresql/4.1.0/virtual-schema-dist-14.1.0-postgresql-4.1.0.jar" ] && echo yes) $([ -f "$EXA/bucketfs/bfsdefault/default/exakit/vs/postgresql/driver-42.7.14/postgresql-42.7.14.jar" ] && echo yes)"
CFG="$EXA/jdbc/POSTGRES_JDBC_DRIVER/settings.cfg"
check "the loader driver's settings.cfg: documented keys, final blank line" \
    "DRIVERNAME=POSTGRES_JDBC_DRIVER|PREFIX=jdbc:postgresql:|DRIVERMAIN=org.postgresql.Driver|FETCHSIZE=100000|INSERTSIZE=-1|JAR=postgresql-42.7.14.jar||" \
    "$(tr '\n' '|' < "$CFG")"
check "the source record says ready" "ready" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/sales/state.json")"
lacks "the secret is not in the output" "s3cr3t" "$OUT"
check "...nor anywhere under the kit home" "" "$(grep -rl 's3cr3t' "$HOME_K/sources" 2>/dev/null)"
check "the source folder is owner-only" "700" "$(stat -c '%a' "$HOME_K/sources/sales" 2>/dev/null || stat -f '%Lp' "$HOME_K/sources/sales")"

printf '\n== a second source on the same connector shares the files ==\n'
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["wh.example.com"] = {"tables": ["STOCK"]}; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect postgresql --name warehouses --set host=wh.example.com --set database=wh --set user=reader --secret-stdin
check "connect warehouses: exit 0" "0" "$RC"
check "the shared driver lists both consumers" '["sales", "warehouses"]' \
    "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["artifacts"]; print(json.dumps(next(v["consumers"] for k,v in r.items() if k.endswith("POSTGRES_JDBC_DRIVER/postgresql-42.7.14.jar"))))' "$HOME_K/sources/registry.json")"
run_secret "$SECRET" connect postgresql --name sales $PG_SET --secret-stdin
check "a name already in use is a conflict, exit 3" "3" "$RC"

printf '\n== a failed connect leaves nothing behind ==\n'
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["bad.example.com"] = {"tables": ["T"], "fail": "auth"}; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=bad.example.com --set database=crm --set user=reader --secret-stdin
check "rejected credentials: exit 1" "1" "$RC"
has "...said plainly, with what to do" "the source rejected the credentials; nothing was kept" "$OUT"
check "...its CONNECTION, script and schema were undone" "false false false" \
    "$(dbq '"EXAKIT_SRC_CRM" in d["connections"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_CRM" in d["scripts"]' | tr A-Z a-z) $(dbq '"VS_CRM" in d["virtual"]' | tr A-Z a-z)"
check "...no record and no files of its own remain" "no no no" \
    "$([ -d "$HOME_K/sources/crm" ] && echo yes || echo no) $([ -d "$EXA/bucketfs/bfsdefault/default/exakit/vs/mysql" ] && echo yes || echo no) $([ -d "$EXA/jdbc/MYSQL" ] && echo yes || echo no)"
check "...while the other sources' files are untouched" "yes" "$([ -f "$CFG" ] && echo yes)"
lacks "...and the secret never reaches the error text" "s3cr3t" "$OUT"
run_secret "$SECRET" connect mysql --name crm --set host=down.example.com --set database=crm --set user=reader --secret-stdin
check "a host the source list does not know: exit 1" "1" "$RC"

python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = False; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=pg.example.com --set database=crm --set user=reader --secret-stdin
check "Java without DNS: exit 20, for the shell to repair and retry" "20" "$RC"
python3 - "$STATE" <<'PYDNS'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = True; json.dump(d, open(sys.argv[1], "w"))
PYDNS
run_secret "$SECRET" connect mysql --name crm --set host=no-such-db.invalid --set database=crm --set user=reader --secret-stdin
check "a name that does not exist is not a DNS repair: exit 1" "1" "$RC"; has "...said as a spelling problem" "does not resolve; nothing was kept - check the spelling" "$OUT"
lacks "...without the firewall advice meant for a host that answers nothing" "firewall" "$OUT"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["dns"] = True; d["unreachable"] = ["slow.example.com"]; json.dump(d, open(sys.argv[1], "w"))
PY
run_secret "$SECRET" connect mysql --name crm --set host=slow.example.com --set database=crm --set user=reader --secret-stdin
check "a host that resolves but does not answer: exit 1" "1" "$RC"; has "...named as unreachable from inside the database" "is not reachable from inside the database" "$OUT"
lacks "...said once, not restated in a second parenthesis" "did not answer from inside the database" "$OUT"
db '{"java": false}'
run_secret "$SECRET" connect oracle --name erp --set host=ora.example.com --set service=ORCL --set schema=APP --set user=reader --secret-stdin
check "no Java in the database: exit 21, for the shell to offer the install" "21" "$RC"

printf '\n== an interrupted connect is recovered, not mistaken for a stranger ==\n'
# The state an attempt killed right after CREATE CONNECTION leaves behind: its
# journal (naming what it made) and the connection in the database.
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}, "connections": {"EXAKIT_SRC_LATE": {"url": "x", "user": "reader", "secret": "half-done"}}}'
mkdir -p "$HOME_K/sources/late"
printf '{"operation": "connect", "connector": "postgresql", "created": {"files": [], "connection": true, "script": false, "schema": false}}\n' > "$HOME_K/sources/late/journal.json"
run_secret "$SECRET" connect postgresql --name late $PG_SET --secret-stdin
check "a retry after an interrupted connect succeeds" "0" "$RC"
has "...and says what it cleaned up first" "was interrupted; removing what it created first" "$OUT"
check "...the connection now holds the new attempt's credential" "$SECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_LATE"]["secret"]')"
run remove late >/dev/null
# A journal with nothing recorded is simply cleared.
mkdir -p "$HOME_K/sources/late2"; printf '{"operation": "connect", "created": {"files": []}}\n' > "$HOME_K/sources/late2/journal.json"
run_secret "$SECRET" connect postgresql --name late2 $PG_SET --secret-stdin
check "an empty journal does not block a connect" "0" "$RC"
run remove late2 >/dev/null

printf '\n== what the kit does not own ==\n'
db '{"sources": {"pg.example.com": {"tables": ["ORDERS"]}}, "connections": {"EXAKIT_SRC_HR": {"url": "x", "user": "u", "secret": "theirs"}}}'
run_secret "$SECRET" connect postgresql --name hr $PG_SET --secret-stdin
check "a CONNECTION the kit did not create: conflict, exit 3" "3" "$RC"
check "...and it is left exactly as it was" "theirs" "$(dbq 'd["connections"]["EXAKIT_SRC_HR"]["secret"]')"
mkdir -p "$EXA/jdbc/SQLSERVER"; printf 'DRIVERNAME=SQLSERVER\nJAR=theirs.jar\n' > "$EXA/jdbc/SQLSERVER/settings.cfg"
db '{"sources": {"ms.example.com": {"tables": ["T"]}}}'
run_secret "$SECRET" connect mssql --name fin --set host=ms.example.com --set database=fin --set user=reader --secret-stdin
check "a loader driver the kit did not register: conflict, exit 3" "3" "$RC"
check "...its settings.cfg untouched" "JAR=theirs.jar" "$(sed -n 2p "$EXA/jdbc/SQLSERVER/settings.cfg")"
rm -rf "$EXA/jdbc/SQLSERVER"
run_secret "{}" connect bigquery --name bq --set project=p --set dataset=d --secret-stdin
check "a gated connector explains its gate, exit 5" "5" "$RC"; has "...naming it" "not qualified on Exasol Personal yet" "$OUT"
run connect bigquery --name bq --dry-run
check "...before any input is asked for, dry run included" "5" "$RC"; lacks "...no input complaint" "is required" "$OUT"
run resolve bq
check "resolving a gated connector says so, exit 5 (the wizard asks nothing)" "5" "$RC"; has "...with the reason" "not available yet" "$OUT"

printf '\n== check, issues, reauth ==\n'
# Back to the two healthy sources from the happy path.
python3 - "$STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.update({"sources": {"pg.example.com": {"tables": ["ORDERS", "CUSTOMERS"], "secret": "s3cr3t-Pa55'word"},
                      "wh.example.com": {"tables": ["STOCK"]}},
          "connections": {"EXAKIT_SRC_SALES": {"url": "jdbc:postgresql://pg.example.com:5432/sales", "user": "reader", "secret": "s3cr3t-Pa55'word"},
                          "EXAKIT_SRC_WAREHOUSES": {"url": "jdbc:postgresql://wh.example.com:5432/wh", "user": "reader", "secret": "x"}},
          "schemas": ["EXAKIT_VS"], "scripts": ["EXAKIT_VS.EXAKIT_DNS_PROBE_V2", "EXAKIT_VS.ADAPTER_SALES", "EXAKIT_VS.ADAPTER_WAREHOUSES"],
          "virtual": {"VS_SALES": {"connection": "EXAKIT_SRC_SALES", "tables": ["ORDERS", "CUSTOMERS"]},
                      "VS_WAREHOUSES": {"connection": "EXAKIT_SRC_WAREHOUSES", "tables": ["STOCK"]}}})
json.dump(d, open(sys.argv[1], "w"))
PY
run check sales; check "check: ready" "0" "$RC"; has "...with its evidence" "metadata and a bounded read (2 tables)" "$OUT"
python3 - "$STATE" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["sources"]["pg.example.com"]["secret"] = "n3w-T0ken-value"; json.dump(d, open(sys.argv[1], "w"))
PY
run check sales; check "a rotated credential at the source: check exits 1" "1" "$RC"
has "...and says why, though no RESULT line follows a failure" "FAIL sales is auth-failed:" "$OUT"
has "...with the fix" "INFO Fix: the source rejected the credentials: exakit source reauth sales" "$OUT"
check "...the record says auth-failed" "auth-failed" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$HOME_K/sources/sales/state.json")"
run --json issues; has "issues lists it" '"name": "sales"' "$OUT"; has "...with the runnable remedy" "exakit source reauth sales" "$OUT"
lacks "...and not the healthy one" '"name": "warehouses"' "$OUT"
run --json check --all; check "check --all: exit 1 while one source is failing" "1" "$RC"
run_secret "$NEWSECRET" reauth sales --secret-stdin
check "reauth with the new credential: ready again" "0" "$RC"
check "...the CONNECTION holds it" "$NEWSECRET" "$(dbq 'd["connections"]["EXAKIT_SRC_SALES"]["secret"]')"
check "...and it is in no file" "" "$(grep -rl 'n3w-T0ken' "$HOME_K/sources" 2>/dev/null)"
run refresh warehouses; has "refresh reports the table count" '"tables": 1' "$OUT"

printf '\n== disconnect and reconnect ==\n'
run disconnect sales --dry-run; check "disconnect --dry-run changes nothing" "true" "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"
has "...and says what it keeps" "virtual schema VS_SALES" "$OUT"
run disconnect sales
check "disconnect drops only the CONNECTION" "false true true" \
    "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z) $(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_SALES" in d["scripts"]' | tr A-Z a-z)"
run check sales; has "a disconnected source is skipped by check" '"skipped": true' "$OUT"
run_secret "$NEWSECRET" connect postgresql --name sales $PG_SET --secret-stdin
check "connect on a disconnected source reconnects it" "0" "$RC"
check "...recreating the CONNECTION" "true" "$(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"

printf '\n== remove: owned objects, shared files kept until the last consumer ==\n'
DRIVER="$EXA/jdbc/POSTGRES_JDBC_DRIVER/postgresql-42.7.14.jar"
run remove sales --dry-run; has "remove --dry-run lists what it keeps" "keep_files" "$OUT"; check "...and changes nothing" "true" "$(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z)"
run remove sales
check "remove sales: its objects are gone" "false false false" \
    "$(dbq '"VS_SALES" in d["virtual"]' | tr A-Z a-z) $(dbq '"EXAKIT_VS.ADAPTER_SALES" in d["scripts"]' | tr A-Z a-z) $(dbq '"EXAKIT_SRC_SALES" in d["connections"]' | tr A-Z a-z)"
check "...the driver warehouses still uses stays" "yes" "$([ -f "$DRIVER" ] && echo yes)"
check "...and so does the kit schema" "true" "$(dbq '"EXAKIT_VS" in d["schemas"]' | tr A-Z a-z)"
run disconnect warehouses
run remove warehouses
check "remove after disconnect works (the adapter callback is skipped)" "0" "$RC"
has "...with FORCE, on the kit's own schema only" 'DROP FORCE VIRTUAL SCHEMA "VS_WAREHOUSES"' "$(dbq '" | ".join(s for s in d["statements"] if "VIRTUAL SCHEMA" in s and s.startswith("DROP"))')"
check "the last consumer out: shared files deleted" "no no" "$([ -f "$DRIVER" ] && echo yes || echo no) $([ -d "$EXA/jdbc/POSTGRES_JDBC_DRIVER" ] && echo yes || echo no)"
check "...the kit schema dropped" "false" "$(dbq '"EXAKIT_VS" in d["schemas"]' | tr A-Z a-z)"
check "...but never the bucket or what the kit did not make" "yes yes" \
    "$([ -d "$EXA/bucketfs/bfsdefault/default" ] && echo yes) $([ -f "$EXA/jdbc/java.security" ] && echo yes)"
run --json list; has "nothing is listed" '"sources": []' "$OUT"
run show sales; check "show on a removed source: exit 4" "4" "$RC"

printf '\n== the shell bridge (setup/lib/virtual-schemas.sh) ==\n'
# A stand-in engine records its arguments and its stdin, and answers with the
# exit code a test arranges - so what the bridge does with each is observable.
B="$WORK/bridge"; mkdir -p "$B"
bridge() {
    ( EXAKIT_HOME="$B/home"; mkdir -p "$EXAKIT_HOME"
      . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/detect.sh"; . "$ROOT/setup/lib/runtime-personal.sh"
      . "$ROOT/setup/lib/virtual-schemas.sh"
      _require_install() { :; }; exakit_init_logging() { :; }
      exakit_vs_engine() {
          printf '%s\n' "$*" >> "$B/argv"
          [ -t 0 ] || cat >> "$B/stdin"
          _n="$(wc -l < "$B/argv" | tr -d ' ')"
          _code="$(sed -n "${_n}p" "$B/codes" 2>/dev/null)"
          if [ "$1" = resolve ] && [ -f "$B/gated" ]; then echo "FAIL BigQuery is not available yet: gated"; return 5; fi
          case "$1" in check) echo 'RESULT {"checks": []}' ;; show) echo "FAIL no source named $2 (see: exakit source list)" ;; resolve) echo 'RESULT {"connector": "postgresql"}' ;; plan) echo 'RESULT {"name": "x", "connector": "postgresql", "tier": "GA", "status": "candidate", "downloads": [], "steps": [], "exposure": "e", "warnings": []}' ;; esac
          return "${_code:-0}"
      }
      personal_slc_dns_repair() { echo "REPAIRED" >> "$B/argv"; return 0; }
      _exakit_vs_install_java() { echo "JAVA-ASKED" >> "$B/argv"; return 1; }
      "$@" ) 2>&1
}
reset_bridge() { rm -f "$B/argv" "$B/stdin" "$B/codes"; printf '%s\n' "$@" > "$B/codes"; }

reset_bridge
OUT="$(bridge cmd_connect pg --name sales --password=hunter2 </dev/null)"; RC=$?
check "a password argument is refused before anything runs, exit 2" "2 no" "$RC $([ -f "$B/argv" ] && echo yes || echo no)"
OUT="$(bridge cmd_connect pg --set host=h </dev/null)"; RC=$?
check "unattended, the name is required" "2" "$RC"
reset_bridge 0 0 0
printf 'pw-from-stdin' > "$B/pw"
OUT="$(bridge cmd_connect pg --name sales --set host=db.example.com --set user=reader --password-file "$B/pw" </dev/null)"; RC=$?
check "connect with a password file: exit 0" "0" "$RC"
check "...the engine ran resolve, plan, connect - the last with --secret-stdin" \
    "resolve pg|plan postgresql --name sales --set host=db.example.com --set user=reader|connect postgresql --name sales --set host=db.example.com --set user=reader --secret-stdin|" \
    "$(tr '\n' '|' < "$B/argv")"
check "...the credential reached it on stdin" "pw-from-stdin" "$(cat "$B/stdin")"
lacks "...and never as an argument" "pw-from-stdin" "$(cat "$B/argv")"
reset_bridge 0 0 20 0
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "exit 20 from the engine: DNS repaired, connect retried once, exit 0" \
    "0 connect|REPAIRED|connect|" "$RC $(grep -E '^(connect|REPAIRED)' "$B/argv" | cut -d' ' -f1 | tr '\n' '|')"
reset_bridge 0 0 21
OUT="$(bridge cmd_connect pg --name sales --set host=h --password-file "$B/pw" </dev/null)"; RC=$?
check "exit 21: the Java install is offered; declined, nothing retried" "21 1" "$RC $(grep -c '^connect' "$B/argv")"
has "...the offer was made" "JAVA-ASKED" "$(cat "$B/argv")"
reset_bridge 0
OUT="$(bridge cmd_source remove sales --dry-run </dev/null)"
check "source remove --dry-run passes the preview through" "remove sales --dry-run" "$(cat "$B/argv")"
OUT="$(bridge cmd_source remove </dev/null)"; RC=$?
check "source remove without a name: exit 2" "2" "$RC"
OUT="$(bridge cmd_source bogus </dev/null)"; RC=$?
check "an unknown action: exit 2" "2" "$RC"
reset_bridge 4
OUT="$(bridge cmd_source reauth nosuch --password-file "$B/pw" </dev/null)"; RC=$?
check "reauth of a source that does not exist: exit 4, before any credential" "4 show nosuch|" "$RC $(tr '\n' '|' < "$B/argv")"
check "...nothing reached the engine's stdin" "no" "$([ -s "$B/stdin" ] && echo yes || echo no)"
has "...and says which name" "no source named nosuch" "$OUT"
reset_bridge 0
OUT="$(bridge cmd_source check --all </dev/null)"
has "check --all with no sources says so" "(none)" "$OUT"
reset_bridge; : > "$B/gated"
OUT="$(bridge cmd_connect bq --name b </dev/null)"; RC=$?
check "a gated connector stops the wizard with the engine's exit 5" "5 resolve bq|resolve bq|" "$RC $(tr '\n' '|' < "$B/argv")"
has "...and the reason is shown" "not available yet" "$OUT"
rm -f "$B/gated"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
