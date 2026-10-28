"""A simulated Exasol for the virtual schema engine (EXAKIT_VS_FAKE_DB).

State lives in the JSON file named by FAKE_VS_STATE, so a test can arrange a
database and inspect it afterwards:

    java        false -> creating a JAVA script fails like a deployment with no
                container ("No usable script language container ...")
    dns         false -> the DNS probe answers "nodns ..." (no resolver at all);
                a host ending in .invalid answers "dns ..." (no such name)
    unreachable host names whose TCP probe fails
    clock_skew  seconds the database clock is off this computer's (negative: behind)
    sources     {host: {"tables": [...], "fail": null|"auth"|"tls"|"tls-validity"|"unreachable"|"denied",
                        "secret": "<the credential the source accepts>"}}
                a document source (S3) is keyed by <bucket>.s3.<region>.amazonaws.com
                and also takes "region" (the bucket's real one) and "empty"
                (tables whose objects match nothing); its tables come from the
                mapping staged under FAKE_VS_EXA, as the adapter reads them
    connections {NAME: {"url", "user", "secret"}}    what the engine created
    schemas, scripts, virtual {VS: {"connection", "tables"}}
    statements  every statement, secrets included, so a test can prove where
                they went (into CONNECTION DDL) and where they did not

Errors carry realistic driver text, including the statement for a failed
CREATE CONNECTION, so the engine's redaction is exercised for real.
"""

import json
import os
import re


def _load():
    with open(os.environ["FAKE_VS_STATE"]) as handle:
        doc = json.load(handle)
    for key, default in (("java", True), ("dns", True), ("unreachable", []), ("sources", {}),
                         ("connections", {}), ("schemas", []), ("scripts", []), ("virtual", {}),
                         ("statements", [])):
        doc.setdefault(key, default)
    return doc


def _save(doc):
    with open(os.environ["FAKE_VS_STATE"], "w") as handle:
        json.dump(doc, handle, indent=1)


def _host(url):
    m = re.search(r"//(?:tcps://)?([^:/;?]+)", url.replace("@tcps://", "//").replace("@//", "//"))
    return m.group(1) if m else ""


def _s3_error(text):
    # The shape measured on Exasol Personal: the UDF wrapper, then the SDK's exception.
    return Exception("VM error: F-UDF-CL-LIB-1126: F-UDF-CL-SL-JAVA-1006: F-UDF-CL-SL-JAVA-1026:\n"
                     "com.exasol.ExaUDFException: F-UDF-CL-SL-JAVA-1068: Exception during singleCall adapterCall\n"
                     "software.amazon.awssdk.services.s3.model.%s (SDK Attempt Count: 1)\n"
                     "\tsoftware.amazon.awssdk.services.s3.model.S3Exception$BuilderImpl.build(S3Exception.java:113)" % text)


def _document_source(doc, con):
    cred = json.loads(con["secret"])
    host = "%s.s3.%s.amazonaws.com" % (cred["s3Bucket"], cred["awsRegion"])
    src = doc["sources"].get(host)
    if src is None:
        # The bucket answers from its own region: any other region's endpoint redirects.
        for other, candidate in doc["sources"].items():
            if other.startswith(cred["s3Bucket"] + ".s3."):
                raise _s3_error("S3Exception: The bucket you are attempting to access must be addressed using the "
                                "specified endpoint. Please send all future requests to this endpoint. (Service: S3, "
                                "Status Code: 301, Request ID: R1)")
        raise _s3_error("NoSuchBucketException: The specified bucket does not exist (Service: S3, Status Code: 404, "
                        "Request ID: R2)")
    if src.get("fail") == "auth" or (src.get("secret") is not None and cred["awsSecretAccessKey"] != src["secret"]):
        raise _s3_error("S3Exception: The request signature we calculated does not match the signature you provided. "
                        "Check your key and signing method. (Service: S3, Status Code: 403, Request ID: R3)")
    if src.get("fail") == "denied":
        raise _s3_error("AccessDeniedException: User: arn:aws:iam::1:user/reader is not authorized to perform: "
                        "s3:ListBucket on resource: \"arn:aws:s3:::%s\" (Service: S3, Status Code: 403, Request ID: R4)"
                        % cred["s3Bucket"])
    return src


def _mapping_tables(path):
    folder = os.path.join(os.environ["FAKE_VS_EXA"], "bucketfs", *path.strip("/").split("/"))
    return sorted(json.load(open(os.path.join(folder, n)))["destinationTable"].upper()
                  for n in os.listdir(folder) if n.endswith(".json"))


def _source_for(doc, connection):
    con = doc["connections"].get(connection)
    if not con:
        raise Exception("connection %s not found" % connection)
    if con["url"] == "" and con["secret"].startswith("{"):
        return _document_source(doc, con)
    src = doc["sources"].get(_host(con["url"]))
    if src is None:
        raise Exception("JDBC-Client-Error: The connection attempt failed.")
    fail = src.get("fail")
    if fail == "auth" or (src.get("secret") is not None and con.get("secret") != src["secret"]):
        raise Exception('FATAL: password authentication failed for user "%s"' % con["user"])
    if fail == "tls":
        raise Exception("PKIX path building failed: unable to find valid certification path")
    if fail == "tls-validity":
        # A certificate outside its dates by the database's clock (measured on RDS).
        raise Exception("SSLHandshakeException: PKIX path validation failed: "
                        "java.security.cert.CertPathValidatorException: validity check failed")
    if fail == "unreachable":
        raise Exception("Connection refused. Check that the hostname and port are correct")
    return src


class Fake(object):
    def query(self, sql):
        doc = _load()
        doc["statements"].append(sql)
        try:
            return self._query(doc, sql)
        finally:
            _save(doc)

    def execute(self, sql):
        doc = _load()
        doc["statements"].append(sql)
        try:
            self._execute(doc, sql)
        finally:
            _save(doc)

    def close(self):
        pass

    def _query(self, doc, sql):
        m = re.search(r"FROM EXA_DBA_CONNECTIONS WHERE CONNECTION_NAME = '([^']+)'", sql)
        if m:
            return [{"CONNECTION_NAME": m.group(1)}] if m.group(1) in doc["connections"] else []
        m = re.search(r"FROM EXA_SCHEMAS WHERE SCHEMA_NAME = '([^']+)'", sql)
        if m:
            return [{"SCHEMA_NAME": m.group(1)}] if m.group(1) in doc["schemas"] + list(doc["virtual"]) else []
        m = re.search(r"SCRIPT_SCHEMA = '([^']+)' AND SCRIPT_NAME = '([^']+)'", sql)
        if m:
            return [{"SCRIPT_NAME": m.group(2)}] if "%s.%s" % m.groups() in doc["scripts"] else []
        m = re.search(r"EXAKIT_DNS_PROBE_V2\('([^']*)', (\d+)\)", sql)
        if m:
            if "EXAKIT_VS.EXAKIT_DNS_PROBE_V2" not in doc["scripts"]:
                raise Exception("function EXAKIT_VS.EXAKIT_DNS_PROBE_V2 not found")
            if not doc["dns"]:
                return [{"R": "nodns UnknownHostException"}]
            if m.group(1).endswith(".invalid"):
                return [{"R": "dns UnknownHostException"}]
            if m.group(1) in doc["unreachable"]:
                return [{"R": "tcp 10.0.0.9 SocketTimeoutException"}]
            return [{"R": "ok 10.0.0.9"}]
        if sql == "SELECT POSIX_TIME() AS T":
            # The database clock: this computer's, shifted by clock_skew seconds.
            import time
            return [{"T": "%.3f" % (time.time() + doc.get("clock_skew", 0))}]
        if sql.startswith("SELECT EXAKIT_VS.EXAKIT_TLS_BUILD("):
            # The kit's TLS helper, compiled by the database's Java: a stand-in
            # class, or the compiler's absence (tls_compiler false).
            if "EXAKIT_VS.EXAKIT_TLS_BUILD" not in doc["scripts"]:
                raise Exception("function EXAKIT_VS.EXAKIT_TLS_BUILD not found")
            doc["tls_builds"] = doc.get("tls_builds", 0) + 1
            if doc.get("tls_compiler") is False:
                return [{"NAME": "ERROR", "B64": "no Java compiler in the database's Java container"}]
            import base64
            return [{"NAME": "exakit/tls/PemTrustManager.class", "B64": base64.b64encode(b"\xca\xfe\xba\xbe-stand-in").decode()}]
        m = re.search(r"FROM EXA_DBA_VIRTUAL_TABLES WHERE TABLE_SCHEMA = '([^']+)'", sql)
        if m:
            vs = doc["virtual"].get(m.group(1))
            return [{"TABLE_NAME": t} for t in (vs["tables"] if vs else [])]
        m = re.match(r"SELECT \* FROM \(IMPORT FROM JDBC AT \"([^\"]+)\" STATEMENT '", sql)
        if m:
            _source_for(doc, m.group(1))
            return [{"1": 1}]
        m = re.match(r'SELECT \* FROM "([^"]+)"\."([^"]+)" LIMIT 1', sql)
        if m:
            vs = doc["virtual"].get(m.group(1))
            if vs is None:
                raise Exception("schema %s not found" % m.group(1))
            src = _source_for(doc, vs["connection"])
            return [] if m.group(2) in src.get("empty", []) else [{"X": 1}]
        raise Exception("fake: unexpected query: %s" % sql[:80])

    def _execute(self, doc, sql):
        if sql == "CREATE SCHEMA EXAKIT_VS":
            doc["schemas"].append("EXAKIT_VS")
            return
        m = re.match(r"CREATE OR REPLACE JAVA (SCALAR|ADAPTER|SET) SCRIPT (?:\"?)([\w]+)(?:\"?)\.(?:\"?)([\w]+)", sql)
        if m:
            if not doc["java"]:
                raise Exception("No usable script language container is installed for the requested language.")
            name = "%s.%s" % (m.group(2), m.group(3))
            if name not in doc["scripts"]:
                doc["scripts"].append(name)
            return
        m = re.match(r"CREATE (OR REPLACE )?CONNECTION \"([^\"]+)\" TO '((?:[^']|'')*)'(?: USER '((?:[^']|'')*)' IDENTIFIED BY '((?:[^']|'')*)')?$", sql)
        if m:
            if not m.group(1) and m.group(2) in doc["connections"]:
                raise Exception("connection %s already exists (statement: %s)" % (m.group(2), sql))
            doc["connections"][m.group(2)] = {"url": m.group(3), "user": (m.group(4) or "").replace("''", "'"),
                                              "secret": (m.group(5) or "").replace("''", "'")}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* CONNECTION_NAME = \'([^\']+)\' MAPPING = \'([^\']+)\'', sql)
        if m:
            # Measured: with explicit fields the adapter reads no object until a query.
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": _mapping_tables(m.group(3))}
            return
        m = re.match(r'CREATE VIRTUAL SCHEMA "([^"]+)" USING .* CONNECTION_NAME = \'([^\']+)\'', sql)
        if m:
            src = _source_for(doc, m.group(2))
            doc["virtual"][m.group(1)] = {"connection": m.group(2), "tables": list(src.get("tables", []))}
            return
        m = re.match(r'ALTER VIRTUAL SCHEMA "([^"]+)" REFRESH', sql)
        if m:
            vs = doc["virtual"][m.group(1)]
            src = _source_for(doc, vs["connection"])
            if "tables" in src:
                vs["tables"] = list(src["tables"])
            return
        m = re.match(r'DROP (FORCE )?VIRTUAL SCHEMA "([^"]+)"', sql)
        if m:
            vs = doc["virtual"].get(m.group(2))
            if vs and not m.group(1) and vs["connection"] not in doc["connections"]:
                raise Exception("adapter call failed: connection %s not found" % vs["connection"])
            doc["virtual"].pop(m.group(2), None)
            return
        m = re.match(r'DROP ADAPTER SCRIPT "([^"]+)"\."([^"]+)"', sql)
        if m:
            doc["scripts"] = [s for s in doc["scripts"] if s != "%s.%s" % m.groups()]
            return
        m = re.match(r'DROP SCRIPT "([^"]+)"\."([^"]+)"$', sql)
        if m:
            doc["scripts"] = [s for s in doc["scripts"] if s != "%s.%s" % m.groups()]
            return
        if sql == "DROP SCRIPT EXAKIT_VS.EXAKIT_TLS_BUILD":
            doc["scripts"] = [s for s in doc["scripts"] if s != "EXAKIT_VS.EXAKIT_TLS_BUILD"]
            return
        m = re.match(r'DROP CONNECTION (?:IF EXISTS )?"([^"]+)"', sql)
        if m:
            doc["connections"].pop(m.group(1), None)
            return
        if sql == "DROP SCHEMA EXAKIT_VS CASCADE":
            doc["schemas"] = [s for s in doc["schemas"] if s != "EXAKIT_VS"]
            doc["scripts"] = [s for s in doc["scripts"] if not s.startswith("EXAKIT_VS.")]
            return
        raise Exception("fake: unexpected statement: %s" % sql[:80])


def connect(**kwargs):
    return Fake()
