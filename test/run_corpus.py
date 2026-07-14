#!/usr/bin/env python3
"""plx corpus test runner. Each case runs in its own fresh psql session
(so TEMP tables don't collide), output normalized and compared to expected.
Reject-* categories PASS when transpile/exec raises an ERROR.
Run as: runuser -u postgres -- python3 <thisdir>/run_corpus.py
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PSQL = "/usr/local/pgsql/bin/psql"
cases = json.load(open(os.path.join(HERE, "corpus.json")))["cases"]

def psql(sql):
    p = subprocess.run(["runuser", "-u", "postgres", "--", PSQL, "-U", "postgres",
                        "-X", "-q", "-v", "ON_ERROR_STOP=0"],
                       input=sql, capture_output=True, text=True)
    return p.stdout + p.stderr

# fresh extension
psql("DROP EXTENSION IF EXISTS plx CASCADE; CREATE EXTENSION plx;")

CHROME = {"CREATE", "EXTENSION", "FUNCTION", "DROP", "TABLE", "TEMP", "INSERT",
          "SET", "PL/pgSQL", "CONTEXT:", "line", "at"}

def datatokens(s):
    toks = set()
    for ln in s.splitlines():
        ln = ln.strip()
        if not ln or set(ln) <= set("-+| "):
            continue
        if re.match(r"^\(\d+ rows?\)$", ln):
            continue
        for t in re.split(r"[\s|]+", ln):
            t = t.strip().strip(",;\"")
            if t and t not in CHROME:
                toks.add(t)
    return toks

npass = nfail = 0
fails = []
for c in cases:
    reject = c["category"].startswith("reject")
    exp_err = "ERROR:" in c["expected_output"]
    sql = "CREATE EXTENSION IF NOT EXISTS plx;\n" + c["ruby_create"] + "\n"
    sql += c["test_sql"] + "\n"
    out = psql(sql)
    had_error = "ERROR:" in out
    if reject or exp_err:
        # expected to raise: PASS if it errored (and a keyword from expected shows)
        kw = datatokens(c["expected_output"].split("ERROR:")[-1]) if exp_err else set()
        got = datatokens(out)
        ok = had_error and (not kw or len(kw & got) >= max(1, len(kw) // 2))
    else:
        want = datatokens(c["expected_output"])
        got = datatokens(out)
        missing = want - got
        ok = (not had_error) and not missing
    if ok:
        npass += 1
    else:
        nfail += 1
        detail = out.strip().splitlines()[-3:] if out.strip() else []
        if not (reject or exp_err) and not had_error:
            detail = ["missing tokens: " + " ".join(sorted(want - got))]
        fails.append((c["id"], c["category"], detail))

print(f"PASS {npass}/{len(cases)}  FAIL {nfail}")
for fid, cat, tail in fails:
    print(f"  FAIL [{cat}] {fid}")
    for t in tail:
        print(f"        {t}")
sys.exit(1 if nfail else 0)
