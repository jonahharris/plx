-- plx_strbuild correctness tests (performance is covered by the benchmark).
CREATE EXTENSION IF NOT EXISTS plx;
SET client_min_messages = warning;

-- build by appending; result and length are correct
CREATE FUNCTION sb1(n int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild := ''; i int;
BEGIN FOR i IN 1..n LOOP s := plx_sb_append(s, 'x'); END LOOP; RETURN s; END; $$;
SELECT sb1(5), length(sb1(5));

-- start from a non-empty value; append mixed content
CREATE FUNCTION sb2() RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild := 'start'; i int;
BEGIN FOR i IN 1..3 LOOP s := plx_sb_append(s, '-' || i::text); END LOOP; RETURN s; END; $$;
SELECT sb2();

-- a NULL accumulator starts empty (append is not strict)
CREATE FUNCTION sb3() RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild;
BEGIN s := plx_sb_append(s, 'a'); s := plx_sb_append(s, 'b'); RETURN s; END; $$;
SELECT sb3();

-- a NULL suffix appends nothing
CREATE FUNCTION sb4() RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild := 'x';
BEGIN s := plx_sb_append(s, NULL); s := plx_sb_append(s, 'y'); RETURN s; END; $$;
SELECT sb4();

-- reading the builder mid-loop (forces a flatten) does not corrupt it
CREATE FUNCTION sb5() RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild := ''; i int;
BEGIN
  FOR i IN 1..4 LOOP s := plx_sb_append(s, length(s::text)::text); END LOOP;
  RETURN s;
END; $$;
SELECT sb5();

-- cast round trip text -> plx_strbuild -> text, including multibyte and quotes
SELECT ('caf'||chr(233)||' ''x''')::plx_strbuild::text AS roundtrip;

-- empty builder flattens to empty string, not NULL
CREATE FUNCTION sb6() RETURNS text LANGUAGE plpgsql AS $$
DECLARE s plx_strbuild := '';
BEGIN RETURN coalesce(s::text, '<null>') || '|end'; END; $$;
SELECT sb6();

-- implicitly usable where text is expected: function calls and comparison
SELECT upper('ab'::plx_strbuild) AS as_text_fn,
       ('ab'::plx_strbuild = 'ab') AS compares_equal;
