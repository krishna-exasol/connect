"""Profile B (document files): the EDML mapping and the credential JSON.

A document source has no URL and no user: its CONNECTION holds a JSON
credential in IDENTIFIED BY, and its tables come from an EDML mapping - JSON
files the user writes, staged where the adapter reads them. Both are checked
here before anything reaches the database: the mapping for what would make the
virtual schema fail or collide, the credential for its shape, so a typo is
named on this computer instead of as a Java stack from inside the database.
"""

import json
import os
import re

EDML_SCHEMA = re.compile(r"^https://schemas\.exasol\.com/edml-\d+\.\d+\.\d+\.json$")
TABLE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
MAX_FILES = 50
MAX_BYTES = 1 << 20

KEY_ID = re.compile(r"^(AKIA|ASIA)[A-Z0-9]{16}$")


class DocumentError(Exception):
    pass


def mapping_files(path):
    """The mapping's files as [(file name, text)]: one .json file, or every
    .json file directly in a folder (sorted, so the staged copy is stable)."""
    path = os.path.abspath(os.path.expanduser(path))
    if os.path.isdir(path):
        names = sorted(n for n in os.listdir(path) if n.lower().endswith(".json")
                       and os.path.isfile(os.path.join(path, n)))
        if not names:
            raise DocumentError("mapping folder %s holds no .json files" % path)
        files = [os.path.join(path, n) for n in names]
    elif os.path.isfile(path):
        if not path.lower().endswith(".json"):
            raise DocumentError("mapping %s is not a .json file" % path)
        files = [path]
    else:
        raise DocumentError("mapping %s does not exist" % path)
    if len(files) > MAX_FILES:
        raise DocumentError("mapping %s has %d files; at most %d are staged" % (path, len(files), MAX_FILES))
    out = []
    for name in files:
        if os.path.getsize(name) > MAX_BYTES:
            raise DocumentError("mapping file %s is larger than 1 MiB" % name)
        with open(name, encoding="utf-8") as handle:
            out.append((os.path.basename(name), handle.read()))
    return out


def load_mappings(path):
    """[{file, table, source}] for a valid mapping; DocumentError names every problem."""
    try:
        files = mapping_files(path)
    except (OSError, UnicodeDecodeError) as error:
        raise DocumentError("mapping %s cannot be read: %s" % (path, error))
    problems, tables, seen = [], [], {}
    for name, text in files:
        try:
            doc = json.loads(text)
        except ValueError as error:
            problems.append("%s is not valid JSON (%s)" % (name, error))
            continue
        if not isinstance(doc, dict):
            problems.append("%s must hold one EDML object" % name)
            continue
        if not EDML_SCHEMA.match(str(doc.get("$schema", ""))):
            problems.append("%s needs \"$schema\": \"https://schemas.exasol.com/edml-2.1.0.json\"" % name)
        source = doc.get("source")
        if not isinstance(source, str) or not source.strip():
            problems.append("%s needs a \"source\": the object key or glob to read, e.g. data/orders/*.json" % name)
        elif "://" in source:
            problems.append("%s: \"source\" is the key inside the bucket, without s3:// or a host (got %s)"
                            % (name, source))
        table = doc.get("destinationTable")
        if not isinstance(table, str) or not TABLE.match(table):
            problems.append("%s needs a \"destinationTable\" that is a plain SQL name (letters, digits, _)" % name)
        elif table.upper() in seen:
            problems.append("%s and %s both map to table %s" % (seen[table.upper()], name, table.upper()))
        else:
            seen[table.upper()] = name
            tables.append({"file": name, "table": table.upper(), "source": source})
    if problems:
        raise DocumentError("; ".join(problems))
    return tables


def _first(doc, *keys):
    for key in keys:
        if doc.get(key):
            return str(doc[key]).strip()
    return ""


def credential(kind, values, secret):
    """(the CONNECTION's JSON, every string to redact, notes) for a document source."""
    if kind != "s3":
        raise DocumentError("unknown credential kind %s" % kind)
    key_id, secret_key, token = values.get("access_key_id", ""), secret, ""
    try:
        doc = json.loads(secret)
    except ValueError:
        doc = None
    if isinstance(doc, dict):
        # What `aws iam create-access-key` prints (AccessKey: {...}), what
        # `aws sts ...` prints (Credentials: {...}), either unwrapped, or the
        # adapter's own field names.
        inner = doc.get("AccessKey") or doc.get("Credentials") or doc
        file_id = _first(inner, "awsAccessKeyId", "AccessKeyId")
        secret_key = _first(inner, "awsSecretAccessKey", "SecretAccessKey")
        token = _first(inner, "awsSessionToken", "SessionToken")
        if key_id and file_id and key_id != file_id:
            raise DocumentError("access_key_id does not match the key in the credential file; give one of them")
        key_id = key_id or file_id
    hidden = [secret, secret_key, token]
    if not key_id:
        raise DocumentError("no access key ID: give --set access_key_id=AKIA... with the secret key, or a "
                            "credential file that holds both")
    if not KEY_ID.match(key_id):
        raise DocumentError("the access key ID must look like AKIA... or ASIA... (20 characters)")
    if not secret_key or len(secret_key) < 30 or re.search(r"\s", secret_key):
        raise DocumentError("the secret access key is missing or malformed")
    if key_id.startswith("ASIA") and not token:
        raise DocumentError("ASIA... keys are temporary and need their session token: give the whole JSON from "
                            "aws sts (with SessionToken) through --password-file")
    body = {"awsAccessKeyId": key_id, "awsSecretAccessKey": secret_key,
            "awsRegion": values["region"], "s3Bucket": values["bucket"]}
    notes = []
    if token:
        body["awsSessionToken"] = token
        notes.append("temporary credentials expire (usually within hours); when they do, give new ones with: "
                     "exakit source reauth <name> --password-file <file>")
    text = json.dumps(body)
    return text, [h for h in hidden + [text] if h], notes
