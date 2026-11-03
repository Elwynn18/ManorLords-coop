# Porting the native helper to a new game build

`coopnative.dll` calls and hooks game functions that are not exported, and reads game objects at
raw offsets. Every game update moves both, and the helper then refuses to start (it checks 16 bytes
at every function it uses). This file lists what it depends on for build 26185246 and how each item
was found, so the next port is a checklist rather than an investigation.

## What changed between 24905706 (0.1.0) and 26185246 (0.2.0)

Target: Steam build **26185246**, UE 5.5.4 (CL 40574608), exe sha256
`560451df38cd91134026c25b69539449c570f3163e33bc8c45b4dc20b6952cee`.

### Native functions (RVAs)

| Function | Old RVA | New RVA | How it was found |
|---|---|---|---|
| `ASMUnit::execwriteUnitDebugLog` (thunk) | 0x4a9ed90 | **0x4afd810** | UFunction native pointer; 16-byte prologue identical |
| `spawnBuilding(engine, type, loc, rot)` | 0x4c24b10 | **0x4ca1bb0** | prologue identical; called from `commitField`; argument use matches |
| `ASMBuildingMaster::findRegionAndOwner` | 0x4cb7540 | **0x4d39b40** | target of the UFunction thunk; prologue identical |
| `ASMBuildingMaster::SetupBuilding` | 0x4c9a720 | **0x4d1a650** | target of the UFunction thunk; frame 0x300 -> 0x310 |
| `finishBuilding(b, TArray<FVector>*)` | 0x4cb5020 | **0x4d37620** | called 3x from SetupBuilding with `b+0x678`; prologue identical |
| `APawnCPP::commitField` | 0x4acf830 | **0x4b35700** | target of the UFunction thunk; prologue identical |
| `APawnCPP::commitRoad` | 0x4ad09f0 | **0x4b368c0** | target of the UFunction thunk; **prologue changed** |
| `TArray<FVector>::ResizeGrow` | 0x10b91f0 | **0x10c2af0** | called by finishBuilding on a TArray<FVector>; prologue identical |
| `setHoveredBuilding(pawn, b)` (lab `hover` only) | - | **0x4b6ef70** | the only writer of `hitBuilding` besides the hover tick |

Hook stolen bytes: SetupBuilding 18, commitField 19, commitRoad **15** (was 18:
`push rbp; push rbx; push rsi; push rdi; push r15; lea rbp,[rsp-0x100]`).

`commitField` and `commitRoad` **return the object they made** (reflection lists a `ReturnValue`) and
their callers use it: hooks must return the original's result.

### ASMBuildingMaster offsets

| Meaning | Old | New | Source |
|---|---|---|---|
| `Data.bType` (building type) | 0x3a8 | **0x3B8** | reflection; SetupBuilding compares it |
| `Data.constructed` ("flag") | 0x3b1 | **0x3C1** | reflection (Data at 0x3B8, constructed +0x9) |
| building id | 0x3d0 | **0x3E0** | spawnBuilding writes it |
| `fieldWorkersNeeded` | 0x488 | **0x4C0** | reflection |
| `FieldPoints` (TArray<FVector>) | 0x5e0 | **0x660** | reflection |
| `borderIsClockwise` | 0x5f0 | **0x670** | reflection |
| `fieldPointsTriangulated` (finishBuilding arg) | 0x5f8 | **0x678** | reflection + SetupBuilding call sites |
| `fieldBorderPoints` (TArray<FVector>) | 0x628 | **0x6A8** | reflection |
| plot geometry block 1 (0x30 bytes) | 0x880 | **0x938** | commitField copies it |
| plot geometry block 2 (0xC0 bytes) | 0x9a0 | **0xA60** | commitField copies it |
| marker component (lab `peek` only) | - | **0xB98** | created by SetupBuilding (fn 0x4d4d040); not a UPROPERTY |

### APawnCPP offsets

| Meaning | Old | New | Source |
|---|---|---|---|
| cursor ground point (FVector) | 0x668 | **0x658** | fieldAddPoint reads it |
| `roadPoints` (TArray<FVector>) | 0x790 | **0x780** | reflection |
| `roadStartPos` | 0x7b8 | **0x7A8** | reflection |
| `placePlotType` | 0xf20 | **0xE78** | reflection |
| `isMarket` | 0xf22 | **0xE7A** | reflection |
| `isExtension` | 0xf23 | **0xE7B** | reflection |
| `FieldPoints` (TArray<FFieldPoint>, 0x38 stride, pos at +0x10) | 0xf38 | **0xE90** | reflection + commitField |
| `fieldClosed` | 0xf98 | **0xEF0** | reflection |
| `fieldWorkersNeeded` | 0xfb8 | **0xF10** | reflection |
| `hitBuilding` (setHoveredBuilding checks it) | - | **0x710** | reflection |

Engine-side constant unchanged: `FFrame::Locals` at 0x28 (UE 5.5).

## How to port the next build

Tools: UE4SS (installed by the installer), Python 3 with `capstone` (`pip install capstone`), the
scripts in `tools/re/` (`set ML_EXE=<path to ManorLords-Win64-Shipping.exe>`).

1. **Dump reflection.** Start the game with UE4SS, load a save, press **Ctrl+H** (C++ headers with
   offsets, `ue4ss\CXXHeaderDump\ManorLords.hpp`) and **Ctrl+J** (`ue4ss\UE4SS_ObjectDump.txt`, every
   UFunction with its native pointer `[f: ...]`). Note the exe base while it runs
   (`(Get-Process ManorLords-Win64-Shipping).MainModule.BaseAddress`).
2. **Reflected functions** (`writeUnitDebugLog`, `SetupBuilding`, `findRegionAndOwner`, `commitField`,
   `commitRoad`): `[f: ...]` minus the base is the exec thunk's RVA. `disasm.py dis <rva>` shows its
   `call`/`jmp` to the implementation, which is what the helper hooks or calls.
3. **The others** (`spawnBuilding`, `finishBuilding`, `ResizeGrow`, `setHoveredBuilding`): look for the
   old 16-byte prologue with `disasm.py sig <bytes>`, then confirm the candidate by who calls it
   (`disasm.py callers <rva>`) and how it uses its arguments. RVAs usually move by a similar amount as
   their neighbours.
4. **Offsets.** UPROPERTY members come from the header dump by name. For the unreflected ones (id,
   plot geometry, cursor point), find the code that reads or writes them: `stores.py <hex offset> any`
   lists every instruction using an offset, grouped by function.
5. **Prologues.** For each hooked function, `disasm.py dis <rva> 8` and count whole,
   position-independent instructions covering at least 14 bytes; update the stolen-byte counts and the
   tail checks in `check_build()`.
6. **Lua names.** `check_names.py lua/ManorLordsCoop/Scripts/main.lua UE4SS_ObjectDump.txt` lists any
   game function or property the Lua side uses that no longer exists (dump after loading a save, so
   blueprint classes are present).
7. **Test.** `test/run-pair.ps1 bootcheck`, then `mirror`, `fields`, `roads`, `hoverrm`; then a hand
   test with `test/run-pair.ps1 manual -Manual`. A crash leaves a minidump in
   `%LOCALAPPDATA%\ManorLords\Saved\Crashes\`; `minidump.py <UEMinidump.dmp>` turns it into a call
   stack of RVAs.
