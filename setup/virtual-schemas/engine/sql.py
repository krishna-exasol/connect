"""The database session: pyexasol as the kit's administrator, secrets redacted.

The administrator password is read from the file the manifest names
(runtime.password_file) and never leaves this process. A source credential
arrives on stdin and is written into the database only inside CREATE /
ALTER CONNECTION over the encrypted session; every error raised while it is
in play has it replaced by *** before anything prints or logs it.

Tests swap the backend: EXAKIT_VS_FAKE_DB names a Python file whose
`connect(**kwargs)` returns an object with query/execute/close.
"""

import importlib.util
import os
import re

MAX_ERROR = 600


class DbError(Exception):
    def __init__(self, message, kind="error"):
        super().__init__(message)
        self.kind = kind


# Ordered: the first match names the failure. Messages are the JDBC drivers'
# and Exasol's own; a generic failure stays "error" rather than guessing.
_KINDS = (
    ("nojava", r"No usable script language container"),
    ("dns", r"UnknownHostException|Name or service not known|nodename nor servname|unable to resolve host"),
    ("tls", r"PKIX|certificate|SSLHandshake|SSL connection|ssl_server_dn_match|TLS|SSLException"),
    ("auth", r"password authentication failed|Access denied for user|Login failed for user|ORA-01017|"
             r"Incorrect username or password|invalid username/password|authentication failed|"
             r"JWT token is invalid|Programmatic access token is invalid|token has expired"),
    ("unreachable", r"Connection refused|connect timed out|The connection attempt failed|"
                    r"Communications link failure|No route to host|Network is unreachable|"
                    r"Connection timed out|ORA-12541|ORA-12170|TCP/IP connection to the host"),
)


def classify(message):
    for kind, pattern in _KINDS:
        if re.search(pattern, message or "", re.I):
            return kind
    return "error"


def ident(name):
    """A quoted identifier; the name is already validated, quotes doubled anyway."""
    return '"%s"' % str(name).replace('"', '""')


def literal(value):
    return "'%s'" % str(value).replace("'", "''")


def summarize(text):
    """One readable line out of Exasol's multi-line UDF error wrapper.

    An adapter failure arrives as "VM error: F-UDF-CL-... com.exasol..." with a
    Java stack under it; the line worth reading is the adapter's own coded
    message (E-VSPG-3: ... Caused by: '...'). Anything else keeps its first
    meaningful line.
    """
    text = str(text)
    coded = re.search(r"(E-[A-Z]+-\d+:[^\n]*)", text)
    if coded:
        line = coded.group(1)
    else:
        lines = [l.strip() for l in text.splitlines() if l.strip() and l.strip() not in ("(", ")")]
        line = next((l for l in lines if not l.startswith("message")), lines[0] if lines else text)
    return re.sub(r"\s+", " ", line).strip()


def redact(text, secrets):
    text = summarize(text)
    for secret in secrets:
        if secret:
            for form in (secret, secret.replace("'", "''")):
                text = text.replace(form, "***")
    text = re.sub(r"IDENTIFIED BY\s+'(?:[^']|'')*'", "IDENTIFIED BY '***'", text, flags=re.I)
    text = re.sub(r"\s*\(Session: \d+\)", "", text)
    return text[:MAX_ERROR]


class Database(object):
    def __init__(self, backend, log=None):
        self.backend = backend
        self.log = log or (lambda text: None)

    def query(self, sql_text, secrets=()):
        try:
            return self.backend.query(sql_text)
        except Exception as error:     # the driver's own exception types vary by backend
            message = redact(error, secrets)
            raise DbError(message, classify(message))

    def execute(self, sql_text, secrets=()):
        try:
            self.backend.execute(sql_text)
        except Exception as error:
            message = redact(error, secrets)
            raise DbError(message, classify(message))

    def close(self):
        try:
            self.backend.close()
        except Exception:
            pass


class _Pyexasol(object):
    def __init__(self, dsn, user, password):
        import pyexasol
        import ssl
        try:
            self.conn = pyexasol.connect(dsn=dsn, user=user, password=password, encryption=True,
                                         websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
                                         fetch_dict=True, compression=False, debug=False)
        except Exception:
            # A deployment configured without TLS: the kit's own validation
            # (setup/lib/pyexasol.sh) falls back the same way.
            self.conn = pyexasol.connect(dsn=dsn, user=user, password=password, encryption=False,
                                         fetch_dict=True, debug=False)

    def query(self, sql_text):
        statement = self.conn.execute(sql_text)
        if statement.result_type != "resultSet":
            return []
        return [{str(k).upper(): v for k, v in row.items()} for row in statement.fetchall()]

    def execute(self, sql_text):
        self.conn.execute(sql_text)

    def close(self):
        self.conn.close()


def connect(dsn, user, password_file, log=None):
    fake = os.environ.get("EXAKIT_VS_FAKE_DB")
    if fake:
        spec = importlib.util.spec_from_file_location("exakit_vs_fake_db", fake)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return Database(module.connect(dsn=dsn, user=user), log)
    try:
        with open(password_file, encoding="utf-8") as handle:
            password = handle.read().strip()
    except OSError as error:
        raise DbError("the administrator password file could not be read: %s" % error, "error")
    try:
        backend = _Pyexasol(dsn, user, password)
    except ImportError:
        raise DbError("pyexasol is not installed in this Python (repair: exakit update pyexasol)", "error")
    except Exception as error:
        message = redact(error, [password])
        raise DbError("the database did not accept a connection: %s" % message, "unreachable")
    return Database(backend, log)
