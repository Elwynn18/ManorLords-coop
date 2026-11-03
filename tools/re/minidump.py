"""Decode a UE minidump: exception, registers, and the likely call stack (return addresses found on the
crashing thread's stack, kept only when the bytes before them are a call), as module + RVA + the
function start from the module's .pdata.

  python -I minidump.py <UEMinidump.dmp>
"""
import struct
import sys

import capstone

d = open(sys.argv[1], "rb").read()
assert d[:4] == b"MDMP"
nstreams, dir_rva = struct.unpack_from("<II", d, 8)
streams = {}
for i in range(nstreams):
    t, size, rva = struct.unpack_from("<III", d, dir_rva + 12 * i)
    streams[t] = (size, rva)


def mdstr(rva):
    n = struct.unpack_from("<I", d, rva)[0]
    return d[rva + 4:rva + 4 + n].decode("utf-16-le")


# modules
mods = []
size, rva = streams[4]
for i in range(struct.unpack_from("<I", d, rva)[0]):
    o = rva + 4 + 108 * i
    base, msize, _, _, name_rva = struct.unpack_from("<QIIII", d, o)
    mods.append((base, msize, mdstr(name_rva)))


def mod_of(addr):
    for base, msize, name in mods:
        if base <= addr < base + msize:
            return base, name
    return None, None


# exception
size, rva = streams[6]
tid = struct.unpack_from("<I", d, rva)[0]
code, flags, _, ex_addr, nparams = struct.unpack_from("<IIQQI", d, rva + 8)
params = struct.unpack_from("<15Q", d, rva + 8 + 32)
ctx_size, ctx_rva = struct.unpack_from("<II", d, rva + 8 + 32 + 120)
regs = {n: struct.unpack_from("<Q", d, ctx_rva + off)[0] for n, off in (
    ("rax", 0x78), ("rcx", 0x80), ("rdx", 0x88), ("rbx", 0x90), ("rsp", 0x98), ("rbp", 0xA0), ("rsi", 0xA8),
    ("rdi", 0xB0), ("r8", 0xB8), ("r9", 0xC0), ("r10", 0xC8), ("r11", 0xD0), ("r12", 0xD8), ("r13", 0xE0),
    ("r14", 0xE8), ("r15", 0xF0), ("rip", 0xF8))}
b, n = mod_of(ex_addr)
print(f"exception {code:#x} at {ex_addr:#x} ({n.split(chr(92))[-1] if n else '?'} +{ex_addr - b:#x})" if b else f"exception {code:#x} at {ex_addr:#x}")
print("  params:", " ".join(hex(p) for p in params[:nparams]))
print("  " + "  ".join(f"{k}={v:#x}" for k, v in regs.items()))

# the PE files on disk, for .pdata and call checks
pe_cache = {}


def pe(path):
    if path in pe_cache:
        return pe_cache[path]
    try:
        data = open(path, "rb").read()
    except OSError:
        pe_cache[path] = None
        return None
    p = struct.unpack_from("<I", data, 0x3C)[0]
    ns = struct.unpack_from("<H", data, p + 6)[0]
    opt = struct.unpack_from("<H", data, p + 20)[0]
    secs = [struct.unpack_from("<8sIIII", data, p + 24 + opt + 40 * i) for i in range(ns)]
    exc_rva, exc_size = struct.unpack_from("<II", data, p + 24 + 112 + 3 * 8)

    def off(r):
        for _, vs, va, rs, rp in secs:
            if va <= r < va + max(vs, rs):
                return rp + r - va
        return None
    funcs = []
    o = off(exc_rva)
    if o is not None:
        for k in range(exc_size // 12):
            beg, end, _ = struct.unpack_from("<III", data, o + 12 * k)
            funcs.append((beg, end))
    funcs.sort()
    pe_cache[path] = (data, off, funcs)
    return pe_cache[path]


def func_start(path, r):
    info = pe(path)
    if not info:
        return None
    import bisect
    funcs = info[2]
    i = bisect.bisect_right(funcs, (r, 0xFFFFFFFF)) - 1
    if i >= 0 and funcs[i][0] <= r < funcs[i][1]:
        return funcs[i][0]
    return None


md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)


def after_call(path, r):
    info = pe(path)
    if not info:
        return False
    data, off, _ = info
    for back in (5, 6, 2, 3, 7):
        o = off(r - back)
        if o is None:
            continue
        ins = list(md.disasm(data[o:o + back], r - back))
        if len(ins) == 1 and ins[0].mnemonic == "call" and ins[0].size == back:
            return True
    return False


def where(addr):
    b, name = mod_of(addr)
    if not b:
        return None
    r = addr - b
    fs = func_start(name, r)
    short = name.split("\\")[-1]
    return f"{short} +{r:#x}" + (f"  (in function {fs:#x} +{r - fs:#x})" if fs is not None else "")


print("crash site:", where(ex_addr))

# crashing thread's stack
size, rva = streams[3]
for i in range(struct.unpack_from("<I", d, rva)[0]):
    o = rva + 4 + 48 * i
    t_id = struct.unpack_from("<I", d, o)[0]
    if t_id != tid:
        continue
    start, ssize, srva = struct.unpack_from("<QII", d, o + 24)
    rsp = regs["rsp"]
    print(f"stack of thread {tid}: {ssize:#x} bytes from {start:#x}, rsp={rsp:#x}")
    k = max(0, rsp - start)
    shown = 0
    while k + 8 <= ssize and shown < 60:
        v = struct.unpack_from("<Q", d, srva + k)[0]
        b, name = mod_of(v)
        if b and after_call(name, v - b):
            print(f"  [rsp+{start + k - rsp:#06x}] {where(v)}")
            shown += 1
        k += 8
