"""The virtual schema coordinator, called by setup/lib/virtual-schemas.{sh,ps1}.

    cli.py [context] catalog    [--query Q]
    cli.py [context] resolve    QUERY
    cli.py [context] plan       CONNECTOR --name N [--set KEY=VALUE ...]
    cli.py [context] connect    CONNECTOR --name N [--set KEY=VALUE ...] [--secret-stdin]
    cli.py [context] list | issues [--status S] | show N | check N|--all
    cli.py [context] reauth     N --secret-stdin
    cli.py [context] refresh    N
    cli.py [context] disconnect N [--dry-run]
    cli.py [context] remove     N [--dry-run]

    context: --defs DIR --kit-home DIR --deployment-dir DIR --dsn HOST:PORT
             --user USER --password-file FILE [--json]

A secret is read from standard input only (--secret-stdin), never from an
argument: arguments are visible to every local user through the process table.

Without --json, one "OK|INFO|WARN|FAIL <text>" line per event on stdout for
the shell to render. With --json, events go to stderr and stdout carries one
JSON object. Exit codes: 0 done, 1 failed, 2 bad input, 3 conflict, 4 no such
source, 5 gated, 20 Java in the database cannot resolve host names,
21 Java is not installed in the database, 22 the local database is unreachable.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lifecycle  # noqa: E402
import plan as planner  # noqa: E402
import sources  # noqa: E402


def parse(argv):
    parser = argparse.ArgumentParser(prog="cli.py")
    parser.add_argument("--defs", required=True)
    parser.add_argument("--kit-home", required=True)
    parser.add_argument("--deployment-dir", default="")
    parser.add_argument("--dsn", default="")
    parser.add_argument("--user", default="sys")
    parser.add_argument("--password-file", default="")
    parser.add_argument("--json", action="store_true")
    sub = parser.add_subparsers(dest="command")
    cmd = sub.add_parser("catalog")
    cmd.add_argument("--query", default="")
    sub.add_parser("resolve").add_argument("query")
    for name in ("plan", "connect"):
        cmd = sub.add_parser(name)
        cmd.add_argument("connector")
        cmd.add_argument("--name", required=True)
        cmd.add_argument("--set", action="append", default=[], metavar="KEY=VALUE")
        cmd.add_argument("--secret-stdin", action="store_true")
        cmd.add_argument("--dry-run", action="store_true")
    sub.add_parser("list")
    sub.add_parser("issues").add_argument("--status", default="")
    sub.add_parser("show").add_argument("name")
    cmd = sub.add_parser("check")
    cmd.add_argument("name", nargs="?")
    cmd.add_argument("--all", action="store_true")
    cmd = sub.add_parser("reauth")
    cmd.add_argument("name")
    cmd.add_argument("--secret-stdin", action="store_true")
    sub.add_parser("refresh").add_argument("name")
    for name in ("disconnect", "remove"):
        cmd = sub.add_parser(name)
        cmd.add_argument("name")
        cmd.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def pairs(items):
    values = {}
    for item in items:
        if "=" not in item:
            raise planner.PlanError("--set takes KEY=VALUE, not %r" % item)
        key, value = item.split("=", 1)
        values[key.strip()] = value
    return values


def read_secret(enabled):
    if not enabled:
        return None
    data = sys.stdin.read()
    return data.rstrip("\r\n") or None


def main(argv=None):
    args = parse(argv)
    out = sys.stderr if args.json else sys.stdout

    def emit(level, text):
        out.write("%s %s\n" % (level, text))
        out.flush()

    if not args.command:
        emit("FAIL", "name a command (see the module docstring)")
        return lifecycle.EXIT["input"]
    result, code = None, 0
    engine = None
    try:
        if args.command in ("catalog", "resolve"):
            defs = planner.Definitions(args.defs)
            if args.command == "resolve":
                # The gate comes before any question: asking for a project and
                # a dataset only to then say "not available" wastes the answers.
                connector = defs.resolve(args.query)
                entry = defs.entry(connector)
                if entry["status"] == "gated":
                    raise planner.PlanError("%s is not available yet: %s" % (entry["name"], entry["gate"]),
                                            code=lifecycle.EXIT["gated"])
                result = {"connector": connector}
            else:
                q = args.query.lower()
                result = {"connectors": [dict(e, profile=e["profile"]) for e in defs.entries()
                                         if not q or q in json.dumps(e).lower()]}
        else:
            engine = lifecycle.Engine(args, emit)
            if args.command in ("plan", "connect"):
                connector = engine.defs.resolve(args.connector)
                result = engine.connect(connector, args.name, pairs(args.set), read_secret(args.secret_stdin),
                                        dry_run=args.dry_run, plan_only=args.command == "plan")
            elif args.command == "list":
                result = {"sources": engine.listing()}
            elif args.command == "issues":
                result = {"issues": engine.issues(args.status or None)}
            elif args.command == "show":
                result = engine.show(args.name)
            elif args.command == "check":
                if args.all:
                    results = [engine.check(name) for name in engine.store.names()]
                    result = {"checks": results}
                    code = 1 if any(r.get("status") not in ("ready", "disconnected") for r in results) else 0
                elif args.name:
                    result = engine.check(args.name)
                    code = 0 if result.get("status") in ("ready", "disconnected") else 1
                else:
                    raise planner.PlanError("check takes a source name or --all")
            elif args.command == "reauth":
                result = engine.reauth(args.name, read_secret(args.secret_stdin))
                code = 0 if result.get("status") == "ready" else 1
            elif args.command == "refresh":
                result = engine.refresh(args.name)
            elif args.command == "disconnect":
                result = engine.disconnect(args.name, args.dry_run)
            elif args.command == "remove":
                result = engine.remove(args.name, args.dry_run)
    except planner.PlanError as error:
        emit("FAIL", str(error))
        if error.choices:
            emit("INFO", "choices: %s" % ", ".join(error.choices))
        result, code = {"ok": False, "error": str(error), "choices": error.choices}, error.code
    except lifecycle.Failure as error:
        emit("FAIL", str(error))
        result, code = {"ok": False, "error": str(error), "kind": error.kind}, error.code
    except sources.SourceError as error:
        emit("FAIL", str(error))
        result, code = {"ok": False, "error": str(error)}, error.code
    finally:
        if engine is not None:
            engine.close()
    if args.json:
        payload = dict(result or {})
        payload.setdefault("ok", code == 0)
        print(json.dumps(payload, indent=2, default=str))
    elif result is not None and code == 0:
        print("RESULT " + json.dumps(result, default=str))
    return code


if __name__ == "__main__":
    sys.exit(main())
