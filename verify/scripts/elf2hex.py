#!/usr/bin/env python3
"""elf2hex.py -- convert a RISC-V ELF test into testbench load files.

Outputs for <name>:
    <name>.hex   Verilog $readmemh file, one 32-bit little-endian word per line
    <name>.info  key=value file with: tohost=<hex addr>, words=<n>, bytes=<n>

Usage:
    elf2hex.py <test.elf> <outdir> [--mem-words N] [--objcopy BIN] [--nm BIN]

Requires riscv64-unknown-elf-objcopy / -nm (or the xpack riscv-none-elf- ones)
via --objcopy/--nm, or the RISCV_OBJCOPY / RISCV_NM environment variables.
"""
import os
import struct
import subprocess
import sys

MEM_WORDS_DEFAULT = 32768  # 128 KiB, must match tb_rv32imc.v


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"error: {' '.join(cmd)} failed:\n{r.stderr}", file=sys.stderr)
        sys.exit(1)
    return r.stdout


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    elf, outdir = sys.argv[1], sys.argv[2]
    mem_words = MEM_WORDS_DEFAULT
    objcopy = os.environ.get("RISCV_OBJCOPY", "riscv64-unknown-elf-objcopy")
    nm = os.environ.get("RISCV_NM", "riscv64-unknown-elf-nm")
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--mem-words":
            mem_words = int(args[i + 1]); i += 2
        elif args[i] == "--objcopy":
            objcopy = args[i + 1]; i += 2
        elif args[i] == "--nm":
            nm = args[i + 1]; i += 2
        else:
            print(f"error: unknown arg {args[i]}", file=sys.stderr); sys.exit(2)

    os.makedirs(outdir, exist_ok=True)
    name = os.path.splitext(os.path.basename(elf))[0]
    bin_path = os.path.join(outdir, name + ".bin")
    hex_path = os.path.join(outdir, name + ".hex")
    info_path = os.path.join(outdir, name + ".info")

    run([objcopy, "-O", "binary", elf, bin_path])
    with open(bin_path, "rb") as f:
        data = f.read()
    # pad to a whole number of words
    data += b"\x00" * ((-len(data)) % 4)
    words = struct.unpack("<%dI" % (len(data) // 4), data)
    if len(words) > mem_words:
        print(f"error: {name}: {len(words)} words exceed memory ({mem_words})",
              file=sys.stderr)
        sys.exit(1)
    with open(hex_path, "w") as f:
        for w in words:
            f.write("%08x\n" % w)

    nm_out = run([nm, elf])
    tohost = None
    for line in nm_out.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == "tohost":
            tohost = int(parts[0], 16)
    if tohost is None:
        print(f"warning: {name}: no 'tohost' symbol found", file=sys.stderr)
        tohost = 0

    with open(info_path, "w") as f:
        f.write(f"name={name}\n")
        f.write(f"tohost=0x{tohost:08x}\n")
        f.write(f"words={len(words)}\n")
        f.write(f"bytes={len(data)}\n")
    print(f"{name}: {len(words)} words, tohost=0x{tohost:08x}")


if __name__ == "__main__":
    main()
