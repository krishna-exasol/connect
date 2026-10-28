---
name: exasol-virtual-schemas
description: Query an external database - PostgreSQL, MySQL, SQL Server, Oracle or Snowflake - or JSON, CSV and Parquet files in an Amazon S3 bucket from the local Exasol database through a virtual schema, with exakit connect and exakit source. Covers giving inputs unattended, passing the credential safely (never as an argument), reading the plan, the "localhost inside the database is not this computer" trap, the failure classes and their fixes (auth, TLS, unreachable, no DNS, no Java, S3 access denied or wrong region), the EDML mapping that turns S3 objects into tables, reauth after a password change, disconnect versus remove, and why BigQuery is gated. Triggers — "connect my Postgres to Exasol", "query MySQL from Exasol", "virtual schema", "federate a remote database", "exakit connect", "exakit source", "my source password changed", "the virtual schema stopped working", "remove a connected source", "join local tables with a remote database", "connect Snowflake", "connect SQL Server", "connect Oracle", "query files in S3", "connect an S3 bucket", "JSON files in S3 as a table", "EDML mapping".
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
| Amazon S3 (JSON, CSV, Parquet files) | `s3` (`aws-s3`) | candidate |
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
- **A private CA is trusted, not skipped.** Managed databases (AWS RDS, Azure)
  and company servers sign with a CA Java does not hold, so the first verified
  connect fails with "PKIX path building failed" (MySQL: "Path does not chain
  with any of the trust anchors"). PostgreSQL, MySQL, SQL Server and Oracle
  take `--set ca=<PEM file>`: the CA's certificate, or the vendor's bundle (for RDS
  the region's, from `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`).
  The kit keeps it with the source. Do not answer a PKIX error with
  `tls=require`.
- **"the trustAnchors parameter must be non-empty"** is Exasol Personal's
  JDBC loader having no CA store of its own: it verifies nothing unless given
  a CA. PostgreSQL, MySQL, SQL Server and Oracle: `--set ca=<PEM>` (a public
  CA's root works too). Snowflake cannot take one yet; `tls=require` encrypts
  without verifying - only if the user accepts that. Oracle's TLS (TCPS) is
  usually on port 2484, not 1521: `--set port=2484`.
- **"validity check failed"** with a certificate that is in date means the
  database clock is behind - after the laptop slept or hibernated, Exasol
  Personal's clock does not catch up. `connect` and `source check` measure it
  and warn ("The database clock is 33 min behind this computer"), and the
  failure's fix then names it. `exakit stop`, then `exakit start`.
- **Name**: lower case, `[a-z][a-z0-9_]`, e.g. `sales`. The tables appear as
  `VS_SALES`, the credential lives in the database's `EXAKIT_SRC_SALES`.
- Show the user the plan's **exposure** line before connecting: the kit's MCP
  read-only user can read every table of the new virtual schema.
- **MySQL tables keep their lower-case names, SQL Server tables their mixed
  case**: quote them exactly, `SELECT * FROM VS_SALES."orders"`,
  `SELECT "UnitPrice" FROM VS_ERP."Order Details"`. And write top-N queries on a MySQL
  source as `ORDER BY x DESC NULLS LAST LIMIT n` - plain `DESC LIMIT n` is
  pushed down with `NULLS FIRST`, which MySQL rejects (upstream adapter 6.1.0).
- **PostgreSQL**: a column whose type is a domain fails every query that reads
  it (`ETL-1299`; name the other columns instead of `*`), `numeric` arrives as
  text (documented upstream; SUM and comparisons still work), array columns
  are missing, and a partitioned table shows only its partitions.

Inputs per connector are in `exakit help connect` and the plan. Defaults:
PostgreSQL port 5432 schema `public`; MySQL 3306 (database only, no schema);
SQL Server 1433 schema `dbo`; Oracle 1521 (TCPS listeners are often 2484) with
`service` and `schema`; Snowflake `account` (`orgname-account`), `database`,
`warehouse`, a programmatic access token as the credential.

## Amazon S3: files as tables

S3 is not a database, so two things replace host/user/password: an **EDML
mapping** that says which objects become which table, and an **access key**.

```bash
# mapping/orders.json - one file per table (a folder of them is fine)
{"$schema": "https://schemas.exasol.com/edml-2.1.0.json",
 "source": "data/orders/*.jsonl", "destinationTable": "ORDERS",
 "mapping": {"fields": {"order_id": {"toDecimalMapping": {"decimalPrecision": 10, "decimalScale": 0}},
                        "status": {"toVarcharMapping": {"varcharColumnSize": 20}}}}}

exakit connect s3 --name docs --set bucket=my-bucket --set region=eu-central-1 \
  --set mapping=./mapping --password-file ~/keys/reader.json
```

- **The key**: `--password-file` with the JSON that `aws iam create-access-key`
  or `aws sts get-session-token` prints, or the secret key alone on stdin plus
  `--set access_key_id=AKIA...`. Temporary (`ASIA...`) keys need their
  session token, so give the sts JSON; they expire, and `exakit source reauth
  <name> --password-file <new.json>` replaces them. The kit never reads `~/.aws`.
- **Least privilege**: the key needs `s3:ListBucket` on the mapped prefixes and
  `s3:GetObject` on the objects - nothing else. Suggest a dedicated read-only
  IAM user, not the user's own keys.
- **The mapping**: `source` is the object key or glob inside the bucket (no
  `s3://`); the type comes from the extension - `.json` (one document per
  file), `.jsonl`, `.csv`, `.parquet`. CSV and Parquet can omit `mapping` and
  have columns inferred; JSON needs explicit fields. A nested list becomes a
  second table (`toTableMapping`, e.g. `ORDERS_ITEMS` keyed by
  `ORDERS_ORDER_ID`); `"addSourceReferenceColumn": true` adds the object key
  as `SOURCE_REFERENCE`, and `WHERE SOURCE_REFERENCE = '...'` reads one file.
  The kit checks the mapping before anything happens.
- **A glob that matches nothing is an empty table, not an error**: connect and
  check name such tables ("No rows in EVENTS").
- Standard regional endpoints over verified HTTPS only: a bucket with dots,
  China regions, custom endpoints and anonymous access are refused.
- To change the mapping: `exakit source remove <name>`, then connect again.

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
| 4 | no source by that name | `exakit source list` |
| 5 | connector gated, or not confirmed | gated: tell the user. Not confirmed (`disconnect`/`remove` without `--yes`): nothing changed - ask the user, then add `--yes` |
| `auth-failed` | the source rejected the credential | `exakit source reauth <name>` (new credential on stdin; it is tried first, and a refused one leaves the old in place) |
| `tls-failed` | certificate or host name did not verify | PKIX: the CA is private - reconnect with `--set ca=<PEM>`. "validity check failed": restart the database (clock). Otherwise fix the server certificate; do not silently drop to `require` |
| `unreachable` | the source does not answer from inside the database | host, port, firewall, VPN; `localhost` trap above |
| "does not resolve" | the host name does not exist | check the spelling |
| `access-denied` | S3: the key works but may not list or read (the message names the action, e.g. `s3:ListBucket`) | grant that permission on the prefix, then `exakit source check <name>` - not reauth |
| S3 "addressed using the specified endpoint" | the bucket is in another region | reconnect with `--set region=<the bucket's region>` |
| S3 "RequestTimeTooSkewed" | the database clock is off (signed requests allow 15 minutes) | `exakit stop`, then `exakit start` |

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
exakit connect pg --name sales --password-file F   # reconnects it; the recorded inputs are reused
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
