"""Connect, check, reauth, refresh, disconnect and remove one named source.

Every operation takes the sources lock, journals its steps, and on failure
undoes only what THIS attempt created - never an object it did not make, never
a file another source still uses. A multi-step setup is not one transaction,
and nothing here pretends it is: an interrupted run leaves a journal the next
run reports, and its objects carry the kit's names so it can finish or clean up.

Object names for a source <name>:
    CONNECTION       EXAKIT_SRC_<NAME>      the credential, readable only through SQL privileges
    virtual schema   VS_<NAME>              the tables a user queries
    adapter script   EXAKIT_VS.ADAPTER_<NAME>
The EXAKIT_VS schema also holds the DNS probe, and is dropped with the last source.
"""

import os

import artifacts
import plan as planner
import sources
import sql

PROBE = "EXAKIT_DNS_PROBE_V2"

EXIT = {"ok": 0, "failed": 1, "input": 2, "conflict": 3, "missing": 4, "gated": 5,
        "dns": 20, "nojava": 21, "unreachable_db": 22}

# Status recorded for a failure kind (sql.classify).
STATUS_FOR = {"auth": "auth-failed", "tls": "tls-failed", "unreachable": "unreachable",
              "dns": "dns-failed", "nojava": "failed", "error": "failed"}

REMEDY_FOR = {
    "auth": "the source rejected the credentials: exakit source reauth {name}",
    "tls": "the source's certificate or host name did not verify; fix the server certificate or trust its CA, then: exakit source check {name}",
    "unreachable": "the source did not answer from inside the database: check the host, port, firewall and VPN (a source on this computer must listen beyond 127.0.0.1), then: exakit source check {name}",
    "dns": "Java in the database could not resolve the host name; restart the database with exakit start (it repairs DNS), then: exakit source check {name}",
    "nojava": "the Java language container is not installed: exakit connect installs it, or run: exasol slc install java",
    "error": "see the log: exakit logs",
}


class Failure(Exception):
    def __init__(self, message, code, kind="error"):
        super().__init__(message)
        self.code = code
        self.kind = kind


class Engine(object):
    def __init__(self, args, emit):
        self.args = args
        self.emit = emit
        self.defs = planner.Definitions(args.defs)
        self.store = sources.Store(args.kit_home)
        self.cache = artifacts.Cache(args.kit_home, log=lambda text: emit("INFO", text))
        self.profile = self.defs.profile("java-jdbc")
        self.runtime = artifacts.Runtime(args.deployment_dir or "", self.profile["bucket"])
        self._db = None

    # --- the database --------------------------------------------------------------
    def db(self):
        if self._db is None:
            try:
                self._db = sql.connect(self.args.dsn, self.args.user, self.args.password_file)
            except sql.DbError as error:
                raise Failure("the local database is not reachable: %s" % error, EXIT["unreachable_db"])
        return self._db

    def close(self):
        if self._db is not None:
            self._db.close()

    def exists(self, kind, *names):
        db = self.db()
        if kind == "connection":
            rows = db.query("SELECT CONNECTION_NAME FROM EXA_DBA_CONNECTIONS WHERE CONNECTION_NAME = %s"
                            % sql.literal(names[0]))
        elif kind == "schema":
            rows = db.query("SELECT SCHEMA_NAME FROM EXA_SCHEMAS WHERE SCHEMA_NAME = %s" % sql.literal(names[0]))
        else:
            rows = db.query("SELECT SCRIPT_NAME FROM EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA = %s AND SCRIPT_NAME = %s"
                            % (sql.literal(names[0]), sql.literal(names[1])))
        return bool(rows)

    # --- prerequisites ---------------------------------------------------------------
    def ensure_probe(self):
        """EXAKIT_VS and its Java DNS probe; tells a missing Java container apart."""
        db = self.db()
        if not self.exists("schema", "EXAKIT_VS"):
            db.execute("CREATE SCHEMA EXAKIT_VS")
        try:
            db.execute(
                "CREATE OR REPLACE JAVA SCALAR SCRIPT EXAKIT_VS.%s(h VARCHAR(253), p DECIMAL(5,0)) "
                "RETURNS VARCHAR(400) AS\n"
                "import java.net.*;\n"
                "class %s { static String run(ExaMetadata exa, ExaIterator ctx) throws Exception {\n"
                "  String h = ctx.getString(\"h\"); int p = ctx.getInteger(\"p\");\n"
                "  InetAddress a;\n"
                "  try { a = InetAddress.getByName(h); } catch (Exception e) {\n"
                "    String conf = \"\";\n"
                "    try { conf = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(\"/etc/resolv.conf\"))); } catch (Exception f) { }\n"
                "    return (conf.contains(\"nameserver\") ? \"dns \" : \"nodns \") + e.getClass().getSimpleName(); }\n"
                "  try (Socket s = new Socket()) { s.connect(new InetSocketAddress(a, p), 5000); return \"ok \" + a.getHostAddress(); }\n"
                "  catch (Exception e) { return \"tcp \" + a.getHostAddress() + \" \" + e.getClass().getSimpleName(); } } }\n"
                "/" % (PROBE, PROBE))
        except sql.DbError as error:
            if error.kind == "nojava":
                raise Failure("Java is not installed in the database (no usable script language container)",
                              EXIT["nojava"], "nojava")
            raise Failure("the DNS probe could not be created: %s" % error, EXIT["failed"])

    def probe(self, host, port):
        """'ok <ip>' | 'dns ...' | 'tcp <ip> ...', from inside the database's Java."""
        self.ensure_probe()
        rows = self.db().query("SELECT EXAKIT_VS.%s(%s, %d) AS R" % (PROBE, sql.literal(host), int(port)))
        return (rows[0].get("R") if rows else "") or ""

    def require_route(self, connector, values, name):
        host = planner.source_host(connector, values)
        if not host:
            return
        port = int(values.get("port") or 443)
        answer = self.probe(host, port)
        if answer.startswith("nodns"):
            # The language container has no resolver at all (Exasol Personal's
            # empty /etc/resolv.conf): repairable, so the shell repairs and retries.
            raise Failure("Java in the database has no DNS resolver, so it cannot resolve %s" % host, EXIT["dns"], "dns")
        if answer.startswith("dns"):
            raise Failure("the host name %s does not resolve (check the spelling)" % host, EXIT["failed"], "unreachable")
        if answer.startswith("tcp"):
            raise Failure("%s:%d is not reachable from inside the database (%s)" % (host, port, answer[4:]),
                          EXIT["failed"], "unreachable")
        self.emit("OK", "%s resolves and answers on port %d from inside the database (%s)" % (host, port, answer[3:]))

    # --- artifacts ------------------------------------------------------------------
    def stage(self, connector, name, created):
        """Fetch, verify and stage the adapter and driver; record this source as their consumer."""
        if not self.runtime.available():
            raise Failure("the deployment's runtime directory is missing (%s)" % self.runtime.exa, EXIT["failed"])
        cid = connector["id"]
        adapter_pin, driver_pin = connector["adapter"], connector["driver"]
        jars = []
        adapter_src = self.cache.fetch(adapter_pin)
        dest = self.runtime.bucket_dir(cid, adapter_pin["version"], adapter_pin["asset"])
        made = artifacts.stage_file(adapter_src, dest)
        self.store.add_consumer(dest, adapter_pin["sha256"], name, made)
        if made:
            created["files"].append(dest)
        jars.append(self.runtime.bucket_sql(cid, adapter_pin["version"], adapter_pin["asset"]))
        driver_src = self.cache.fetch(driver_pin)
        if driver_pin.get("bundle") == "zip":
            bundle_dir = self.runtime.bucket_dir(cid, "driver-" + driver_pin["version"])
            for jar in artifacts.stage_zip(driver_src, bundle_dir):
                jars.append(self.runtime.bucket_sql(cid, "driver-" + driver_pin["version"], jar))
                self.store.add_consumer(os.path.join(bundle_dir, jar), driver_pin["sha256"], name, True)
                created["files"].append(os.path.join(bundle_dir, jar))
        else:
            dest = self.runtime.bucket_dir(cid, "driver-" + driver_pin["version"], driver_pin["asset"])
            made = artifacts.stage_file(driver_src, dest)
            self.store.add_consumer(dest, driver_pin["sha256"], name, made)
            if made:
                created["files"].append(dest)
            jars.append(self.runtime.bucket_sql(cid, "driver-" + driver_pin["version"], driver_pin["asset"]))
        self.emit("OK", "Adapter %s and driver %s verified and staged" % (adapter_pin["version"], driver_pin["version"]))
        etl = connector.get("etl")
        if etl:
            loader = self.runtime.loader_dir(etl["drivername"])
            settings = artifacts.settings_cfg(etl, driver_pin["asset"])
            cfg = os.path.join(loader, "settings.cfg")
            if os.path.isfile(cfg):
                with open(cfg, encoding="utf-8") as handle:
                    current = handle.read()
                if current != settings and not self.store.consumers(cfg):
                    raise Failure("a loader driver %s is already registered and was not set up by the kit; it was "
                                  "left unchanged" % etl["drivername"], EXIT["conflict"])
            made_jar = artifacts.stage_file(driver_src, os.path.join(loader, driver_pin["asset"]))
            os.makedirs(loader, exist_ok=True)
            made_cfg = not os.path.isfile(cfg)
            with open(cfg, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(settings)
            self.store.add_consumer(os.path.join(loader, driver_pin["asset"]), driver_pin["sha256"], name, made_jar)
            self.store.add_consumer(cfg, "settings", name, made_cfg)
            if made_jar:
                created["files"].append(os.path.join(loader, driver_pin["asset"]))
            if made_cfg:
                created["files"].append(cfg)
            self.emit("OK", "Loader driver %s registered for IMPORT FROM JDBC" % etl["drivername"])
        return jars

    # --- SQL ------------------------------------------------------------------------
    def create_connection(self, names, url, user, secret, replace=False):
        verb = "CREATE OR REPLACE CONNECTION" if replace else "CREATE CONNECTION"
        statement = "%s %s TO %s" % (verb, sql.ident(names["connection"]), sql.literal(url))
        if user is not None:
            statement += " USER %s IDENTIFIED BY %s" % (sql.literal(user), sql.literal(secret))
        self.db().execute(statement, secrets=[secret])

    def adapter_sql(self, names, jars):
        lines = ["CREATE OR REPLACE JAVA ADAPTER SCRIPT %s.%s AS"
                 % (sql.ident(names["script_schema"]), sql.ident(names["script"])),
                 "  %%scriptclass %s;" % self.profile["adapter_script"]["scriptclass"]]
        lines += ["  %%env %s;" % env for env in self.profile["adapter_script"].get("env", [])]
        lines += ["  %%jar %s;" % jar for jar in jars]
        return "\n".join(lines) + "\n/"

    def vs_sql(self, connector, names, values):
        props = ["CONNECTION_NAME = %s" % sql.literal(names["connection"])]
        for key, template in connector["vs_properties"].items():
            props.append("%s = %s" % (key, sql.literal(template.format(**values))))
        return "CREATE VIRTUAL SCHEMA %s USING %s.%s WITH %s" % (
            sql.ident(names["schema"]), sql.ident(names["script_schema"]), sql.ident(names["script"]),
            " ".join(props))

    def tables(self, schema):
        return [r.get("TABLE_NAME") for r in self.db().query(
            "SELECT TABLE_NAME FROM EXA_DBA_VIRTUAL_TABLES WHERE TABLE_SCHEMA = %s ORDER BY TABLE_NAME"
            % sql.literal(schema))]

    def bounded_read(self, schema, tables):
        """One row through the adapter and the loader; the rows are never printed."""
        if not tables:
            return False
        self.db().query("SELECT * FROM %s.%s LIMIT 1" % (sql.ident(schema), sql.ident(tables[0])))
        return True

    # --- operations -----------------------------------------------------------------
    def connect(self, connector_id, name, given, secret, dry_run=False, plan_only=False):
        if not sources.NAME.match(name or ""):
            raise Failure("the source name must be lower case letters, digits and _ (start with a letter, at most 40), "
                          "e.g. sales", EXIT["input"])
        connector = self.defs.connector(connector_id)
        entry = self.defs.entry(connector_id)
        values = planner.validate_inputs(connector, given)
        names = planner.objects(name)
        description = planner.describe(self.defs, connector_id, name, values, self.runtime, self.cache, self.store)
        if plan_only or dry_run:
            return description
        if entry["status"] == "gated":
            raise Failure("%s is not available yet: %s" % (entry["name"], entry["gate"]), EXIT["gated"])
        reconnect = False
        if self.store.exists(name):
            current = self.store.config(name)
            if self.store.status(name).get("status") != "disconnected" or current["connector"] != connector_id:
                raise Failure("a source named %s already exists (%s); choose another name or remove it first: "
                              "exakit source remove %s" % (name, current["connector"], name), EXIT["conflict"])
            reconnect = True
        spec = planner.secret_input(connector)
        if spec and not secret:
            raise Failure("%s needs %s on standard input (it is never taken as an argument)"
                          % (connector_id, spec["label"].lower()), EXIT["input"])
        created = {"files": [], "connection": False, "script": False, "schema": False}
        with self.store.lock():
            self.store.save_journal(name, {"operation": "reconnect" if reconnect else "connect",
                                           "connector": connector_id, "started": sources.now(), "steps": []})
            try:
                if not reconnect:
                    for kind, label in (("connection", names["connection"]), ("schema", names["schema"])):
                        if self.exists(kind, label):
                            raise Failure("%s %s already exists in the database and is not a source the kit set up; "
                                          "it was left unchanged" % (kind, label), EXIT["conflict"])
                self.require_route(connector, values, name)
                jars = self.stage(connector, name, created)
                url = planner.jdbc_url(connector, values)
                self.create_connection(names, url, values.get("user"), secret, replace=reconnect)
                created["connection"] = not reconnect
                self.emit("OK", "Connection %s created (the credential lives only in the database)" % names["connection"])
                if not reconnect:
                    self.db().execute(self.adapter_sql(names, jars))
                    created["script"] = True
                    self.db().execute(self.vs_sql(connector, names, values))
                    created["schema"] = True
                tables = self.tables(names["schema"])
                read = self.bounded_read(names["schema"], tables)
                if read:
                    self.emit("OK", "Virtual schema %s: %d table(s); a bounded read succeeded" % (names["schema"], len(tables)))
                else:
                    self.emit("WARN", "Virtual schema %s connected, but the source shows no tables for this scope"
                              % names["schema"])
            except (Failure, sql.DbError, artifacts.ArtifactError, OSError) as error:
                self.undo(names, created, name)
                self.store.clear_journal(name)
                if reconnect:
                    self.store.update_status(name, status="disconnected")
                else:
                    # A first attempt leaves no record at all - not even the
                    # empty folder its journal lived in.
                    self.store.delete_source(name)
                    self.drop_kit_schema_if_unused()
                kind = getattr(error, "kind", "error")
                code = getattr(error, "code", EXIT["failed"])
                if isinstance(error, sql.DbError):
                    code = EXIT["dns"] if kind == "dns" else EXIT["nojava"] if kind == "nojava" else EXIT["failed"]
                # A first connect has no source record yet, so the lifecycle
                # commands do not apply: nothing was left behind, and the fix is
                # the same command with corrected input.
                remedy = REMEDY_FOR.get(kind, REMEDY_FOR["error"]).format(name=name)
                if not reconnect and kind in ("auth", "tls", "unreachable"):
                    remedy = {"auth": "the source rejected the credentials; nothing was kept - correct them and run the same exakit connect again",
                              "tls": "the source's certificate or host name did not verify; nothing was kept - fix the server certificate or choose tls=require knowingly, then connect again",
                              "unreachable": "the source did not answer from inside the database; nothing was kept - check host, port, firewall and VPN (a source on this computer must listen beyond 127.0.0.1), then connect again"}[kind]
                raise Failure("%s (%s)" % (error, remedy), code, kind)
            pins = {"adapter": connector["adapter"]["sha256"], "driver": connector["driver"]["sha256"],
                    "adapter_version": connector["adapter"]["version"], "driver_version": connector["driver"]["version"]}
            self.store.save_config(name, {"schema_version": 1, "id": name, "connector": connector_id,
                                          "profile": connector["profile"], "inputs": values, "objects": names,
                                          "created_at": self.store.config(name).get("created_at") if reconnect else sources.now()})
            self.store.save_status(name, {"status": "ready", "pins": pins, "tables": len(tables),
                                          "last_check": {"at": sources.now(), "outcome": "ok",
                                                         "evidence": "metadata and a bounded read" if read else "metadata"}})
            self.store.clear_journal(name)
        return {"name": name, "connector": connector_id, "objects": names, "tables": len(tables), "status": "ready"}

    def undo(self, names, created, name):
        """Compensate exactly what this attempt created, newest first."""
        db = self._db
        if db is not None:
            for flag, statement in (("schema", "DROP FORCE VIRTUAL SCHEMA %s CASCADE" % sql.ident(names["schema"])),
                                    ("script", "DROP ADAPTER SCRIPT %s.%s" % (sql.ident(names["script_schema"]),
                                                                               sql.ident(names["script"]))),
                                    ("connection", "DROP CONNECTION %s" % sql.ident(names["connection"]))):
                if created.get(flag):
                    try:
                        db.execute(statement)
                    except sql.DbError as error:
                        self.emit("WARN", "could not undo %s: %s" % (flag, error))
        if not self.store.exists(name):
            for path in self.store.release(name):
                if path in created["files"] and os.path.isfile(path):
                    os.remove(path)
                    self.prune(os.path.dirname(path))

    def record_check(self, name, outcome, evidence, kind=None):
        status = "ready" if outcome == "ok" else STATUS_FOR.get(kind or "error", "failed")
        self.store.update_status(name, status=status, last_check={"at": sources.now(), "outcome": outcome,
                                                                  "kind": kind, "evidence": evidence})
        return status

    def check(self, name):
        config = self.store.config(name)
        if self.store.status(name).get("status") == "disconnected":
            return {"name": name, "status": "disconnected", "skipped": True}
        connector = self.defs.connector(config["connector"])
        names = config["objects"]
        try:
            self.require_route(connector, config["inputs"], name)
            tables = self.tables(names["schema"])
            read = self.bounded_read(names["schema"], tables)
        except (Failure, sql.DbError) as error:
            kind = getattr(error, "kind", "error")
            status = self.record_check(name, "failed", str(error), kind)
            return {"name": name, "status": status, "kind": kind, "error": str(error),
                    "remedy": REMEDY_FOR.get(kind, REMEDY_FOR["error"]).format(name=name)}
        evidence = "metadata and a bounded read (%d tables)" % len(tables) if read else "metadata only (no tables in scope)"
        self.record_check(name, "ok", evidence)
        return {"name": name, "status": "ready", "evidence": evidence}

    def reauth(self, name, secret):
        config = self.store.config(name)
        if self.store.status(name).get("status") == "disconnected":
            raise Failure("%s is disconnected; reconnect it with: exakit connect %s --name %s"
                          % (name, config["connector"], name), EXIT["conflict"])
        if not secret:
            raise Failure("reauth needs the new credential on standard input", EXIT["input"])
        connector = self.defs.connector(config["connector"])
        url = planner.jdbc_url(connector, config["inputs"])
        with self.store.lock():
            try:
                self.create_connection(config["objects"], url, config["inputs"].get("user"), secret, replace=True)
            except sql.DbError as error:
                raise Failure("the credential could not be replaced: %s" % error, EXIT["failed"])
        self.emit("OK", "Credential replaced in %s" % config["objects"]["connection"])
        return self.check(name)

    def refresh(self, name):
        config = self.store.config(name)
        schema = config["objects"]["schema"]
        try:
            self.db().execute("ALTER VIRTUAL SCHEMA %s REFRESH" % sql.ident(schema))
        except sql.DbError as error:
            raise Failure("the metadata refresh failed: %s" % error, EXIT["failed"], error.kind)
        count = len(self.tables(schema))
        self.store.update_status(name, tables=count, refreshed_at=sources.now())
        return {"name": name, "tables": count}

    def disconnect(self, name, dry_run=False):
        config = self.store.config(name)
        connection = config["objects"]["connection"]
        plan = {"name": name, "drop": ["CONNECTION %s" % connection],
                "keep": ["virtual schema %s" % config["objects"]["schema"], "adapter script", "staged files",
                         "the source record (marked disconnected)"],
                "note": "queries on %s fail until it is reconnected; sessions already running are not cancelled, "
                        "and nothing is revoked at the source" % config["objects"]["schema"]}
        if dry_run:
            return plan
        with self.store.lock():
            if self.exists("connection", connection):
                self.db().execute("DROP CONNECTION %s" % sql.ident(connection))
            self.store.update_status(name, status="disconnected", disconnected_at=sources.now())
        return plan

    def remove(self, name, dry_run=False):
        config = self.store.config(name)
        names = config["objects"]
        registry = self.store.registry().get("artifacts", {})
        mine = [path for path, entry in registry.items() if name in entry.get("consumers", [])]
        reclaim = [path for path in mine if registry[path].get("owned") and registry[path].get("consumers") == [name]]
        plan = {"name": name, "drop": ["virtual schema %s" % names["schema"],
                                       "adapter script %s.%s" % (names["script_schema"], names["script"]),
                                       "CONNECTION %s" % names["connection"]],
                "delete_files": reclaim, "keep_files": [p for p in mine if p not in reclaim],
                "note": "remote data and source accounts are never touched"}
        if dry_run:
            return plan
        with self.store.lock():
            db = self.db()
            connection_present = self.exists("connection", names["connection"])
            if self.exists("schema", names["schema"]):
                # With the CONNECTION gone the adapter cannot be called back to
                # clean up, so the drop skips that callback (FORCE) - for this
                # kit-owned schema only.
                force = "" if connection_present else "FORCE "
                db.execute("DROP %sVIRTUAL SCHEMA %s CASCADE" % (force, sql.ident(names["schema"])))
            if self.exists("script", names["script_schema"], names["script"]):
                db.execute("DROP ADAPTER SCRIPT %s.%s" % (sql.ident(names["script_schema"]), sql.ident(names["script"])))
            if connection_present:
                db.execute("DROP CONNECTION %s" % sql.ident(names["connection"]))
            for path in self.store.release(name):
                if os.path.isfile(path):
                    os.remove(path)
                    self.prune(os.path.dirname(path))
            self.store.delete_source(name)
            self.drop_kit_schema_if_unused()
        return plan

    def drop_kit_schema_if_unused(self):
        """EXAKIT_VS (the adapters and the DNS probe) goes with the last source."""
        if self.store.names() or self._db is None:
            return
        try:
            if self.exists("schema", "EXAKIT_VS"):
                self._db.execute("DROP SCHEMA EXAKIT_VS CASCADE")
        except sql.DbError as error:
            self.emit("WARN", "could not drop the unused EXAKIT_VS schema: %s" % error)
        # The kit's own empty folders go too - exakit/vs and exakit, never the
        # bucket above them (on Personal a bucket directory IS the bucket).
        for folder in (self.runtime.bucket_dir(), os.path.dirname(self.runtime.bucket_dir())):
            try:
                os.rmdir(folder)
            except OSError:
                break

    def prune(self, folder):
        """Remove empty folders the kit made, up to - never including - its roots.

        The roots are the kit's own bucket folder (exakit/vs) and the loader's
        jdbc folder. Climbing past them would remove an empty bucket
        directory, and on Exasol Personal a bucket directory IS the bucket.
        """
        stops = {os.path.normpath(self.runtime.bucket_dir()), os.path.normpath(os.path.join(self.runtime.exa, "jdbc"))}
        folder = os.path.normpath(folder)
        while folder not in stops and any(folder.startswith(stop + os.sep) for stop in stops):
            try:
                os.rmdir(folder)
            except OSError:
                return
            folder = os.path.dirname(folder)

    def listing(self):
        rows = []
        for name in self.store.names():
            config = self.store.config(name)
            status = self.store.status(name)
            rows.append({"name": name, "connector": config["connector"], "schema": config["objects"]["schema"],
                         "status": status.get("status", "unknown"), "last_check": status.get("last_check")})
        return rows

    def show(self, name):
        config = self.store.config(name)
        status = self.store.status(name)
        return {"name": name, "connector": config["connector"], "inputs": config["inputs"],
                "objects": config["objects"], "status": status.get("status", "unknown"),
                "pins": status.get("pins"), "tables": status.get("tables"), "last_check": status.get("last_check"),
                "journal": self.store.journal(name)}

    def issues(self, status_filter=None):
        rows = []
        for row in self.listing():
            if row["status"] in ("ready", "disconnected"):
                continue
            if status_filter and row["status"] != status_filter:
                continue
            check = row.get("last_check") or {}
            rows.append(dict(row, remedy=REMEDY_FOR.get(check.get("kind") or "error", REMEDY_FOR["error"]).format(name=row["name"])))
        return rows
