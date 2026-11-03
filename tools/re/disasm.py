"""Small reverse-engineering helper for ManorLords-Win64-Shipping.exe (path: env ML_EXE).

  python -I disasm.py dis <rva> [max_insns]      disassemble from an RVA (stops at ret/int3 padding)
  python -I disasm.py callers <rva>               every direct call/jmp to an RVA
  python -I disasm.py sig <hex bytes>             every RVA in .text starting with those bytes
  python -I disasm.py bytes <rva> [n]             raw bytes at an RVA
"""
import os
import struct
import sys

import capstone

EXE = os.environ.get("ML_EXE", r"C:\Program Files (x86)\Steam\steamapps\common\Manor Lords\ManorLords\Binaries\Win64\ManorLords-Win64-Shipping.exe")


def load():
    data = open(EXE, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt = struct.unpack_from("<H", data, pe + 20)[0]
    secs = []
    for i in range(nsec):
        o = pe + 24 + opt + 40 * i
        name = data[o:o + 8].rstrip(b"\0").decode()
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", data, o + 8)
        secs.append((name, va, vsize, rptr, rsize))
    return data, secs


DATA, SECS = load()
TEXT = next(s for s in SECS if s[0] == ".text")


def off(rva):
    for name, va, vsize, rptr, rsize in SECS:
        if va <= rva < va + max(vsize, rsize):
            return rptr + (rva - va)
    raise ValueError(hex(rva))


def dis(rva, max_insns=200):
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    o = off(rva)
    n = 0
    for ins in md.disasm(DATA[o:o + max_insns * 15], rva):
        print(f"  {ins.address:#09x}  {ins.bytes.hex():<24} {ins.mnemonic} {ins.op_str}")
        n += 1
        if n >= max_insns or ins.mnemonic in ("ret", "int3"):
            break


def grep(rva, max_insns, pattern):
    """Linear disassembly of max_insns from rva (does not stop at ret), lines matching pattern."""
    import re
    rx = re.compile(pattern)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    o = off(rva)
    for n, ins in enumerate(md.disasm(DATA[o:o + max_insns * 15], rva)):
        line = f"{ins.mnemonic} {ins.op_str}"
        if rx.search(line):
            print(f"  {ins.address:#09x}  {line}")
        if n >= max_insns:
            break


def callers(target):
    _, va, vsize, rptr, rsize = TEXT
    text = DATA[rptr:rptr + rsize]
    hits = []
    for op in (b"\xe8", b"\xe9"):
        i = text.find(op)
        while i != -1:
            if i + 5 <= len(text):
                rel = struct.unpack_from("<i", text, i + 1)[0]
                if va + i + 5 + rel == target:
                    hits.append((va + i, "call" if op == b"\xe8" else "jmp"))
            i = text.find(op, i + 1)
    for a, k in sorted(hits):
        print(f"  {k} at {a:#x}")
    print(f"  {len(hits)} hits")


def sig(hexstr):
    pat = bytes.fromhex(hexstr.replace(" ", ""))
    _, va, vsize, rptr, rsize = TEXT
    text = DATA[rptr:rptr + rsize]
    i = text.find(pat)
    out = []
    while i != -1:
        out.append(va + i)
        i = text.find(pat, i + 1)
    print(" ".join(hex(x) for x in out[:400]))
    print(f"  {len(out)} hits")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dis":
        dis(int(sys.argv[2], 16), int(sys.argv[3]) if len(sys.argv) > 3 else 200)
    elif cmd == "grep":
        grep(int(sys.argv[2], 16), int(sys.argv[3]), sys.argv[4])
    elif cmd == "callers":
        callers(int(sys.argv[2], 16))
    elif cmd == "sig":
        sig(" ".join(sys.argv[2:]))
    elif cmd == "bytes":
        o = off(int(sys.argv[2], 16))
        print(DATA[o:o + (int(sys.argv[3]) if len(sys.argv) > 3 else 32)].hex(" "))
