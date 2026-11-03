"""Find every instruction in the game exe that writes or reads a given struct offset (disp32 form),
grouped by the function (.pdata) it is in.

  python -I stores.py <hex offset> [write|read|any]
"""
import bisect
import re
import struct
import sys

import capstone

sys.path.insert(0, __file__.rsplit("\\", 1)[0])
from disasm import DATA, TEXT, SECS  # noqa: E402

disp = int(sys.argv[1], 16)
mode = sys.argv[2] if len(sys.argv) > 2 else "write"
data = DATA
pe = struct.unpack_from("<I", data, 0x3C)[0]
exc_rva, exc_size = struct.unpack_from("<II", data, pe + 24 + 112 + 3 * 8)
pdata = next(s for s in SECS if s[1] <= exc_rva < s[1] + s[2])
o = pdata[3] + exc_rva - pdata[1]
funcs = sorted(struct.unpack_from("<II", data, o + 12 * k) for k in range(exc_size // 12))
starts = [f[0] for f in funcs]

_, va, vsize, rptr, rsize = TEXT
text = data[rptr:rptr + rsize]
needle = struct.pack("<I", disp)
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
hits = {}
i = text.find(needle)
while i != -1:
    # try instruction starts before the displacement: REX+op+modrm first (most pointer moves),
    # then REX+op+modrm+SIB, then op+modrm
    for back in (3, 4, 2):
        s = i - back
        ins = next(md.disasm(text[s:s + 15], va + s), None)
        if ins and ins.size >= back + 4 and f"0x{disp:x}]" in ins.op_str:
            dst = ins.op_str.split(",")[0]
            is_write = f"0x{disp:x}]" in dst and ins.mnemonic.startswith("mov")
            if mode == "any" or (mode == "write") == is_write:
                k = bisect.bisect_right(starts, ins.address) - 1
                f = funcs[k][0] if k >= 0 and funcs[k][0] <= ins.address < funcs[k][1] else None
                hits.setdefault(f, []).append(f"{ins.address:#x} {ins.mnemonic} {ins.op_str}")
            break
    i = text.find(needle, i + 1)
for f, lines in sorted(hits.items(), key=lambda kv: kv[0] or 0):
    print(f"function {f:#x}" if f is not None else "function ?")
    for line in lines[:6]:
        print("   ", line)
print(f"{sum(len(v) for v in hits.values())} instructions in {len(hits)} functions")
