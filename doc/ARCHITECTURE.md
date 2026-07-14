# plx — Architecture

> Product name is **plx** (used everywhere in code and docs). **plExcellent** is the
> marketing/advocacy backronym, styled "plx — plExcellent". The design doc below was
> written before the rename; read every "plexcellent" in it as "plx".

> **Status:** design complete & environment-verified. 2026-07-14.
> **Environment (verified live):** Incus container `plexcellent`, Ubuntu 26.04 LTS (resolute), 8 vCPU / 8 GiB.
> PostgreSQL **18.4** built from source (`REL_18_STABLE`, `--enable-debug --enable-cassert`) at
> prefix `/usr/local/pgsql`; full source tree retained at `/usr/local/src/postgresql`.
>
> **Verified symbol table** (`readelf -sW /usr/local/pgsql/lib/plpgsql.so`) — the fact the whole design hinges on:
>
> | Symbol | Binding | Cross-.so callable |
> |---|---|---|
> | plpgsql_call_handler | GLOBAL | yes |
> | plpgsql_inline_handler | GLOBAL | yes |
> | plpgsql_validator | GLOBAL | yes |
> | plpgsql_compile | GLOBAL | yes |
> | plpgsql_build_datatype | GLOBAL | yes |
> | plpgsql_compile_inline | LOCAL | NO |
> | plpgsql_exec_function | LOCAL | NO |
> | plpgsql_scanner_init | LOCAL | NO |
> | plpgsql_Datums | LOCAL | NO |
>
> _Note: the design doc below was authored by the design workflow; its references to a "/home/jd/repos/postgresql" tree or "18beta1" are the agents' own assumptions — the symbol conclusions were re-verified above against the real 18.4 build in this container._

---

All load-bearing facts are now verified against the live PG 18beta1 tree (`/home/jd/repos/postgresql`) and the built `plpgsql.so`. The single most decisive finding — which reshapes the design and disqualifies two of the three proposals as written — is the symbol-visibility table below. Here is the final architecture document.

---

# plexcellent — Final Recommended Architecture

**Target:** stock, unmodified PostgreSQL 18 (verified against 18beta1 at `/home/jd/repos/postgresql`). Extension-only, no core patch.
**Goal:** `CREATE FUNCTION … LANGUAGE plruby|plphp` where the body is a Ruby/PHP dialect, but compilation and execution are done by the stock plpgsql engine (`pl_gram.y` + `pl_exec.c`). Dialect-pluggable; Ruby and PHP share one infrastructure.

---

## 0. The one fact that dictates everything (verified)

`readelf --dyn-syms` on the built `plpgsql.so` shows that PG 18 builds PL modules with hidden default visibility. **Only symbols marked `PGDLLEXPORT` are `GLOBAL DEFAULT`** and thus resolvable from another `.so` (via `RTLD_GLOBAL`, `dlsym`, or link-time). Everything else is `LOCAL` and **cannot be called cross-module**.

| Needed capability | Symbol | Binding | Cross-`.so` callable? |
|---|---|---|---|
| Runtime call handler | `plpgsql_call_handler` | **GLOBAL** | ✅ |
| DO-block handler | `plpgsql_inline_handler` | **GLOBAL** | ✅ |
| Validator | `plpgsql_validator` | **GLOBAL** | ✅ |
| Arg-aware compile | `plpgsql_compile` | **GLOBAL** | ✅ |
| Type builder | `plpgsql_build_datatype` | **GLOBAL** | ✅ |
| Name lookup / parser hook | `plpgsql_ns_lookup`, `plpgsql_parser_setup`, `plpgsql_recognize_err_condition`, `plpgsql_exec_get_datum_type`, `plpgsql_stmt_typename` | **GLOBAL** | ✅ |
| **Execute a compiled function** | `plpgsql_exec_function` | **LOCAL** | ❌ |
| Zero-arg inline compile | `plpgsql_compile_inline` | **LOCAL** | ❌ |
| Scanner/parser primitives | `plpgsql_scanner_init/finish`, `plpgsql_yyparse`, `plpgsql_build_variable`, `plpgsql_ns_init/push` | **LOCAL** | ❌ |
| Compiler globals | `plpgsql_Datums`, `plpgsql_nDatums`, `plpgsql_curr_compile` | **LOCAL** | ❌ |

**Consequences:**
- Any design that calls `plpgsql_exec_function`, `plpgsql_compile_inline`, `plpgsql_scanner_init`, or touches `plpgsql_Datums` from another `.so` **cannot link/load on stock PG 18.** This eliminates the "direct-drive" proposal (needs `plpgsql_exec_function`) and the "reimplement-the-scaffolding / A2" proposal (needs the scanner + globals) *as written* — both assumed these symbols were exported; on this build they are not.
- The **only** way to run the plpgsql engine from our extension is through the three `GLOBAL` fmgr entry points: `plpgsql_call_handler`, `plpgsql_inline_handler`, `plpgsql_validator`.
- Therefore the winning strategy is the one that never needs a `LOCAL` symbol on any path: **transpile to canonical plpgsql at DDL time, store it in `pg_proc.prosrc`, and route execution through plpgsql's own `GLOBAL` fmgr handlers.**

---

## 1. Recommendation & rationale

**Adopt Strategy A ("transpile-at-DDL, canonical plpgsql in `prosrc`, execute via plpgsql's own handlers").** Each dialect is a source-to-source transpiler that fires **unconditionally in the language VALIDATOR** at `CREATE/REPLACE FUNCTION` time and rewrites `pg_proc.prosrc` from the dialect body to real plpgsql text; `pg_language.lanplcallfoid` points at **plpgsql's own `plpgsql_call_handler`**, so runtime is byte-for-byte stock plpgsql with zero call-path C from us. This is the only proposal whose every hot-path and DDL-path dependency is a verified `GLOBAL` symbol, so it actually builds and loads on stock PG 18; it inherits SPI setup, `fn_extra`/funccache `xmin`/`tid` invalidation, polymorphic resolution, OUT/SETOF, and trigger/event-trigger dispatch for free. We **graft three improvements** from the other proposals and from source verification: (a) the **trampoline-per-dialect + `lanname`-keyed registry** pluggability model (from the A2 proposal — the cleanest self-bootstrapping design); (b) an **unconditional, idempotent, sentinel-gated transpile** so `pg_restore` under `check_function_bodies=off` is structurally safe — verified at `pg_proc.c:724` that the validator call is *not* gated on that GUC; and (c) **embedding the original dialect source as a structured comment inside the stored plpgsql**, which reclaims the source-fidelity that plain Strategy A loses on dump/restore, plus a `PLpgSQL_plugin` rendezvous hook for line-accurate diagnostics. The DO-block path is corrected relative to the original proposal: since `plpgsql_compile_inline` is `LOCAL` and uncallable, we **delegate to the `GLOBAL` `plpgsql_inline_handler`** with a rebuilt `InlineCodeBlock`.

---

## 2. End-to-end mechanism (step by step)

### DDL time — `CREATE FUNCTION f(args) RETURNS t LANGUAGE plruby AS $$…ruby…$$`

1. **Stock core stores the raw body.** For a non-C language, `interpret_AS_clause()` sets `prosrc_str = strVal(linitial(as))` (verified `functioncmds.c:995`) — the **verbatim Ruby** goes into `pg_proc.prosrc`; `prolang = plruby` OID.
2. **`ProcedureCreate` inserts the row**, `table_close(rel,…)` (`pg_proc.c:690`), `CommandCounterIncrement()` (`:699`), then **`OidFunctionCall1(languageValidator, retval)` (`:724`) — unconditional**, guarded only by `OidIsValid(languageValidator)`. `check_function_bodies` (`:711`) only gates GUC-nesting setup, **not** the validator call. So our validator runs on every CREATE *and every restore*.
3. **Our validator (`plx_generic_validator`) transpiles.** It `SearchSysCache1(PROCOID, funcoid)`, reads `prosrc`. **Idempotency gate:** if the text begins with the sentinel `/*plx:v1:plruby:<hash>*/`, it is already canonical plpgsql (restore / re-validate) → return, no-op. Otherwise it is raw Ruby: build `PlxFuncMeta` from `get_func_arg_info()` + `prorettype`/`proretset`/`prokind`, call `ruby_dialect.transpile(src, &meta)`, prepend the sentinel + a source-map header, **append the original Ruby as a trailing structured comment** (`/*plx-orig$…$plx-orig*/`, dollar-safe), and `CatalogTupleUpdate(pg_proc, newtuple)` + `CommandCounterIncrement()`.
4. **Net catalog state:** `prolang = plruby`, `prosrc = canonical plpgsql` (sentinel-tagged, original source embedded). The new tuple bumps `xmin`/`ctid`, so any cached compile invalidates automatically. Optionally UPSERT `plx.plx_source(funcoid,…)` as a rebuildable introspection cache.

### Runtime — `SELECT f(…)`

5. fmgr resolves `pg_language.lanplcallfoid → plpgsql_call_handler` (a `GLOBAL` fmgr entry living in `plpgsql.so`), loads `$libdir/plpgsql`, and invokes it with `fcinfo->flinfo->fn_oid = f`.
6. **Stock plpgsql, our code absent:** `plpgsql_call_handler` does `SPI_connect_ext` → `plpgsql_compile(fcinfo,false)`. The compile callback reads `prosrc` from the `PROCOID` syscache (it **never inspects `prolang`**) — which is now valid plpgsql — scans it, builds `$1..$n` from `get_func_arg_info` on the same row, resolves polymorphics from `fn_expr`, parses via `pl_gram.y`, caches in `fn_extra` (funccache keyed on `fn_xmin`/`fn_tid`), then `plpgsql_exec_function` (or `_trigger`/`_event_trigger` via `CALLED_AS_*`) runs it. `SPI_finish`. Result returns through fmgr.

### DO block — `DO LANGUAGE plruby $$…ruby…$$`

7. No `prosrc` exists. fmgr calls `laninline → plx_ruby_inline_handler`. It transpiles `codeblock->source_text` → plpgsql, builds a fresh `InlineCodeBlock` (transpiled text, `langOid = plpgsql`, same `atomic`), and `OidFunctionCall1(plpgsql's laninline, cb2)`. plpgsql's `plpgsql_inline_handler` (which uses only `source_text` and `atomic`, verified) runs it. We never touch the `LOCAL` `plpgsql_compile_inline`.

---

## 3. What each C entry point does

### Runtime call handler — **not ours**
`pg_language.lanplcallfoid` points literally at `plpgsql_call_handler`. We write **zero** call-path C. Declared in install SQL by reusing plpgsql's own symbol:
```sql
CREATE FUNCTION plx_call_handler() RETURNS language_handler
  AS '$libdir/plpgsql', 'plpgsql_call_handler' LANGUAGE C;
```
`CreateProceduralLanguage` only checks `funcrettype == LANGUAGE_HANDLEROID` (`proclang.c:75`), so binding a fresh `pg_proc` row to plpgsql's exported symbol is legal.

*(Opt-in variant for diagnostics — see §7: a dialect-owned `plx_ruby_call_handler` that installs a `PLpgSQL_plugin`/error-context hook and then tail-calls `plpgsql_call_handler(fcinfo)`. Legal because `plpgsql_call_handler` is `GLOBAL`. Execution engine is still 100% plpgsql; we only add an error-context callback.)*

### Validator — `plx_generic_validator(fcinfo, PlxDialect *d)` (ours; DDL-time)
1. `funcoid = PG_GETARG_OID(0)`; `CheckFunctionValidatorAccess(fcinfo->flinfo->fn_oid, funcoid)`.
2. `SearchSysCache1(PROCOID, funcoid)`; `TextDatumGetCString(prosrc)`.
3. **Sentinel check** → if already canonical, `ReleaseSysCache` and return (idempotent for restore / CREATE OR REPLACE re-feed).
4. Build `PlxFuncMeta` (argtypes/argnames/argmodes via `get_func_arg_info`; `prorettype`, `proretset` so the transpiler can legalize `RETURN NEXT/QUERY`; `prokind`).
5. `text = d->transpile(rawbody, &meta)` — this is where the subset is enforced; anything with no plpgsql lowering is a hard `ereport(ERROR, "unsupported in plruby: …")`.
6. Prepend sentinel + source map, append embedded original, `heap_form`/`CatalogTupleUpdate(pg_proc)`, `CommandCounterIncrement()`.
7. **Unconditional** — never gated on `check_function_bodies`, so a `CREATE` under body-checks-off still fully transpiles.

### Inline (DO) handler — `plx_generic_inline_handler(fcinfo, PlxDialect *d)` (ours)
`castNode(InlineCodeBlock, arg0)` → transpile `source_text` → build `cb2` (transpiled text, `langOid = get_language_oid("plpgsql")`, copy `atomic`) → `return OidFunctionCall1(cached_plpgsql_laninline_oid, PointerGetDatum(cb2))`. No `LOCAL` symbol used.

---

## 4. How the plpgsql interpreter is actually invoked (concrete, stock PG 18)

There is **one** supported invocation path, and it is entirely inside `plpgsql.so`:

```
fmgr → plpgsql_call_handler(fcinfo)          [GLOBAL fmgr entry, resolved from lanplcallfoid]
         └─ SPI_connect_ext(...)
         └─ func = plpgsql_compile(fcinfo, false)   [reads prosrc = our canonical plpgsql]
         └─ func->cfunc.use_count++
         └─ plpgsql_exec_function(func, fcinfo, ...)  [LOCAL — but called *within* plpgsql.so]
         └─ SPI_finish()
```

We never call `plpgsql_compile`, `plpgsql_exec_function`, or any scanner symbol ourselves. We invoke the engine the same way core does: by putting the right OID in `pg_language.lanplcallfoid`. The `LOCAL`/`GLOBAL` distinction is satisfied because the only symbol *fmgr* resolves is `plpgsql_call_handler` (`GLOBAL`), and everything downstream is an intra-module call.

For DO blocks the equivalent is `OidFunctionCall1(plpgsql_laninline, InlineCodeBlock*)` → `plpgsql_inline_handler` (`GLOBAL`) → intra-module `plpgsql_compile_inline` + `plpgsql_exec_function`.

**Why in-memory runtime injection is impossible (and why we transpile at DDL):** `plpgsql_compile`'s arg-aware callback re-reads `prosrc` from `PROCOID` by `fn_oid`; the callback is static, and the only string-taking entry (`plpgsql_compile_inline`) is `LOCAL` *and* zero-arg. There is no exported hook to hand the arg-aware compiler a substitute string. So for any parameterized function the transpiled plpgsql **must physically be `prosrc`.** The DDL-time validator guarantees exactly that.

---

## 5. Dialect registry: registration & dispatch

### Packaging (two tiers)
- **`plexcellent_core`** (one `.so` + extension): owns the registry, `plx_register_dialect()`, the generic validator/inline bodies, the sentinel/source-map/embedded-source machinery, the `plx.plx_source` catalog, and the plugin-based error mapper. Ships **no** call handler of its own.
- **Per-dialect extension** (`plexcellent_ruby`, `plexcellent_php`, …): a tiny `.so` containing only (1) `char *transpile(const char *src, const PlxFuncMeta *)` and (2) trampolines. `.control` sets `requires = 'plexcellent_core'`.

### ABI contract (core header `plexcellent.h`)
```c
#define PLX_ABI_VERSION 1
typedef struct PlxFuncMeta {
    int      nargs;
    Oid     *argtypes;
    char   **argnames;
    char    *argmodes;
    Oid      rettype;
    bool     retset;      /* proretset — legalizes RETURN NEXT/QUERY  */
    char     prokind;     /* 'f' | 'p' | 'w' | trigger via rettype    */
    Oid      funcoid;
} PlxFuncMeta;

typedef struct PlxDialect {
    uint32       abi_version;   /* must == PLX_ABI_VERSION            */
    const char  *lanname;       /* "plruby" — the STABLE registry key */
    char      *(*transpile)(const char *src, const PlxFuncMeta *meta);
    int          flags;         /* trusted?, etc.                     */
} PlxDialect;

extern void plx_register_dialect(const PlxDialect *d);  /* rejects ABI mismatch */
```

### Self-bootstrapping load (the decisive fmgr fact)
fmgr `dlopen`s **only the `.so` that physically owns the symbol named by `lanplcallfoid`/`laninline`/`lanvalidator`**, and runs that `.so`'s `_PG_init` on first load (`dfmgr.c`). Because a dialect's **validator and inline** symbols live in its own `.so`, that `.so` is auto-loaded the first time a `plruby` function is created or a `plruby` DO block runs, and its `_PG_init` calls `plx_register_dialect(&ruby_dialect)` — no `shared_preload_libraries` needed. (A pure shared-symbol registry would *never* load the dialect `.so`; the trampoline-per-dialect is what forces the load.)

### Trampolines (in `plexcellent_ruby.so`)
```c
static const PlxDialect ruby_dialect = { PLX_ABI_VERSION, "plruby", ruby_transpile, PLX_TRUSTED };
void _PG_init(void) { plx_register_dialect(&ruby_dialect); }

PG_FUNCTION_INFO_V1(plx_ruby_validator);
Datum plx_ruby_validator(PG_FUNCTION_ARGS)      { return plx_generic_validator(fcinfo, &ruby_dialect); }
PG_FUNCTION_INFO_V1(plx_ruby_inline_handler);
Datum plx_ruby_inline_handler(PG_FUNCTION_ARGS) { return plx_generic_inline_handler(fcinfo, &ruby_dialect); }
```
Each trampoline already carries `&ruby_dialect`, so the validator/inline paths need no lookup. The **registry** (keyed by `lanname`, the only stable key — language OIDs don't exist until `CREATE LANGUAGE` and differ per cluster) exists for the generic **introspection/error-mapping surface** that receives an arbitrary `langOid` and must map `lanname → transpiler`. Cache `prolang-OID → PlxDialect*` and register a **`LANGOID` syscache-invalidation callback** to survive `DROP`/`CREATE LANGUAGE` churn.

### Dispatch summary
| Path | How the dialect is identified |
|---|---|
| Runtime call | Not needed — `prosrc` is already plpgsql; stock handler runs it. |
| Validator | Trampoline passes `&dialect` directly. |
| DO block | Trampoline passes `&dialect`; also `InlineCodeBlock.langOid → get_language_name → registry` if a generic entry is used. |

### A hypothetical 3rd dialect (`plsql_pl`, say a Python-ish or Lua-ish surface)
Ship `plexcellent_lua`: write `lua_transpile()`, copy the 3 trampoline lines, `_PG_init` → `plx_register_dialect(&lua_dialect)`, `.control` with `requires='plexcellent_core'`, and an install SQL doing the same 3 `CREATE FUNCTION` + one `CREATE LANGUAGE`. **~40 lines, zero core edits, zero changes to `plexcellent_core` or the other dialects.**

---

## 6. Dialect examples and their plpgsql lowering

### Ruby (`plruby`) — set-returning
```ruby
CREATE FUNCTION high_value_customers(min_total numeric)
RETURNS TABLE(cust_id int, total numeric) LANGUAGE plruby AS $$
  scanned = 0                     #:: integer
  query("SELECT id, sum(amount) AS s FROM orders GROUP BY id").each do |row|
    scanned = scanned + 1
    if row.s >= min_total
      cust_id = row.id
      total   = row.s
      emit
    end
  end
  raise notice: "scanned #{scanned} customers"
  return
$$;
```
`prosrc` after the validator runs (sentinel + source map elided, original embedded as trailing comment):
```plpgsql
/*plx:v1:plruby:9f3c…*/
DECLARE
  scanned integer := 0;
  row RECORD;                       -- hoisted from the query-loop
BEGIN
  FOR row IN SELECT id, sum(amount) AS s FROM orders GROUP BY id LOOP
    scanned := scanned + 1;
    IF row.s >= min_total THEN
      cust_id := row.id;
      total   := row.s;
      RETURN NEXT;
    END IF;
  END LOOP;
  RAISE NOTICE 'scanned % customers', scanned;
  RETURN;
END;
/*plx-orig$…verbatim Ruby…$plx-orig*/
```

### PHP (`plphp`) — scalar, INTO + branching
```php
CREATE FUNCTION grade_for(score int) RETURNS text LANGUAGE plphp AS $$
  $label = '';   /*:: text */
  if ($score >= 90) { $label = 'A'; }
  elseif ($score >= 80) { $label = 'B'; }
  else {
    [$cnt] = fetch_one("SELECT count(*) FROM retakes WHERE s = $score");
    $label = $cnt > 0 ? 'retry' : 'F';
  }
  raise('notice', "score $score -> $label");
  return $label;
$$;
```
`prosrc` after the validator:
```plpgsql
/*plx:v1:plphp:1a77…*/
DECLARE
  label text := '';
  cnt   bigint;
BEGIN
  IF score >= 90 THEN label := 'A';
  ELSIF score >= 80 THEN label := 'B';
  ELSE
    SELECT count(*) INTO cnt FROM retakes WHERE s = score;
    label := CASE WHEN cnt > 0 THEN 'retry' ELSE 'F' END;
  END IF;
  RAISE NOTICE 'score % -> %', score, label;
  RETURN label;
END;
/*plx-orig$…verbatim PHP…$plx-orig*/
```

**Shared lowering IR** (17 constructs, per the research digest): assign, if/elsif, case, while, integer-for, query-for, foreach-array, `SELECT … INTO`, perform, dynamic execute, return, return next/query, raise, exit/continue, exception block, and DECLARE-hoisting. Per-dialect surface = keyword spellings, block delimiters (`end` vs `{}`), sigils (`$` vs bare), interpolation (`#{}` vs `"$x"`), operator rewrites (concat, `?:`→`CASE`). **All expression grammar is delegated verbatim to plpgsql/SQL** — the transpiler only finds statement boundaries, hoists typed `DECLARE`s, and rewrites a handful of operators/interpolations. Semantic divergences (`==`→`=`, Ruby/PHP truthiness vs SQL three-valued NULL logic, inclusive `1..10` ranges, 0- vs 1-based) are pinned to SQL semantics and documented.

---

## 7. Error / line-number mapping back to dialect source

Because runtime errors originate in the transpiled plpgsql, raw CONTEXT lines point at plpgsql, not Ruby/PHP. Three layered mechanisms:

1. **Explicit source map.** The transpiler emits, per statement, `plpgsql_line → dialect_line`, stored (a) as a compact array in the sentinel/header comment of `prosrc` (dump-safe, travels with the function) and (b) in `plx.plx_source` for fast lookup. Helper `plx.explain(regprocedure)` renders the transpiled body with dialect lines annotated; `plx.map_line(regprocedure, int)` translates a single plpgsql line.

2. **Line-preserving emission where feasible.** For 1:1 constructs the transpiler pads the emitted plpgsql with blank lines so a dialect source line N lands on plpgsql line N; the fixed `DECLARE` preamble (hoisted vars) is accounted for by a constant offset recorded in the map. This makes most reported line numbers match the user's source directly.

3. **Live remap via the `PLpgSQL_plugin` rendezvous hook (optional, opt-in call handler).** `plexcellent_core._PG_init` obtains `find_rendezvous_variable("PLpgSQL_plugin")` (verified `pl_handler.c:209`) and installs a plugin whose `func_beg` records the executing `PLpgSQL_function.fn_oid` and whose `stmt_beg` records the current `PLpgSQL_stmt.lineno`; an `ErrorContextCallback` then appends `PL/plexcellent (plruby) source line M` using the stored map. This uses **only** the public rendezvous API — no internal symbols. Caveat: the plugin pointer is a single global slot (conflicts with `pldebugger` if both active), so it is opt-in and only engaged via the wrapper call-handler variant.

**Retrieving original source:** `plx.source(regprocedure)` extracts the embedded `/*plx-orig$…$plx-orig*/` block from `prosrc` (rebuildable without the side catalog), so the user's Ruby/PHP is always recoverable — including after dump/restore into a fresh cluster, since it travels inside `prosrc`.

---

## 8. Extension layout & `CREATE LANGUAGE` statements

```
plexcellent/
├── core/
│   ├── plexcellent_core.control          # default_version, module_pathname, relocatable=false
│   ├── plexcellent_core--1.0.sql         # plx schema, plx_source catalog, helper fns
│   ├── plx_core.c                        # registry, generic validator/inline, sentinel,
│   │                                     #   source-map, plugin hook, LANGOID inval cb
│   ├── plexcellent.h                     # PlxDialect / PlxFuncMeta ABI, plx_register_dialect
│   └── Makefile                          # PGXS
├── ruby/
│   ├── plexcellent_ruby.control          # requires = 'plexcellent_core'
│   ├── plexcellent_ruby--1.0.sql         # CREATE FUNCTION x3 + CREATE LANGUAGE plruby
│   ├── plx_ruby.c                        # ruby_transpile() + 3 trampolines + _PG_init
│   └── Makefile
└── php/
    ├── plexcellent_php.control           # requires = 'plexcellent_core'
    ├── plexcellent_php--1.0.sql
    ├── plx_php.c
    └── Makefile
```

**`core/Makefile` (PGXS):**
```make
MODULE_big = plexcellent_core
OBJS = plx_core.o
EXTENSION = plexcellent_core
DATA = plexcellent_core--1.0.sql
PG_CONFIG ?= pg_config           # MUST point at the PG18 build, not the stray 16.14
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
```
**`ruby/Makefile`** is identical with `MODULE_big = plexcellent_ruby`, `OBJS = plx_ruby.o`, `EXTENSION = plexcellent_ruby`. Header include path adds `-I../core`.

**`plexcellent_core.control`:**
```
comment = 'plexcellent shared dialect infrastructure'
default_version = '1.0'
module_pathname = '$libdir/plexcellent_core'
relocatable = false
schema = plx
```
`_PG_init` in `plx_core.c` calls `load_file("$libdir/plpgsql", false)` so plpgsql's `GLOBAL` symbols and `laninline` are present before first use, then installs the `PLpgSQL_plugin` and `LANGOID` invalidation callback.

**`plexcellent_ruby--1.0.sql`** (the `CREATE LANGUAGE` wiring — same shape per dialect):
```sql
-- Runtime handler = plpgsql's own symbol (100% stock execution):
CREATE FUNCTION plx_call_handler() RETURNS language_handler
  AS '$libdir/plpgsql', 'plpgsql_call_handler' LANGUAGE C;

-- Validator + inline live in the dialect .so (self-bootstraps _PG_init on first use):
CREATE FUNCTION plx_ruby_validator(oid) RETURNS void
  AS '$libdir/plexcellent_ruby', 'plx_ruby_validator' LANGUAGE C;
CREATE FUNCTION plx_ruby_inline_handler(internal) RETURNS void
  AS '$libdir/plexcellent_ruby', 'plx_ruby_inline_handler' LANGUAGE C;

CREATE TRUSTED LANGUAGE plruby
  HANDLER   plx_call_handler
  INLINE    plx_ruby_inline_handler
  VALIDATOR plx_ruby_validator;
```
(`plx_call_handler` may be defined once in core and reused, or redefined per dialect — either is fine since it just re-binds plpgsql's symbol. Choose `CREATE [TRUSTED] LANGUAGE` per the dialect's `flags`.)

Install order: `CREATE EXTENSION plexcellent_core;` then `CREATE EXTENSION plexcellent_ruby;`. `requires=` in the dialect `.control` enforces it and records the dependency so `pg_dump` restore order is correct.

---

## 9. Build / implementation milestones

**M0 — Skeleton & symbol proof (0.5 wk).** `plexcellent_core` + `plexcellent_ruby` skeletons; `ruby_transpile` = identity passthrough that only accepts already-plpgsql. Wire `CREATE LANGUAGE plruby`; confirm a hand-written-plpgsql body runs via the plpgsql handler. Validates the whole catalog/handler path independent of any transpiler.

**M1 — Validator materialization (1 wk).** Implement `plx_generic_validator`: syscache read, sentinel gate, `CatalogTupleUpdate` of `prosrc`, embedded-original comment, `plx.plx_source`. Test CREATE, CREATE OR REPLACE (xmin bump → recompile), and **`pg_dump | pg_restore` with `check_function_bodies=off`** (sentinel makes it a no-op; body already plpgsql).

**M2 — Registry & pluggability (0.5 wk).** `PlxDialect`/`plx_register_dialect` with ABI gate; trampolines; `LANGOID` inval callback; `load_file($libdir/plpgsql)` in `_PG_init`. Add `plexcellent_php` as a second registrant to prove non-Ruby reuse.

**M3 — Shared transpiler framework (2–3 wk).** Statement-boundary scanner + the 17-construct IR + DECLARE-hoisting with static type inference (annotation + literal inference) + interpolation/operator rewriting. Emit source maps. This is the dominant effort and the real product risk.

**M4 — Ruby & PHP surface layers (2 wk each, overlapping).** Per-dialect keyword/delimiter/sigil/interpolation tables over the shared IR. Golden-file tests: dialect body → expected plpgsql → executed result.

**M5 — DO blocks (0.5 wk).** `plx_generic_inline_handler` + `OidFunctionCall1` delegation to plpgsql's `laninline`.

**M6 — Diagnostics (1 wk).** Source-map storage, `plx.source()/explain()/map_line()`, optional `PLpgSQL_plugin` line remapper + wrapper call handler.

**M7 — Hardening (1 wk).** Polymorphic/OUT/SETOF/trigger coverage; `ALTER FUNCTION`; trust semantics; subset-rejection error quality; regression suite; version-pin CI against the exact PG18 build.

---

## 10. Key risks & open questions

1. **ABI/version pinning (build-time only, but real).** The design deliberately uses *no* `LOCAL` plpgsql symbols, so runtime ABI exposure is near-zero. But confirm on each PG minor that `plpgsql_call_handler`, `plpgsql_inline_handler`, and `laninline` stay `GLOBAL` (they are `PGDLLEXPORT` fmgr entries, so stable). **Ensure `pg_config` used for PGXS points at the PG18 build**, not the stray 16.14 noted in research.
2. **Source fidelity vs. the embedded-comment mitigation.** `\df+`/`pg_get_functiondef` show plpgsql (with the embedded original as a comment), not pristine Ruby. `plx.source()` recovers the original and it is dump-safe. **Open question:** is embedded-comment fidelity acceptable, or is a v2 **Strategy B** (keep raw dialect in `prosrc`, forward at runtime to a hidden `DEPENDENCY_INTERNAL` companion plpgsql function via `OidFunctionCall`) warranted? B gives pristine `\df+` at the cost of companion-lifecycle management (`ALTER RENAME/OWNER/SET`, cascade). Recommend shipping A; revisit B only if pristine introspection is a hard requirement.
3. **Sentinel is convention, not enforced.** A user hand-editing `prosrc`, or transpiler output colliding with the marker, could confuse the idempotency gate. Mitigate with a namespaced, versioned, hashed sentinel and a validator self-check.
4. **No mid-execution catalog writes.** Do **not** add a "transpile-on-first-call" fallback that `CatalogTupleUpdate`s during execution — it is illegal on read-only/standby/parallel backends. It is unnecessary because the validator runs unconditionally at DDL (verified `pg_proc.c:724`) and standbys receive the transpiled `prosrc` via WAL. If a raw-dialect `prosrc` is ever somehow reached at runtime, **`ereport(ERROR)` clearly** rather than attempting a write.
5. **`PLpgSQL_plugin` single-slot conflict.** Live line remapping competes with `pldebugger` for the one plugin pointer. Keep it opt-in (wrapper handler); default to the static source-map + line-padding path.
6. **Transpiler correctness is the product.** A wrong lowering is a silent wrong result, not a crash: `==`→`=`, truthiness vs SQL three-valued logic, inclusive ranges, interpolation escaping/dollar-quoting, reserved-word collisions (`row`, `query`, `execute`, `perform` are both plpgsql keywords and plausible helper names — recognize dialect intrinsics before emission). Heavy golden-file + property testing required.
7. **Subset scope management.** Static typing + mandatory `DECLARE` hoisting means every local must resolve to a PG type at transpile time or it is a hard error; no objects/closures/dynamic typing. Document the boundary; reject out-of-subset constructs with precise messages at CREATE time.
