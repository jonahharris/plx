-- plx rejection tests: each CREATE FUNCTION must fail at CREATE time with a
-- precise error and source line number.
CREATE EXTENSION IF NOT EXISTS plx;
SET client_min_messages = warning;

-- plxruby: nested def
CREATE FUNCTION e_rb_def() RETURNS int LANGUAGE plxruby AS $$
def helper
  1
end
return helper
$$;

-- plxruby: unresolvable local type
CREATE FUNCTION e_rb_type() RETURNS int LANGUAGE plxruby AS $$
x = some_call()
return x
$$;

-- plxruby: next outside a loop
CREATE FUNCTION e_rb_next() RETURNS int LANGUAGE plxruby AS $$
next
return 1
$$;

-- plxruby: assignment with an empty right-hand side
CREATE FUNCTION e_rb_emptyrhs() RETURNS int LANGUAGE plxruby AS $$
x =#:: int
return 1
$$;

-- plxphp: nested function definition
CREATE FUNCTION e_php_fn() RETURNS int LANGUAGE plxphp AS $$
function helper() { return 1; }
return 1;
$$;

-- plxphp: switch fall-through (non-terminated case body)
CREATE FUNCTION e_php_fall(n int) RETURNS text LANGUAGE plxphp AS $$
switch ($n) {
  case 1: $x = "a";
  case 2: return "b";
}
return "c";
$$;

-- plxjs: switch fall-through
CREATE FUNCTION e_js_fall(n int) RETURNS text LANGUAGE plxjs AS $$
switch (n) {
  case 1: let x = "a";
  default: return "b";
}
$$;
