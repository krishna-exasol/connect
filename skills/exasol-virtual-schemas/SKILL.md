---
name: exasol-virtual-schemas
description: Query an external database - PostgreSQL, MySQL, SQL Server, Oracle or Snowflake - from the local Exasol database through a virtual schema, with exakit connect and exakit source. Covers giving inputs unattended, passing the credential safely (never as an argument), reading the plan, the "localhost inside the database is not this computer" trap, the failure classes and their fixes (auth, TLS, unreachable, no DNS, no Java), reauth after a password change, disconnect versus remove, and why BigQuery is gated. Triggers — "connect my Postgres to Exasol", "query MySQL from Exasol", "virtual schema", "federate a remote database", "exakit connect", "exakit source", "my source password changed", "the virtual schema stopped working", "remove a connected source", "join local tables with a remote database", "connect Snowflake", "connect SQL Server", "connect Oracle".
---

# Virtual schemas — query a remote database from local Exasol

A virtual schema exposes a remote database's tables in the local Exasol
database. The data stays at the source: each query fetches what it needs, so
it can join remote tables with local ones. The kit sets the connection up; the
database runs every query, even after `exakit` exits.

| Source | Connector id (aliases) | Status |
|---|---|---|
| PostgreSQL | `postgresql` (`pg`, `postgres`) | candidate |
| MySQL | `mysql` | candidate |
| SQL Server | `sqlserver` (`mssql`) | candidate |
| Oracle | `oracle` (`ora`) | candidate |
| Snowflake | `snowflake` (`sf`) | candidate |
| BigQuery | `bigquery` (`bq`) | **gated** — not available yet |

`candidate` means defined and tested against a simulated database, not yet
qualified against every real server version. `exakit source catalog` is the
live list.

## Connect — unattended, the way an agent does it

```bash
exakit connect pg --name sales \
  --set host=db.example.com --set database=sales --set user=reader \
  --dry-run                      # the plan: downloads, objects, exposure - changes nothing

printf '%s' "$SALES_PASSWORD" | exakit connect pg --name sales \
  --set host=db.example.com --set database=sales --set user=reader
# or: --password-file ~/.config/sales.pw   (a file only the user can read)
```

Rules that are not negotiable:

- **The credential never goes on the command line.** `--password=…` is refused
  (exit 2): every local user can read another process's arguments. Pipe it on
  stdin or name a file with `--password-file`. Ask the user for it; never
  invent, guess or echo it.
- **`localhost` / `127.0.0.1` means the database itself**, not this computer,
  and the kit refuses it. A source on the user's own machine is reached at the
  address the database sees that machine at - on macOS `192.168.64.1` (the
  launcher VM's gateway; `host.containers.internal` there is the VM, not the
  Mac), on Linux and WSL `host.containers.internal` - and must listen on that
  interface, not only on 127.0.0.1. A VPN client can still drop such traffic.
  A remote source is reached by its real host name.
- **TLS verifies the server's certificate and host name by default**
  (`tls=verify`). `tls=require` only encrypts; `tls=disable` sends credentials
  in clear. Only lower it when the user says so, and say what it costs.
- **Name**: lower case, `[a-z][a-z0-9_]`, e.g. `sales`. The tables appear as
  `VS_SALES`, the credential lives in the database's `EXAKIT_SRC_SALES`.
- Show the user the plan's **exposure** line before connecting: the kit's MCP
  read-only user can read every table of the new virtual schema.

Inputs per connector are in `exakit help connect` and the plan. Defaults:
PostgreSQL port 5432 schema `public`; MySQL 3306 (database only, no schema);
SQL Server 1433 schema `dbo`; Oracle 1521 (TCPS listeners are often 2484) with
`service` and `schema`; Snowflake `account` (`orgname-account`), `database`,
`warehouse`, a programmatic access token as the credential.

## Query it

```bash
exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"
```

Identifiers follow the source's case conversion (PostgreSQL names are upper-cased
by default). `LIMIT` on a virtual table does not guarantee the source does
little work — keep remote queries selective.

## When something fails

| Exit / status | Meaning | Do |
|---|---|---|
| 2 | bad input | fix the named input |
| 3 | name or object conflict | another name, or `exakit source remove <name>` first |
| 5 | connector gated | tell the user; nothing to do |
| `auth-failed` | the source rejected the credential | `exakit source reauth <name>` (new credential on stdin) |
| `tls-failed` | certificate or host name did not verify | fix the server certificate; do not silently drop to `require` |
| `unreachable` | the source does not answer from inside the database | host, port, firewall, VPN; `localhost` trap above |
| "does not resolve" | the host name does not exist | check the spelling |

A failed **first** connect leaves nothing behind — re-run it with corrected
input. The kit repairs two things itself and retries once: Java in the database
without a DNS resolver (Exasol Personal ships it empty), and a missing Java
language container (it asks first: about 250 MiB and one database restart).

## Keep it working

```bash
exakit source list                 # every source and its last known state
exakit source issues               # only the failing ones, each with its fix
exakit source check sales          # a fresh bounded read now (--all for every source)
exakit source reauth sales         # after a password or token change
exakit source refresh sales        # after tables were added or changed at the source
```

`check` is one shot, not monitoring: nothing watches a source in the background.

## Disconnect versus remove

```bash
exakit source disconnect sales --dry-run   # drops ONLY the CONNECTION; VS_SALES stays, queries fail
exakit connect pg --name sales ...         # reconnects a disconnected source
exakit source remove sales --dry-run       # drops VS_SALES, its adapter and CONNECTION; deletes
                                           # downloaded files no other source still uses
```

Both preview, then ask; `--yes` answers for a script that was told to. Neither
touches remote data or the source's accounts, and neither revokes anything at
the source. Ask the user before removing: queries and views on `VS_<NAME>`
stop working.

## BigQuery

Gated: its driver reads a service-account key **file** inside the database, and
storage that only that connection can read is not qualified on Exasol Personal
yet. `exakit connect bigquery` explains this and stops. Do not work around it
by copying a key into a bucket.
