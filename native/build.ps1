# Build coopnative.dll on Windows with Zig's bundled clang + lld: no CRT, no Windows SDK needed.
# Same output as build.sh. Zig: $env:ZIG, or zig.exe on PATH (https://ziglang.org/download/).
# Import libraries are generated from the .def files with zig dlltool.
$ErrorActionPreference = 'Stop'
$zig = if ($env:ZIG) { $env:ZIG } else { (Get-Command zig -ErrorAction Stop).Source }
Set-Location $PSScriptRoot
New-Item -ItemType Directory -Force out | Out-Null
function Run { & $zig @args; if ($LASTEXITCODE -ne 0) { throw "zig $($args[0]) failed ($LASTEXITCODE)" } }
Run dlltool -m i386:x86-64 -d kernel32.def -l out/kernel32.lib
Run dlltool -m i386:x86-64 -d ws2_32.def -l out/ws2_32.lib
Run cc -target x86_64-windows-msvc -nostdinc -nostdlib -O2 -fno-stack-protector -ffreestanding -mno-stack-arg-probe -Wno-ignored-pragma-intrinsic -c coopnative.c -o out/coopnative.obj
Run lld-link /nologo /dll /entry:DllMain /nodefaultlib /subsystem:windows /out:out/coopnative.dll out/coopnative.obj out/kernel32.lib out/ws2_32.lib
(Get-FileHash out/coopnative.dll -Algorithm SHA256).Hash.ToLower() + '  out/coopnative.dll'
