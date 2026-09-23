#!/usr/bin/env python3
"""check_d0.py -- verify the D0 directed-test logs.

Usage: python3 check_d0.py <logdir>
Exit 0 iff every check passes; prints one line per check.
"""
import re, sys, pathlib

logdir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "logs")

def parse(log):
    txt = (logdir / log).read_text()
    rep = {int(k): int(v) for k, v in re.findall(
        r"\[TB\] REPORT id=(\d+) value=(\d+)", txt)}
    m = re.search(r"\[TB\] RESULT: (PASS|FAIL[^\n]*)", txt)
    return txt, rep, (m.group(1) if m else "NO-RESULT")

ok = True
def check(name, cond, detail=""):
    global ok
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    if not cond:
        ok = False

# (a) wait tests: RESULT PASS everywhere, checksum identical across variants
base = parse("test_wait_mix.base.log")
for tag in ("base", "imem", "dmem", "both"):
    txt, rep, res = parse(f"test_wait_mix.{tag}.log")
    check(f"wait_mix[{tag}] RESULT=PASS", res == "PASS", res)
sums = {tag: parse(f"test_wait_mix.{tag}.log")[1].get(3) for tag in
        ("base", "imem", "dmem", "both")}
check("wait_mix checksum identical (base/imem/dmem/both)",
      None not in sums.values() and len(set(sums.values())) == 1,
      f"0x{list(sums.values())[0]:08x}" if None not in sums.values() else str(sums))

txt, rep, res = parse("test_wait_misp.win.log")
check("wait_misp: redirect survives imem_wait window", res == "PASS", res)

txt, rep, res = parse("test_wait_loaduse.dmem.log")
check("wait_loaduse: RESULT=PASS", res == "PASS", res)
check("wait_loaduse: forwarded value exact",
      rep.get(3) == (0x12345679 & 0xFFFFFF) and rep.get(4) == 1,
      f"t2=0x{rep.get(3,0):08x} xor={rep.get(4,0)}")

# (a2) SoC-like address-change-triggered 2-wait (the wait x mispredict corner).
# test_wait_soc reports id=3 twice (c.jal ra, then jal ra) and id=4 (MMIO).
# The checker sees only the LAST id=3; the in-test bne catches a wrong ra
# before REPORT, so RESULT=PASS implies both links were exact.
for tag in ("soc_imem", "soc_dmem", "soc_both"):
    txt, rep, res = parse(f"test_wait_soc.{tag}.log")
    check(f"wait_soc[{tag}] RESULT=PASS", res == "PASS", res)
    check(f"wait_soc[{tag}] MMIO exactly-once",
          rep.get(4) == (0x5A5A5A5A & 0xFFFFFF), f"val=0x{rep.get(4,0):06x}")

# (b) timer interrupt
txt, rep, res = parse("test_irq_timer.timer.log")
check("irq_timer: RESULT=PASS", res == "PASS", res)
check("irq_timer: main counter == 30 (no lost/dup retire)",
      rep.get(1) == 30, f"t2={rep.get(1)}")
check("irq_timer: exactly 1 take", rep.get(2) == 1, f"takes={rep.get(2)}")

# (c) priority
txt, rep, res = parse("test_irq_prio.prio.log")
check("irq_prio: RESULT=PASS (MEI>MSI>MTI order)", res == "PASS", res)
check("irq_prio: 3 takes", rep.get(1) == 3, f"takes={rep.get(1)}")

# (d) masking
txt, rep, res = parse("test_irq_mask.mask.log")
check("irq_mask: RESULT=PASS (never taken while masked)", res == "PASS", res)

# (e) predictor liveness
txt, rep, res = parse("test_pred_alive.alive.log")
check("pred_alive: RESULT=PASS", res == "PASS", res)
check("pred_alive: 1000 branches resolved", rep.get(3) == 1000,
      f"br={rep.get(3)}")
check("pred_alive: mispredicts <= 10 (expect 2)", (rep.get(2) or 999) <= 10,
      f"mp={rep.get(2)}")
check("pred_alive: cycles < 3000 (predictions helping)", (rep.get(1) or 99999) < 3000,
      f"cyc={rep.get(1)}")

sys.exit(0 if ok else 1)
