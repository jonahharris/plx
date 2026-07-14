#!/usr/bin/env python3
"""plx benchmark harness.

Two workloads across every installed language, in one database:
  - arithmetic: an integer accumulation loop (CPU / interpreter dispatch bound)
  - iteration:  summing a column over a table (SPI / row-marshalling bound)

plx dialects (plxruby, plxphp) transpile to plpgsql. The native CommandPrompt
PL/Ruby (plruby) and PL/PHP (plphp) run their own embedded interpreters, as do
plperl and plpython3u. plx uses plx-prefixed language names, so it coexists with
the native languages in the same database.

Each function is verified for correctness, then timed as the minimum of REPS runs
(psql \\timing). Run as root in the container: python3 <thisdir>/run_bench.py
"""
import re, subprocess, sys

PSQL = "/usr/local/pgsql/bin/psql"
ARITH_N = 2_000_000
ITER_ROWS = 1_000_000
REPS = 5

def psql(sql, timing=False):
    pre = "\\timing on\n" if timing else ""
    p = subprocess.run(["runuser", "-u", "postgres", "--", PSQL, "-U", "postgres",
                        "-X", "-q", "-v", "ON_ERROR_STOP=0"],
                       input=pre + sql, capture_output=True, text=True)
    return p.stdout + p.stderr

def lang_exists(lan):
    return "1" in psql("SELECT 1 FROM pg_language WHERE lanname='%s';" % lan)

def time_call(call_sql):
    best = None
    for _ in range(REPS):
        m = re.search(r"Time:\s*([0-9.]+)\s*ms", psql(call_sql + ";", timing=True))
        if not m:
            return None
        t = float(m.group(1))
        best = t if best is None or t < best else best
    return best

# name -> (extension or None, arith_create, iter_create, arith_call, iter_call)
DEFS = [
 ("plpgsql", None,
  """CREATE FUNCTION b_a_pg(n bigint) RETURNS bigint LANGUAGE plpgsql AS $x$
DECLARE s bigint:=0; i bigint; BEGIN FOR i IN 1..n LOOP s:=s+i; END LOOP; RETURN s; END; $x$;""",
  """CREATE FUNCTION b_i_pg() RETURNS bigint LANGUAGE plpgsql AS $x$
DECLARE s bigint:=0; r record; BEGIN FOR r IN SELECT v FROM bench_data LOOP s:=s+r.v; END LOOP; RETURN s; END; $x$;""",
  "SELECT b_a_pg(%d)" % ARITH_N, "SELECT b_i_pg()"),

 ("plxruby", None,
  """CREATE FUNCTION b_a_xrb(n bigint) RETURNS bigint LANGUAGE plxruby AS $x$
s = 0 #:: bigint
for i in 1..n
  s = s + i
end
return s
$x$;""",
  """CREATE FUNCTION b_i_xrb() RETURNS bigint LANGUAGE plxruby AS $x$
s = 0 #:: bigint
query("SELECT v FROM bench_data").each do |r|
  s = s + r.v
end
return s
$x$;""",
  "SELECT b_a_xrb(%d)" % ARITH_N, "SELECT b_i_xrb()"),

 ("plxphp", None,
  """CREATE FUNCTION b_a_xphp(n bigint) RETURNS bigint LANGUAGE plxphp AS $x$
$s = 0 /*:: bigint */;
for ($i = 1; $i <= $n; $i++) { $s = $s + $i; }
return $s;
$x$;""",
  """CREATE FUNCTION b_i_xphp() RETURNS bigint LANGUAGE plxphp AS $x$
$s = 0 /*:: bigint */;
foreach (query("SELECT v FROM bench_data") as $r) { $s = $s + $r->v; }
return $s;
$x$;""",
  "SELECT b_a_xphp(%d)" % ARITH_N, "SELECT b_i_xphp()"),

 ("plruby (native)", "plruby",
  """CREATE FUNCTION b_a_nrb(n bigint) RETURNS bigint LANGUAGE plruby AS $x$
s = 0
(1..args[0]).each { |i| s += i }
s
$x$;""",
  """CREATE FUNCTION b_i_nrb() RETURNS bigint LANGUAGE plruby AS $x$
s = 0
res = spi_exec("SELECT v FROM bench_data")
while (row = spi_fetch_row(res))
  s += row['v'].to_i
end
s
$x$;""",
  "SELECT b_a_nrb(%d)" % ARITH_N, "SELECT b_i_nrb()"),

 ("plphp (native)", "plphp",
  """CREATE FUNCTION b_a_nphp(n bigint) RETURNS bigint LANGUAGE plphp AS $x$
$s = 0;
for ($i = 1; $i <= $args[0]; $i++) { $s += $i; }
return $s;
$x$;""",
  """CREATE FUNCTION b_i_nphp() RETURNS bigint LANGUAGE plphp AS $x$
$s = 0;
$r = spi_exec("SELECT v FROM bench_data");
while ($row = spi_fetch_row($r)) { $s += $row['v']; }
return $s;
$x$;""",
  "SELECT b_a_nphp(%d)" % ARITH_N, "SELECT b_i_nphp()"),

 ("plperl", "plperl",
  """CREATE FUNCTION b_a_pl(n bigint) RETURNS bigint LANGUAGE plperl AS $x$
my ($n)=@_; my $s=0; for (my $i=1;$i<=$n;$i++){ $s+=$i; } return $s;
$x$;""",
  """CREATE FUNCTION b_i_pl() RETURNS bigint LANGUAGE plperl AS $x$
my $s=0; my $rv=spi_exec_query("SELECT v FROM bench_data");
for my $row (@{$rv->{rows}}) { $s+=$row->{v}; } return $s;
$x$;""",
  "SELECT b_a_pl(%d)" % ARITH_N, "SELECT b_i_pl()"),

 ("plpython3u", "plpython3u",
  """CREATE FUNCTION b_a_py(n bigint) RETURNS bigint LANGUAGE plpython3u AS $x$
s = 0
for i in range(1, n + 1):
    s += i
return s
$x$;""",
  """CREATE FUNCTION b_i_py() RETURNS bigint LANGUAGE plpython3u AS $x$
s = 0
for row in plpy.execute("SELECT v FROM bench_data"):
    s += row["v"]
return s
$x$;""",
  "SELECT b_a_py(%d)" % ARITH_N, "SELECT b_i_py()"),
]

psql("CREATE EXTENSION IF NOT EXISTS plx;")
psql("DROP TABLE IF EXISTS bench_data; CREATE TABLE bench_data(v bigint);")
psql("INSERT INTO bench_data SELECT g FROM generate_series(1,%d) g;" % ITER_ROWS)
psql("VACUUM ANALYZE bench_data;")

exp_a = str(ARITH_N * (ARITH_N + 1) // 2)
exp_i = str(ITER_ROWS * (ITER_ROWS + 1) // 2)

rows = []
for name, ext, adef, idef, acall, icall in DEFS:
    if ext and not lang_exists(name.split()[0]):
        psql("CREATE EXTENSION IF NOT EXISTS %s;" % ext)
        if not lang_exists(name.split()[0]):
            rows.append((name, "not installed", "not installed", ""))
            continue
    for d in (adef, idef):
        o = psql(d)
        if "ERROR" in o:
            print("create failed %s:\n%s" % (name, o[:400]), file=sys.stderr)
    ok = (exp_a in psql(acall + ";")) and (exp_i in psql(icall + ";"))
    rows.append((name, time_call(acall), time_call(icall), "ok" if ok else "WRONG"))

def fmt(x):
    return ("%.1f ms" % x) if isinstance(x, float) else str(x)

base_a = next((r[1] for r in rows if r[0] == "plpgsql"), None)
base_i = next((r[2] for r in rows if r[0] == "plpgsql"), None)

print("plx benchmark  (PostgreSQL 18.4)")
print("arithmetic: accumulate 1..%d    iteration: sum %d rows    min of %d runs\n"
      % (ARITH_N, ITER_ROWS, REPS))
print("%-16s | %-18s | %-18s | %s" % ("language", "arithmetic", "iteration", "ok"))
print("-" * 64)
for name, a, i, ok in rows:
    ra = (" (%.2fx)" % (a / base_a)) if isinstance(a, float) and base_a else ""
    ri = (" (%.2fx)" % (i / base_i)) if isinstance(i, float) and base_i else ""
    print("%-16s | %-18s | %-18s | %s" % (name, fmt(a) + ra, fmt(i) + ri, ok))
print("\nx = relative to plpgsql (lower is faster). plxruby/plxphp transpile to plpgsql.")
