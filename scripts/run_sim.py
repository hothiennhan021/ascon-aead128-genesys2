#!/usr/bin/env python3
"""Run one compiled Icarus simulation (vvp) and turn its PASS/FAIL text
into an exit code, so `make regress` (and CI) stops on the first failing
testbench instead of only printing FAIL lines.

A run fails if vvp exits non-zero, never reaches $finish, or prints any
line starting with "FAIL" (the convention used by every testbench here).
The full simulation log is echoed and saved next to the .vvp as .log.

Usage:  python scripts/run_sim.py build/tb_aead.vvp
"""
import os
import subprocess
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: run_sim.py <file.vvp>")
    vvp_file = sys.argv[1]
    vvp = os.environ.get("VVP", "vvp")
    proc = subprocess.run([vvp, vvp_file], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, universal_newlines=True)
    out = proc.stdout
    log_file = os.path.splitext(vvp_file)[0] + ".log"
    with open(log_file, "w") as f:
        f.write(out)
    sys.stdout.write(out)

    lines = out.splitlines()
    failed = [l for l in lines if l.startswith("FAIL")]
    finished = any("$finish called" in l for l in lines)
    name = os.path.basename(vvp_file)
    if proc.returncode != 0 or not finished or failed:
        why = ("vvp exit code %d" % proc.returncode if proc.returncode != 0
               else "simulation did not reach $finish" if not finished
               else "%d FAIL line(s)" % len(failed))
        print("*** %s FAILED (%s) -- log: %s" % (name, why, log_file))
        sys.exit(1)
    print("*** %s OK" % name)


if __name__ == "__main__":
    main()
