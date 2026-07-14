-- Auto-generated from test/corpus.json — plx transpiler corpus
CREATE EXTENSION IF NOT EXISTS plx;
SET client_min_messages=WARNING;

-- [return-arith] scalar-return-arith: Explicit scalar return of an arithmetic expression over args; no locals, no DECLARE. Confirms args pass through by name and SQL operator precedence is untouched.
CREATE FUNCTION plx_add(a int, b int) RETURNS int
LANGUAGE plxruby AS $$
return a + b * 2
$$;
SELECT plx_add(3, 4) AS r;

-- [interp] interp-return-value: String interpolation in a returned value: local inferred text (from string literal), interpolation lowered to || with ::text cast, trailing literal chunk preserved. RHS is not a constant literal so no init-fold.
CREATE FUNCTION plx_greet(name text) RETURNS text
LANGUAGE plxruby AS $$
greeting = "Hello, #{name}!"
return greeting
$$;
SELECT plx_greet('World') AS r;

-- [if-elsif] if-elsif-else: if/elsif/else chain with explicit text annotation on a branch-assigned local (declared once, no fold). >= comparisons pass through; openers end in THEN, closer END IF.
CREATE FUNCTION plx_grade(score int) RETURNS text
LANGUAGE plxruby AS $$
grade #:: text
if score >= 90
  grade = "A"
elsif score >= 80
  grade = "B"
else
  grade = "F"
end
return grade
$$;
SELECT plx_grade(85) AS r;

-- [unless-block] unless-block-and-eq: Block-form unless lowering to IF NOT (cond) with the condition parenthesized; exercises && -> AND and == -> = together. status inferred text and init-folded (top-level, first-reference, string literal).
CREATE FUNCTION plx_access(active boolean, role text) RETURNS text
LANGUAGE plxruby AS $$
status = "ok"
unless active && role == "admin"
  status = "denied"
end
return status
$$;
SELECT plx_access(true, 'guest') AS r;

-- [unless-modifier] unless-modifier-neq: Modifier unless on a return statement, plus != -> <>. Modifier expands to IF NOT (cond) THEN <stmt>; END IF; no frame pushed.
CREATE FUNCTION plx_zcheck(n int) RETURNS text
LANGUAGE plxruby AS $$
return "empty" unless n != 0
return "nonzero"
$$;
SELECT plx_zcheck(0) AS r;

-- [for-next-break] for-next-break: Integer for over 1..n with modifier next-if and break-if lowering to CONTINUE WHEN / EXIT WHEN. Loop var i is plpgsql-implicit (not hoisted); total inferred integer and init-folded.
CREATE FUNCTION plx_sum_skip(n int) RETURNS int
LANGUAGE plxruby AS $$
total = 0
for i in 1..n
  next if i == 3
  break if i > 7
  total = total + i
end
return total
$$;
SELECT plx_sum_skip(10) AS r;

-- [each-range] each-exclusive-range: (LO...HI).each do |j| block form with an EXCLUSIVE range: lowers to FOR j IN LO..(HI - 1) LOOP. s inferred integer and init-folded.
CREATE FUNCTION plx_exsum(n int) RETURNS int
LANGUAGE plxruby AS $$
s = 0
(0...n).each do |j|
  s = s + j
end
return s
$$;
SELECT plx_exsum(5) AS r;

-- [ternary] ternary-return: Ternary C ? A : B in a returned expression lowering to CASE WHEN C THEN A ELSE B END; >= comparison passes through.
CREATE FUNCTION plx_sign(x int) RETURNS text
LANGUAGE plxruby AS $$
return x >= 0 ? "nonneg" : "neg"
$$;
SELECT plx_sign(-4) AS r;

-- [raise-notice] raise-notice-interp: raise notice: with interpolation -> RAISE NOTICE with % placeholder and ordered arg; a literal % in the message is escaped to %%. Followed by a scalar return.
CREATE FUNCTION plx_note(id int) RETURNS int
LANGUAGE plxruby AS $$
raise notice: "processing id #{id} at 50%done"
return id * 10
$$;
SELECT plx_note(7) AS r;

-- [raise-exception] raise-exception-errcode: Conditional raise exception: with interpolation and an errcode: option -> RAISE EXCEPTION '...' , arg USING ERRCODE = '...'. Test drives the failing path so psql prints the ERROR.
CREATE FUNCTION plx_checkpos(v int) RETURNS int
LANGUAGE plxruby AS $$
if v < 0
  raise exception: "negative: #{v}", errcode: "22023"
end
return v
$$;
SELECT plx_checkpos(-3) AS r;

-- [annotation] annotation-numeric: Explicit numeric type annotations: trailing `#:: numeric` on a first constant assignment folds into the DECLARE init; standalone `amount #:: numeric` declares without init (RHS is an expression). Return interpolates the numeric via ::text.
CREATE FUNCTION plx_interest(principal numeric) RETURNS text
LANGUAGE plxruby AS $$
rate = 0.05 #:: numeric
amount #:: numeric
amount = principal * rate
return "interest: #{amount}"
$$;
SELECT plx_interest(1000) AS r;

-- [decl-infer] decl-infer-multi: Literal type inference across three locals (string->text, int->integer, true/false->boolean), each top-level/first-reference/constant so all init-fold into the DECLARE. Return builds a multi-interpolation string; a leading empty chunk drops (lone #{label} -> (label)::text).
CREATE FUNCTION plx_fmt() RETURNS text
LANGUAGE plxruby AS $$
label = "count"
n = 42
active = true
return "#{label}=#{n} active=#{active}"
$$;
SELECT plx_fmt() AS r;

-- [until-loop] until-loop: until loop -> WHILE NOT (cond) LOOP with the condition parenthesized; two locals inferred integer and init-folded.
CREATE FUNCTION plx_until_sum(n int) RETURNS int
LANGUAGE plxruby AS $$
i = 0
count = 0
until i >= n
  count = count + i
  i = i + 1
end
return count
$$;
SELECT plx_until_sum(5) AS r;

-- [setof-emit] setof-emit: SETOF via RETURNS TABLE + emit -> RETURN NEXT. TABLE columns idx/label are params (assigned with :=, never hoisted); integer for var i is implicit. No DECLARE section is emitted.
CREATE FUNCTION plx_rows(n int) RETURNS TABLE(idx int, label text)
LANGUAGE plxruby AS $$
for i in 1..n
  idx = i
  label = "row#{i}"
  emit
end
$$;
SELECT * FROM plx_rows(3);

-- [begin-rescue] begin-rescue: begin/rescue => e without ensure -> nested BEGIN/EXCEPTION WHEN OTHERS; e.message rewrites to SQLERRM. Division by zero is caught, a notice raised, and a fallback value returned.
CREATE FUNCTION plx_safediv(d int) RETURNS int
LANGUAGE plxruby AS $$
begin
  return 100 / d
rescue => e
  raise notice: "caught: #{e.message}"
  return -1
end
$$;
SELECT plx_safediv(0) AS r;

-- [query-for] query-for-sum: query(...).each do |row| iterating a static SELECT, summing a record field into a hoisted local; static interpolation #{g} lowers to a bare name reference.
CREATE FUNCTION c1(g int) RETURNS bigint LANGUAGE plxruby AS $$
total = 0  #:: bigint
query("SELECT amount FROM orders WHERE grp = #{g}").each do |row|
  total = total + row.amount
end
return total
$$;
CREATE TEMP TABLE orders(grp int, id int, amount bigint);
INSERT INTO orders VALUES (1,1,10),(1,2,20),(1,3,30),(2,9,5);
SELECT c1(1);

-- [fetch-one] fetch-one-row: row = fetch_one(SELECT) lowers to SELECT * INTO <record> FROM (<user sql>) AS __plx_fo_1; whole-row target hoists RECORD; field access after.
CREATE FUNCTION c2(uid int) RETURNS text LANGUAGE plxruby AS $$
u = fetch_one("SELECT id, name FROM users WHERE id = #{uid}")
return u.name
$$;
CREATE TEMP TABLE users(id int, name text);
INSERT INTO users VALUES (1,'Alice'),(2,'Bob'),(3,'Carol');
SELECT c2(2);

-- [perform] perform-dml-and-rowreturning: perform(...) with a static DML string is emitted verbatim; perform of a row-returning SELECT becomes PERFORM * FROM (<sql>) AS __plx_p_1; result discarded.
CREATE FUNCTION c4(cid int) RETURNS void LANGUAGE plxruby AS $$
perform("UPDATE counters SET n = n + 1 WHERE id = #{cid}")
perform("SELECT count(*) FROM counters")
return
$$;
CREATE TEMP TABLE counters(id int, n int);
INSERT INTO counters VALUES (1,5);
SELECT c4(1);
SELECT n FROM counters WHERE id = 1;

-- [execute-dynamic] execute-dynamic-interp-using: execute(expr, bind) is always dynamic; interpolation #{tbl} becomes runtime string concatenation || (tbl)::text and the extra arg becomes USING.
CREATE FUNCTION c5(tbl text, note text) RETURNS void LANGUAGE plxruby AS $$
execute("INSERT INTO #{tbl}(msg) VALUES ($1)", note)
return
$$;
CREATE TEMP TABLE aud(msg text);
SELECT c5('aud','hello');
SELECT msg FROM aud;

-- [setof-emit] setof-emit-returns-table: RETURNS TABLE(cust_id,total) with query iteration; TABLE columns are params (not hoisted), emit lowers to RETURN NEXT.
CREATE FUNCTION c6() RETURNS TABLE(cust_id int, total bigint) LANGUAGE plxruby AS $$
query("SELECT id, amount FROM orders WHERE grp = 1 ORDER BY id").each do |row|
  cust_id = row.id
  total = row.amount * 2
  emit
end
$$;
CREATE TEMP TABLE orders(grp int, id int, amount bigint);
INSERT INTO orders VALUES (1,1,10),(1,2,20),(1,3,30);
SELECT * FROM c6();

-- [setof-return-next] setof-return-next-expr: RETURNS SETOF int with an integer for-loop; return_next e lowers to RETURN NEXT e; trailing bare return -> RETURN;.
CREATE FUNCTION c7(n int) RETURNS SETOF int LANGUAGE plxruby AS $$
for i in 1..n
  return_next i * i
end
return
$$;
SELECT * FROM c7(3);

-- [return-query] return-query-static: return_query(static SELECT) lowers to RETURN QUERY <sql> in a SETOF function.
CREATE FUNCTION c8() RETURNS SETOF int LANGUAGE plxruby AS $$
return_query("SELECT id FROM vip ORDER BY id")
$$;
CREATE TEMP TABLE vip(id int);
INSERT INTO vip VALUES (3),(1),(2);
SELECT * FROM c8();

-- [record-field] record-field-subscript-normalize: Record field access via row[:id] and row['name'] both normalize to row.id / row.name; raise notice interpolation -> RAISE NOTICE '%'.
CREATE FUNCTION c9() RETURNS void LANGUAGE plxruby AS $$
query("SELECT id, name FROM users ORDER BY id").each do |r|
  raise notice: "user #{r[:id]}: #{r['name']}"
end
return
$$;
CREATE TEMP TABLE users(id int, name text);
INSERT INTO users VALUES (1,'Alice'),(2,'Bob'),(3,'Carol');
SELECT c9();

-- [begin-rescue] begin-rescue-unique-violation: begin/rescue with a Ruby exception class mapping (PG::UniqueViolation -> unique_violation) and e.message -> SQLERRM; local first assigned inside begin still hoisted to outer DECLARE (no init fold, := kept).
CREATE FUNCTION c10(k int) RETURNS boolean LANGUAGE plxruby AS $$
begin
  execute("INSERT INTO uniq(id) VALUES ($1)", k)
  ok = true  #:: boolean
rescue PG::UniqueViolation => e
  ok = false
  raise notice: "dup #{k}: #{e.message}"
end
return ok
$$;
CREATE TEMP TABLE uniq(id int PRIMARY KEY);
INSERT INTO uniq VALUES (1);
SELECT c10(1);
SELECT c10(2);

-- [begin-rescue-ensure] begin-rescue-ensure-doublenest: begin/rescue/ensure lowers to the double-nested BEGIN/EXCEPTION pattern so the ensure body runs exactly once on both the normal/handled and the propagate path.
CREATE FUNCTION c11(k int) RETURNS void LANGUAGE plxruby AS $$
begin
  perform("INSERT INTO t2 VALUES (#{k})")
rescue => e
  raise notice: "failed: #{e.message}"
ensure
  perform("INSERT INTO log2(msg) VALUES ('done')")
end
return
$$;
CREATE TEMP TABLE t2(x int);
CREATE TEMP TABLE log2(msg text);
SELECT c11(5);
SELECT x FROM t2;
SELECT msg FROM log2;

-- [for-next] for-int-next-if-modifier: Integer for i in 1..n (loop var not hoisted, plpgsql auto-declares it) with modifier next if -> CONTINUE WHEN; top-level literal init folded into DECLARE.
CREATE FUNCTION c12(n int) RETURNS int LANGUAGE plxruby AS $$
s = 0  #:: int
for i in 1..n
  next if i == 3
  s = s + i
end
return s
$$;
SELECT c12(5);

-- [if-elsif] if-elsif-else-operators: if/elsif/else with rewritten operators (&& -> AND, || -> OR, == -> =); conditions are boolean SQL, no truthiness coercion.
CREATE FUNCTION c13(score int, bonus boolean, override boolean) RETURNS text LANGUAGE plxruby AS $$
if score >= 90 && bonus
  return 'A'
elsif score >= 80 || override
  return 'B'
else
  return 'F'
end
$$;
SELECT c13(95,true,false) AS a, c13(70,false,true) AS b, c13(50,false,false) AS c;

-- [while-until] until-loop-break-if-compound: until C -> WHILE NOT (C) LOOP; compound assign += -> := x + (..); modifier break if -> EXIT WHEN.
CREATE FUNCTION c14(n int) RETURNS int LANGUAGE plxruby AS $$
step = 0  #:: int
until step >= n
  step += 1
  break if step > 100
end
return step
$$;
SELECT c14(5);

-- [raise-interp] raise-notice-percent-ternary: raise notice: with interpolation -> % placeholders + arg list, literal % escaped to %%; ternary ?: -> CASE WHEN ... END; annotated locals.
CREATE FUNCTION c15(done int, total int) RETURNS text LANGUAGE plxruby AS $$
pct = done * 100 / total  #:: int
label = done == total ? "complete" : "partial"  #:: text
raise notice: "50% checkpoint at #{pct} (#{label})"
return label
$$;
SELECT c15(3,10);

-- [each-with-index] each-with-index: .each_with_index hoists idx integer and row RECORD, emits idx := -1 before the FOR and injects idx := idx + 1 as the first body statement (0-based).
CREATE FUNCTION c16() RETURNS void LANGUAGE plxruby AS $$
query("SELECT name FROM users ORDER BY id").each_with_index do |row, idx|
  raise notice: "#{idx}: #{row.name}"
end
return
$$;
CREATE TEMP TABLE users(id int, name text);
INSERT INTO users VALUES (1,'Alice'),(2,'Bob'),(3,'Carol');
SELECT c16();

-- [reject-out-of-subset] reject-case-when: case/when is out of the M3 subset and must be rejected at CREATE time with a FEATURE_NOT_SUPPORTED ereport (no plpgsql body is produced).
CREATE FUNCTION e_case(x int) RETURNS text LANGUAGE plxruby AS $$
case x
when 1
  return 'one'
else
  return 'other'
end
$$;
CREATE FUNCTION e_case(x int) RETURNS text LANGUAGE plxruby AS $$
case x
when 1
  return 'one'
else
  return 'other'
end
$$;

-- [reject-out-of-subset] reject-nested-def: A nested `def` (function definition) anywhere in the body is a hard out-of-subset error rejected at CREATE time.
CREATE FUNCTION e_def(x int) RETURNS int LANGUAGE plxruby AS $$
def helper(a)
  return a + 1
end
return helper(x)
$$;
CREATE FUNCTION e_def(x int) RETURNS int LANGUAGE plxruby AS $$
def helper(a)
  return a + 1
end
return helper(x)
$$;

-- [reject-type-inference] reject-uninferable-local: A local whose first assignment RHS is a plain function call (no annotation, no literal/cast/fetch_one) cannot be typed and is rejected at CREATE time naming the var and its line.
CREATE FUNCTION e_infer(x int) RETURNS text LANGUAGE plxruby AS $$
label = compute_thing(x)
return label
$$;
CREATE FUNCTION e_infer(x int) RETURNS text LANGUAGE plxruby AS $$
label = compute_thing(x)
return label
$$;
