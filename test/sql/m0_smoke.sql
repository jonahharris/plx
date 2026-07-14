-- plexcellent M0 smoke test: prove LANGUAGE plxruby executes via the plpgsql engine.
CREATE EXTENSION plx;

-- A function declared LANGUAGE plxruby whose body is (M0) plpgsql.
CREATE FUNCTION add_two(a int, b int) RETURNS int
LANGUAGE plxruby AS $$
BEGIN
	RETURN a + b;
END;
$$;

SELECT add_two(2, 3) AS should_be_5;

-- Control flow through the plpgsql engine.
CREATE FUNCTION fib(n int) RETURNS int
LANGUAGE plxruby AS $$
DECLARE
	x int := 0;
	y int := 1;
	t int;
	i int;
BEGIN
	FOR i IN 1..n LOOP
		t := x + y;
		x := y;
		y := t;
	END LOOP;
	RETURN x;
END;
$$;

SELECT fib(10) AS should_be_55;

-- Set-returning through the engine.
CREATE FUNCTION squares(n int) RETURNS TABLE(k int, sq int)
LANGUAGE plxruby AS $$
BEGIN
	FOR k IN 1..n LOOP
		sq := k * k;
		RETURN NEXT;
	END LOOP;
END;
$$;

SELECT * FROM squares(4);

-- Anonymous block via the inline (DO) handler.
DO LANGUAGE plxruby $$
BEGIN
	RAISE NOTICE 'plxruby inline says 6*7 = %', 6 * 7;
END;
$$;

-- Introspection: the language is wired to plpgsql's call handler + our validator.
SELECT lanname,
       lanplcallfoid::regprocedure AS call_handler,
       lanvalidator::regprocedure  AS validator,
       laninline::regprocedure     AS inline_handler
FROM pg_language WHERE lanname = 'plxruby';

DROP EXTENSION plx CASCADE;
