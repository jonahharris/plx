# plx / plpgsql Feature Parity

Target: every plpgsql capability is expressible in each plx dialect (plxruby,
plxphp, plxjs). The reference is the plpgsql statement set in
`src/pl/plpgsql/src/plpgsql.h` (`PLpgSQL_stmt_*`) plus its declaration forms.

Legend: done / partial / todo. All three dialects track the same status unless
noted.

| plpgsql construct | plx status | dialect syntax |
|---|---|---|
| assignment (`:=`) | done | `x = e` / `$x = e;` / `x = e;` |
| `IF / ELSIF / ELSE` | done | if/elsif(elseif/else if)/else |
| `CASE` (simple + searched) | done | `case/when`, `switch/case` |
| `LOOP` | done | `loop do` / (while true) |
| `WHILE` | done | while / until |
| `FOR` integer | done | `for i in 1..n` / C-for |
| `FOR` over query | done | `query(sql).each` / `foreach`/`for..of` |
| `FOR` over dynamic query | done | same, non-literal SQL or binds |
| `FOREACH` over array | done | `array.each` / `foreach($a as $v)` / `for..of` array |
| `EXIT` / `CONTINUE` | done | next/break (+ `WHEN`); labels: todo |
| `RETURN` / `RETURN NEXT` / `RETURN QUERY` | done | return / emit / return_query |
| `RAISE` | done | raise / throw |
| `ASSERT` | done | `assert cond[, msg]` |
| `PERFORM` | done | `perform(sql)` |
| `EXECUTE` (dynamic) | done | `execute(sql, args)` |
| SQL statement / `SELECT INTO` | done | `fetch_one` / perform / execute |
| `GET DIAGNOSTICS` | done | `row_count()` , `FOUND` via `found?()` |
| `GET STACKED DIAGNOSTICS` | done | `e.message`, `e.detail`, `e.hint`, ... |
| `CALL` procedure | done | `call(proc, args)` |
| `COMMIT` / `ROLLBACK` | done | `commit()` / `rollback()` |
| cursors: `OPEN`/`FETCH`/`MOVE`/`CLOSE` | todo | |
| cursor `FOR` loop | todo | |
| declarations: `CONSTANT` | todo | |
| declarations: `%TYPE` / `%ROWTYPE` | partial | annotation may name `tbl%ROWTYPE` |
| nested block with local `DECLARE` | partial | begin/rescue reuses one scope |
| block labels `<<l>>` | todo | |

This file is updated as constructs land.
