"""Definitions, input validation and the plan shown before anything changes.

A connector's definition (connectors/<id>/connector.json) is data: its
inputs, pinned artifacts, loader registration, JDBC URL template, TLS modes
and virtual schema properties. Everything a user types is validated here by
kind before it reaches a template, and the templates only ever see validated
values - nothing a user types is interpolated into SQL unchecked.
"""

import base64
import difflib
import json
import os
import re

import document
import tlsca

KINDS = {
    "host": re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
                       r"|^\d{1,3}(\.\d{1,3}){3}$|^\[?[0-9A-Fa-f:]+\]?$"),
    "name": re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_$.-]{0,127}$"),
    "account": re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"),
    "text": re.compile(r"^[^\x00-\x1f'\"\\]{1,128}$"),
    # No dots: a dotted bucket's virtual-hosted name (a.b.s3.<region>.amazonaws.com)
    # does not match the S3 certificate, and path-style access is not offered.
    "s3-bucket": re.compile(r"^(?!xn--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"),
    "aws-region": re.compile(r"^[a-z]{2}(-gov)?-[a-z]+-\d{1,2}$"),
    "aws-key-id": document.KEY_ID,
    "azure-account": document.AZURE_ACCOUNT,
    "azure-container": document.AZURE_CONTAINER,
}


# Inside the database, loopback is the database's own runtime. Measured on
# Exasol Personal (macOS): a UDF reaches the internet, the Mac as 192.168.64.1
# (its resolver's address) and host.containers.internal - which there is the
# launcher's Linux VM, not the Mac. On Linux Podman it is the host itself.
LOOPBACK = ("localhost", "127.0.0.1", "::1", "0.0.0.0", "localhost.localdomain")
LOOPBACK_ADVICE = ("host=localhost would be the database itself, not this computer. For a source running on this "
                   "computer use the address the database sees it at - on macOS 192.168.64.1, on Linux and WSL "
                   "host.containers.internal - and make the source listen on that interface, not only on 127.0.0.1")


class PlanError(Exception):
    def __init__(self, message, code=2, choices=None):
        super().__init__(message)
        self.code = code
        self.choices = choices or []


class Definitions(object):
    def __init__(self, root):
        self.root = root
        self.catalog = self._load("catalog.json")

    def _load(self, *parts):
        with open(os.path.join(self.root, *parts), encoding="utf-8") as handle:
            return json.load(handle)

    def entries(self):
        return list(self.catalog["connectors"])

    def entry(self, connector_id):
        for item in self.entries():
            if item["id"] == connector_id:
                return item
        raise PlanError("unknown connector %s" % connector_id)

    def connector(self, connector_id):
        return self._load("connectors", connector_id, "connector.json")

    def profile(self, profile_id):
        return self._load("profiles", profile_id, "profile.json")

    def resolve(self, query):
        """A connector id from a name, an id or an alias; ambiguity is refused with the choices."""
        q = re.sub(r"[\s_]+", "-", (query or "").strip().lower())
        if not q:
            raise PlanError("name a source to connect, for example: exakit connect postgresql",
                            choices=[e["id"] for e in self.entries()])
        exact = [e for e in self.entries()
                 if q in [e["id"], e["name"].lower().replace(" ", "-")] + [a.lower() for a in e.get("aliases", [])]]
        if len(exact) == 1:
            return exact[0]["id"]
        partial = [e for e in self.entries()
                   if any(q in key for key in [e["id"], e["name"].lower()] + e.get("aliases", []))]
        if len(partial) == 1:
            return partial[0]["id"]
        if len(partial) > 1:
            raise PlanError("%s matches more than one source" % query, choices=[e["id"] for e in partial])
        keys = {}
        for e in self.entries():
            for key in [e["id"], e["name"].lower()] + e.get("aliases", []):
                keys[key] = e["id"]
        close = difflib.get_close_matches(q, list(keys), n=3, cutoff=0.6)
        raise PlanError("no source matches %s" % query, choices=sorted(set(keys[c] for c in close))
                        or [e["id"] for e in self.entries()])


def objects(name):
    upper = name.upper()
    return {"connection": "EXAKIT_SRC_%s" % upper, "schema": "VS_%s" % upper,
            "script_schema": "EXAKIT_VS", "script": "ADAPTER_%s" % upper}


def validate_inputs(connector, given):
    """Defaults applied, every value checked by kind; secrets are not taken here."""
    values, problems = {}, []
    known = {spec["name"] for spec in connector["inputs"]}
    for key in given:
        if key not in known:
            problems.append("%s is not an input of %s (inputs: %s)" % (key, connector["id"], ", ".join(sorted(known))))
    for spec in connector["inputs"]:
        name, kind = spec["name"], spec["kind"]
        if kind in ("secret", "secret-file"):
            continue
        raw = given.get(name)
        if raw is None or raw == "":
            if "default" in spec:
                raw = spec["default"]
            elif spec.get("required"):
                problems.append("%s is required (%s)" % (name, spec.get("label", name)))
                continue
            else:
                continue
        raw = str(raw).strip()
        if kind == "port":
            if not raw.isdigit() or not 0 < int(raw) < 65536:
                problems.append("%s must be a port number, not %r" % (name, raw))
                continue
        elif kind == "choice":
            if raw not in spec["choices"]:
                problems.append("%s must be one of %s, not %r" % (name, ", ".join(spec["choices"]), raw))
                continue
        elif kind == "ca-file":
            raw = os.path.abspath(os.path.expanduser(raw))
            try:
                tlsca.certificates(raw)
            except tlsca.CaError as error:
                problems.append(str(error))
                continue
        elif kind == "edml":
            raw = os.path.abspath(os.path.expanduser(raw))
            try:
                document.load_mappings(raw)
            except document.DocumentError as error:
                problems.append(str(error))
                continue
        elif kind == "s3-bucket" and "." in raw:
            problems.append("bucket %s has dots: its HTTPS name does not match the S3 certificate, and the kit "
                            "reads only over verified HTTPS" % raw)
            continue
        elif kind in KINDS and not KINDS[kind].match(raw):
            problems.append("%s=%r is not a valid %s" % (name, raw, kind))
            continue
        if kind == "aws-region" and raw.startswith("cn-"):
            problems.append("the China regions use other endpoints, which this connector does not reach")
            continue
        if kind == "host" and raw.strip("[]").lower() in LOOPBACK:
            problems.append(LOOPBACK_ADVICE)
            continue
        if kind == "host":
            # Stored bare; jdbc_url adds the brackets an IPv6 literal needs in
            # a URL, and the route probe resolves the bare form.
            raw = raw.strip("[]")
        values[name] = raw.upper() if spec.get("upper") else raw
    if values.get("ca") and values.get("tls", "verify") != "verify":
        # A CA only means something to a check; with require or disable it
        # would read as protection that is not there.
        problems.append("ca is used to verify the server, so it needs tls=verify (not %s)" % values["tls"])
    if problems:
        raise PlanError("; ".join(problems))
    return values


def secret_input(connector):
    for spec in connector["inputs"]:
        if spec["kind"] in ("secret", "secret-file"):
            return spec
    return None


def source_host(connector, values):
    template = connector.get("host") or "{host}"
    try:
        return template.format(**values)
    except KeyError:
        return ""


def jdbc_url(connector, values, extra=None):
    """The source's JDBC URL. extra["ca_pem"] is the one certificate chosen
    from the `ca` input (tlsca.choose); with it, verify trusts that CA."""
    fields = dict(values)
    if ":" in fields.get("host", ""):
        fields["host"] = "[%s]" % fields["host"]
    fields.update(extra or {})
    if connector.get("tls"):
        if fields.get("ca_pem") and connector.get("tls_ca"):
            if connector.get("ca_encoding") == "base64-bundle":
                # The whole bundle, base64: ojdbc 23 reads a PEM wallet from a
                # data: URI (wallet_location=data:;base64,...), trust-only.
                value = base64.b64encode(fields["ca_pem"].encode("ascii")).decode("ascii")
            else:
                value = tlsca.url_value(fields["ca_pem"])
            fields["tls"] = connector["tls_ca"].format(**dict(fields, ca_pem=value))
        elif fields.get("truststore") and connector.get("tls_truststore"):
            fields["tls"] = connector["tls_truststore"].format(**fields)
        elif fields.get("ca_pem") and connector.get("tls_class"):
            fields["tls"] = connector["tls_class"].format(tls_arg=tlsca.class_arg(values["host"], fields["ca_pem"]))
        else:
            fields["tls"] = connector["tls"][values.get("tls", "verify")].format(**fields)
    return connector["url"].format(**fields)


def tls_warning(connector, values):
    mode = values.get("tls")
    if mode == "require":
        return "TLS encrypts the connection but does NOT check the server's identity"
    if mode == "disable":
        return "TLS is off: credentials and rows cross the network unencrypted"
    return None


def describe(defs, connector_id, name, values, runtime, cache, store):
    """The plan, as data: what is downloaded, staged, created - before any of it happens."""
    connector = defs.connector(connector_id)
    entry = defs.entry(connector_id)
    names = objects(name)
    downloads = []
    for role in ("adapter", "driver"):
        pin = connector.get(role)
        if not pin:
            continue
        downloads.append({"role": role, "asset": pin["asset"], "version": pin["version"], "bytes": pin["size"],
                          "cached": cache.has(pin), "license": pin["license"]})
    steps = ["verify Java and its DNS in the database (resolve %s)" % (source_host(connector, values) or "the source")]
    if connector.get("etl"):
        steps.append("register loader driver %s" % connector["etl"]["drivername"])
    if values.get("ca"):
        count = len(tlsca.certificates(values["ca"]))
        if connector.get("tls_truststore"):
            how = "%d certificate%s, in a truststore for the adapter and the loader" % (count, "" if count == 1 else "s")
        elif connector.get("ca_encoding") == "base64-bundle":
            how = "%d certificate%s, as a wallet inside the connection" % (count, "" if count == 1 else "s")
        elif connector.get("tls_class"):
            how = ("%d certificate%s, checked with the host name by the kit's TLS helper class"
                   % (count, "" if count == 1 else "s"))
        elif count == 1:
            how = "1 certificate"
        else:
            how = ("%d certificates; a verified handshake from this computer picks the one that signs %s"
                   % (count, source_host(connector, values)))
        steps.append("trust the CA in %s for this source only (%s)" % (values["ca"], how))
    if values.get("mapping"):
        tables = document.load_mappings(values["mapping"])
        steps += ["stage the mapping from %s (%d mapped table%s: %s)" % (values["mapping"], len(tables),
                                                                "" if len(tables) == 1 else "s",
                                                                ", ".join(t["table"] for t in tables)),
                  "create CONNECTION %s (the credential as JSON, inside the database only)" % names["connection"],
                  "create adapter script %s.%s and its import script %s.%s"
                  % (names["script_schema"], names["script"], names["script_schema"], connector["import_script"]),
                  "create virtual schema %s" % names["schema"],
                  "verify every table with a bounded read"]
    else:
        steps += ["create CONNECTION %s" % names["connection"],
                  "create adapter script %s.%s" % (names["script_schema"], names["script"]),
                  "create virtual schema %s" % names["schema"],
                  "verify metadata and one bounded read"]
    plan = {
        "connector": connector_id, "name": name, "tier": entry["tier"], "status": entry["status"],
        "objects": names, "downloads": downloads, "steps": steps,
        "download_bytes": sum(d["bytes"] for d in downloads if not d["cached"]),
        "exposure": "the kit's MCP read-only user can read every table of %s (SELECT ANY TABLE)" % names["schema"],
        "restart": False,
        "warnings": [w for w in [tls_warning(connector, values)] if w],
        "gate": entry.get("gate") if entry["status"] == "gated" else None,
    }
    if store.exists(name):
        plan["existing"] = store.status(name).get("status", "unknown")
    return plan
