#!/usr/bin/env python3
"""check_pred.py -- verify directed predictor test logs against hand-computed
expectations. Usage: check_pred.py <build_dir>"""
import re
import sys
import os

EXPECT = {
    # test: (branches, mispredicts, checksum)
    "a": (100, 2,   0),
    "b": (200, 2,   0),
    "c": (400, 202, 100),
    "d": (210, 13,  0),
    "e": (25,  13,  0),
    "f": (3,   4,   1),
    "g": (8,   5,   0),
}

def parse(log_path):
    rep = {}
    passed = False
    with open(log_path) as f:
        for line in f:
            m = re.search(r"REPORT id=(\d+) value=(\d+)", line)
            if m:
                rep[int(m.group(1))] = int(m.group(2))
            if "RESULT: PASS" in line:
                passed = True
    return rep, passed

def main():
    build = sys.argv[1]
    nfail = 0
    for t in sorted(EXPECT):
        log = os.path.join(build, f"test_{t}.log")
        eb, em, ec = EXPECT[t]
        if not os.path.exists(log):
            print(f"test_{t}: MISSING LOG"); nfail += 1; continue
        rep, passed = parse(log)
        got = (rep.get(1), rep.get(2), rep.get(3))
        ok = passed and got == (eb, em, ec)
        status = "OK " if ok else "FAIL"
        if not ok:
            nfail += 1
        print(f"test_{t}: {status} pass={passed} "
              f"branches={got[0]} (exp {eb}) "
              f"mispredicts={got[1]} (exp {em}) "
              f"checksum={got[2]} (exp {ec})")
    print(f"{len(EXPECT)-nfail}/{len(EXPECT)} passed")
    sys.exit(1 if nfail else 0)

main()
