# Add-on modules for the preprocessor framework

Exasol has one global SQL preprocessor slot, and the framework's
`PREPROC_RT.MASTER` dispatcher holds it on every starter-kit database. An add-on
that needs to transform SQL never takes the slot itself: it registers its
transformation with MASTER as a module.

Each add-on that needs the slot gets a folder here:

```
modules/<add-on>/
  module.toml   # the framework's module manifest (name, version, phase, entry)
  <entry>.lua   # the module script
```

The upstream add-on repository stays untouched; the adaptation lives in this
kit's packaging. Users never run `ALTER SESSION SET sql_preprocessor_script`.

The kit registers a module itself - verify its pinned digest, create its Lua
script, `PREPROC.RULE_ENSURE` its rule, `PREPROC.MODULE_REGISTER` its
provenance - rather than through `PREPROC INSTALL MODULE ... FROM <url>`. That
command needs the framework's Python registry resolver, which the kit leaves
out: local deployments ship no script language container. A module's own code
is Lua (Exasol preprocessors are Lua); a module whose Lua calls a Python UDF
needs the Python container installed with it (`exasol slc install python3`).

No bundled add-on needs the slot yet. dash-server, dbt-exasol,
exasol-scheduler, exasol-vscode and json-tables ingest do not use it.
json-tables wrap and semantic-views do, and get a folder here when the kit
bundles them. The registration lifecycle they follow:

- add-on install: install the add-on, register its module, refresh
- framework arrives after the add-on (a kit update): the framework's verify
  step registers every installed add-on that has a folder here
- add-on uninstall: retire the module first, then remove the add-on
