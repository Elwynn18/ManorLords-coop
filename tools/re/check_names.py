"""Check that every game member a Lua mod uses (obj:Func(...) / obj.Prop) exists in a UE4SS object dump.

  python -I check_names.py <main.lua> <UE4SS_ObjectDump.txt>
"""
import re
import sys

LUA_BUILTINS = {
    # Lua / UE4SS API and string/table methods the mod calls on non-game values
    "IsValid", "GetAddress", "GetFullName", "GetFName", "GetClass", "ToString", "get", "set",
    "lines", "close", "write", "read", "seek", "match", "gmatch", "gsub", "find", "sub", "byte",
    "format", "lower", "upper", "rep", "len", "insert", "remove", "concat", "sort", "unpack",
    "getinfo", "getenv", "date", "time", "clock", "open", "loadlib", "floor", "ceil", "abs",
    "sqrt", "max", "min", "random", "randomseed", "huge", "pi", "char", "path", "cpath",
    "source", "X", "Y", "Z", "W", "Pitch", "Yaw", "Roll", "Rotation", "Translation", "Scale3D",
}

lua = open(sys.argv[1], encoding="utf-8", errors="replace").read()
lua = re.sub(r"--[^\n]*", "", lua)                       # drop comments
lua = re.sub(r'"(?:[^"\\]|\\.)*"', '""', lua)            # drop string literals

calls = set(re.findall(r":([A-Za-z_]\w*)\s*\(", lua))
props = set(re.findall(r"[\w\)\]]\.([A-Za-z_]\w*)", lua)) - calls
props -= {"getinfo", "getenv", "format", "loadlib"}

dump = open(sys.argv[2], encoding="utf-8", errors="replace").read()
members = set(re.findall(r"(?:Function|Property|StructProperty|ObjectProperty|BoolProperty|IntProperty|FloatProperty|DoubleProperty|StrProperty|NameProperty|TextProperty|ArrayProperty|MapProperty|ByteProperty|EnumProperty|ClassProperty|SetProperty|DelegateProperty|MulticastInlineDelegateProperty|MulticastSparseDelegateProperty|SoftObjectProperty|WeakObjectProperty|Int64Property|UInt32Property|Int8Property|UInt16Property|Int16Property|UInt64Property|InterfaceProperty|FieldPathProperty|OptionalProperty) /[\w/.]+:([A-Za-z_]\w*)\s", dump))
classes = set(re.findall(r"Class /[\w/.]+\.([A-Za-z_]\w*)\s", dump)) | set(re.findall(r"BlueprintGeneratedClass /[\w/.]+\.([A-Za-z_]\w*)\s", dump))

missing = []
for kind, names in (("call", calls), ("prop", props)):
    for n in sorted(names - LUA_BUILTINS):
        if n not in members:
            missing.append((kind, n))

print(f"{len(calls)} calls, {len(props)} property reads checked against {len(members)} reflected members")
for kind, n in missing:
    print(f"  NOT FOUND  {kind:4}  {n}")

for c in sorted(set(re.findall(r'Find(?:First|All)Of\(""\)', lua))):
    pass
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for c in sorted(set(re.findall(r'Find(?:First|All)Of\("([\w]+)"\)', src))):
    print(f"  class {c:28} {'ok' if c in classes else 'NOT FOUND (BP classes only load in-game)'}")
