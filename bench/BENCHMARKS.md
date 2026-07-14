# plx Benchmarks

## Method

Two workloads were measured on PostgreSQL 18.4 in the development container
(8 vCPU, 8 GiB, Ubuntu 26.04):

- Arithmetic: a function that accumulates the integers 1..2,000,000 in a loop.
  This is bound by loop dispatch and integer arithmetic in the language runtime.
- Iteration: a function that sums a `bigint` column over a 1,000,000-row table.
  This is bound by the row-retrieval path (SPI) and per-row marshalling.

Each function was written idiomatically in each language, checked for a correct
result, and called five times; the minimum wall-clock time (`psql \timing`) is
reported. The harness is `bench/run_bench.py`. All languages run in one database;
plx uses plx-prefixed language names (plxruby, plxphp), so it coexists with the
native plruby and plphp.

plxruby and plxphp transpile to plpgsql at `CREATE FUNCTION` time, so at run time
they execute as plpgsql. The native CommandPrompt PL/Ruby and PL/PHP, plperl, and
plpython3u each run an embedded interpreter and retrieve rows through SPI.

## Results

| language        | arithmetic (2M loop) | iteration (1M rows) |
|-----------------|----------------------|---------------------|
| plpgsql         | 48.0 ms (1.00x)      | 92.0 ms (1.00x)     |
| plxruby         | 50.8 ms (1.06x)      | 92.6 ms (1.01x)     |
| plxphp          | 51.0 ms (1.06x)      | 93.8 ms (1.02x)     |
| plruby (native) | 94.0 ms (1.96x)      | 373.4 ms (4.06x)    |
| plphp (native)  | 49.3 ms (1.03x)      | 245.0 ms (2.66x)    |
| plperl          | 43.3 ms (0.90x)      | 499.2 ms (5.42x)    |
| plpython3u      | 69.2 ms (1.44x)      | 342.2 ms (3.72x)    |

The multiplier is relative to plpgsql; lower is faster.

## Analysis

- plxruby and plxphp match plpgsql within measurement noise on both workloads,
  because the stored function body is plpgsql. There is no run-time translation
  cost; the translation happens once at `CREATE FUNCTION`.
- On iteration, plxruby and plxphp are faster than the native PL/Ruby and PL/PHP
  by 4.0x and 2.6x. plpgsql streams rows through a cursor and reads columns
  directly, while the embedded interpreters copy each row into their own data
  structures. plperl and plpython3u show the same pattern (5.4x and 3.7x slower
  than plpgsql).
- On arithmetic, the embedded interpreters vary: plperl is fastest (native
  integer arithmetic), plphp and plpgsql/plx are close, and native plruby and
  plpython3u are slower. plxruby and plxphp track plpgsql.

The transpile-to-plpgsql approach gives plx dialects the performance profile of
plpgsql: strong on set-oriented and SQL-bound work, competitive on procedural
arithmetic, with no additional language runtime loaded into the backend.

## Native PL/Ruby and PL/PHP build notes

Both native languages are the current CommandPrompt versions
(https://github.com/commandprompt/plruby, https://github.com/commandprompt/PL-php;
plruby 2.5, plphp 2.6). They build against PostgreSQL 18 with the following:

- PL/Ruby: built with `make PG_CONFIG=<pgconfig>`. On GCC 15 (Ubuntu 26.04),
  the older `RUBY_METHOD_FUNC` casts trip `-Werror=incompatible-pointer-types`,
  which is a default error in GCC 14 and later. Passing
  `COPT="-Wno-error=incompatible-pointer-types"` demotes it to a warning; the
  casts are valid at run time. Built against Ruby 3.3.
- PL/PHP: built with `make PG_CONFIG=<pgconfig>`. It links against the PHP embed
  SAPI library, which is provided by the `libphp8.5-embed` package on this system.
  Built against PHP 8.5.

The build scripts are `bench/build_native_pls.sh` (in-tree PL/Perl and
PL/Python3) and `bench/try_native_ruby_php.sh` (native PL/Ruby and PL/PHP).

## Reproducing

In the container:

```
python3 /root/plxsrc/bench/run_bench.py
```

Requires the `plx` extension and the comparison languages installed: PL/Perl and
PL/Python3 (`bench/build_native_pls.sh`), and native PL/Ruby and PL/PHP
(`bench/try_native_ruby_php.sh`).
