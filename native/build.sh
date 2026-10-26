#!/bin/sh
# Build coopnative.dll with clang-cl + lld-link: no CRT, no Windows SDK needed.
# Import libraries are generated from the .def files with llvm-dlltool.
set -eu
cd "$(dirname "$0")"
mkdir -p out
llvm-dlltool -m i386:x86-64 -d kernel32.def -l out/kernel32.lib
llvm-dlltool -m i386:x86-64 -d ws2_32.def -l out/ws2_32.lib
clang-cl --target=x86_64-pc-windows-msvc /nologo /O2 /GS- /Zl /W3 /c coopnative.c /Foout/coopnative.obj
lld-link /nologo /dll /entry:DllMain /nodefaultlib /subsystem:windows \
  /out:out/coopnative.dll out/coopnative.obj out/kernel32.lib out/ws2_32.lib
sha256sum out/coopnative.dll
