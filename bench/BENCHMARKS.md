# plx Benchmarks

## Method

Five workloads were measured on PostgreSQL 18.4 in the development container
(8 vCPU, 8 GiB, Ubuntu 26.04):

- arith: accumulate the integers 1 to 2,000,000 in a loop (loop dispatch and
  integer arithmetic).
- strbuild: build a 200,000-character string one character at a time in a loop
  (text handling with the natural in-language idiom for each language). plpgsql
  uses `s := s || 'x'`. The plx dialects use their append operator (`s << 'x'`,
  `$s .= 'x'`, `s += 'x'`), which plx lowers to the plx_strbuild builder.
- iter: sum a `bigint` column over a 1,000,000-row table (SPI and per-row
  marshalling).
- branch: a four-way conditional per element over 2,000,000 elements (branch
  dispatch).
- call: 500,000 calls to a small function (call and return overhead). For plperl
  and plpython3u this uses 50,000 iterations, because each call goes through SPI
  and is far slower; those two cells are scaled to the smaller count.

Each function is written idiomatically in each language, checked for a correct
result, and called five times; the minimum wall-clock time (`psql \timing`) is
reported. The harness is `bench/run_bench.py`. All languages run in one database;
plx uses plx-prefixed language names, so it coexists with the native plruby,
plphp, plperl, and plpython3u.

plxruby, plxphp, plxjs, and plxpython3 transpile to plpgsql at `CREATE FUNCTION`
time, so at run time they execute as plpgsql. plperl and plpython3u run their own
embedded interpreters and retrieve rows through SPI.

## Results

Times are milliseconds; the multiplier is relative to plpgsql (lower is faster).

| language   | arith        | strbuild     | iter          | branch        | call          |
|------------|--------------|--------------|---------------|---------------|---------------|
| plpgsql    | 48 (1.00x)   | 1597 (1.00x) | 88 (1.00x)    | 150 (1.00x)   | 145 (1.00x)   |
| plxruby    | 50 (1.06x)   | 9 (0.01x)    | 97 (1.10x)    | 153 (1.02x)   | 151 (1.05x)   |
| plxphp     | 52 (1.09x)   | 9 (0.01x)    | 99 (1.11x)    | 154 (1.02x)   | 149 (1.03x)   |
| plxjs      | 51 (1.07x)   | 10 (0.01x)   | 94 (1.06x)    | 154 (1.03x)   | 153 (1.06x)   |
| plxpython3 | 53 (1.12x)   | 10 (0.01x)   | 99 (1.12x)    | 154 (1.03x)   | 149 (1.03x)   |
| plperl     | 42 (0.88x)   | 12 (0.01x)   | 507 (5.74x)   | 139 (0.93x)   | 273 (1.89x)   |
| plpython3u | 64 (1.35x)   | 14 (0.01x)   | 337 (3.81x)   | 108 (0.72x)   | 165 (1.14x)   |

In the strbuild column, native plpgsql is the `s := s || 'x'` baseline and the
plx dialects use the builder. This is the intended native-versus-plx comparison:
the same accumulation idiom is 1597 ms in stock plpgsql and about 10 ms in the
plx dialects. These numbers are on PostgreSQL 18; the builder's amortized-O(1)
append requires PostgreSQL 18 (see the version note under String building). On
PostgreSQL 13 to 17 the plx strbuild column would match plpgsql (both O(n^2)).

## Analysis

- The four plx dialects match plpgsql within about 11 percent on every workload,
  because the stored function body is plpgsql. There is no run-time translation
  cost; the translation happens once at `CREATE FUNCTION`. The small spread among
  the dialects is measurement noise.

- Row iteration (iter): plpgsql, and therefore the plx dialects, are 3.7x to 5.6x
  faster than plperl and plpython3u. plpgsql streams rows through a cursor and
  reads columns directly, while the embedded interpreters copy each row into
  their own data structures.

- String building (strbuild): concatenating onto a text variable in a loop
  (`s := s || 'x'`) is quadratic in plpgsql, because text is immutable and each
  step rebuilds the whole string. This is the one workload where plx does not
  simply match plpgsql: plx ships an expanded-object string builder
  (`plx_strbuild`, see `../doc/` and `src/plx_strbuild.c`) whose append is
  amortized O(1), and the transpiler lowers the dialect append operators
  (`<<`, `.=`, `+=` on a string) onto it. The result is about 170x faster than
  the stock plpgsql idiom and on par with the embedded interpreters' native
  append. In hand-written plpgsql the same win is available by calling
  `plx_sb_append`, or by assembling text in SQL with `string_agg` over a set.

- Arithmetic (arith): the embedded interpreters vary. plperl is fastest (native
  integer arithmetic), plpython3u is slowest, and plpgsql with the plx dialects
  sits between.

- Branching (branch): plpython3u is faster on this pure-CPU integer workload
  (0.72x); plperl and plpgsql with the plx dialects are close to each other.

- Call overhead (call): plpgsql and the plx dialects are fastest. plperl and
  plpython3u pay an SPI round trip per call and are slower even at one tenth the
  iteration count.

The transpile-to-plpgsql approach gives the plx dialects the performance profile
of plpgsql: strong on set-oriented and SQL-bound work, competitive on procedural
arithmetic and branching, and with no additional language runtime loaded into the
backend. In-loop string building, the one case where plpgsql is weak, is handled
by the string builder, which brings it on par with the embedded interpreters on
PostgreSQL 18 (on PostgreSQL 13 to 17 the builder is correct but not accelerated,
so that case remains O(n^2)).

## Native PL/Ruby and PL/PHP build notes

The comparison against the third-party native PL/Ruby and PL/PHP is documented in
the build scripts. Both are the current CommandPrompt versions
(https://github.com/commandprompt/plruby, https://github.com/commandprompt/PL-php;
plruby 2.5, plphp 2.6). They build against PostgreSQL 18 with:

- PL/Ruby: `make PG_CONFIG=<pgconfig>`. On GCC 15 (Ubuntu 26.04) pass
  `COPT="-Wno-error=incompatible-pointer-types"` to demote the older
  `RUBY_METHOD_FUNC` cast warnings, which are valid at run time. Built against
  Ruby 3.3.
- PL/PHP: `make PG_CONFIG=<pgconfig>`. Links against the PHP embed SAPI, provided
  by the `libphp8.5-embed` package. Built against PHP 8.5.

## Reproducing

In the container:

```
PGHOST=/tmp PGPORT=5432 python3 bench/run_bench.py
```

Requires the `plx` extension and the comparison languages installed: PL/Perl and
PL/Python3 (`bench/build_native_pls.sh`), and optionally native PL/Ruby and
PL/PHP (`bench/try_native_ruby_php.sh`).
