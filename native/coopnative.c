// coopnative.dll - native half of the Manor Lords co-op mod (UE4SS Lua mod "ManorLordsCoop").
//
// Loaded by the Lua mod with package.loadlib(path, "*"). It
//   1. checks the game build byte for byte (only Steam build 26185246, shipping exe sha256
//      560451df...); on any mismatch it installs nothing and says so in its log;
//   2. replaces the exec thunk of the debug UFunction ASMUnit:writeUnitDebugLog(FString) so the
//      Lua side can send it text commands that run on the game thread;
//   3. hooks SetupBuilding to report every building the game sets up (outbox file);
//   4. runs one TCP connection (host or join) in a background thread; whatever arrives is written
//      to an inbox file that the Lua side reads.
//
// No C runtime, kernel32 + ws2_32 only. Build: build.sh (clang-cl + lld-link).
// License: MIT (see LICENSE).

typedef unsigned long long u64;
typedef long long i64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned short wchar;
typedef unsigned char u8;

// ------------------------------------------------------------------ imports
__declspec(dllimport) void *__stdcall GetModuleHandleW(const wchar *);
__declspec(dllimport) u32 __stdcall GetModuleFileNameW(void *, wchar *, u32);
__declspec(dllimport) int __stdcall VirtualProtect(void *, u64, u32, u32 *);
__declspec(dllimport) void *__stdcall VirtualAlloc(void *, u64, u32, u32);
__declspec(dllimport) void *__stdcall GetCurrentProcess(void);
__declspec(dllimport) int __stdcall FlushInstructionCache(void *, const void *, u64);
__declspec(dllimport) u32 __stdcall GetEnvironmentVariableW(const wchar *, wchar *, u32);
__declspec(dllimport) void *__stdcall CreateFileW(const wchar *, u32, u32, void *, u32, u32, void *);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, u32, u32 *, void *);
__declspec(dllimport) int __stdcall ReadFile(void *, void *, u32, u32 *, void *);
__declspec(dllimport) int __stdcall GetFileSizeEx(void *, i64 *);
__declspec(dllimport) int __stdcall CloseHandle(void *);
__declspec(dllimport) int __stdcall CreateDirectoryW(const wchar *, void *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall CreateThread(void *, u64, u32(__stdcall *)(void *), void *, u32, u32 *);
__declspec(dllimport) void __stdcall Sleep(u32);
__declspec(dllimport) void __stdcall InitializeCriticalSection(void *);
__declspec(dllimport) void __stdcall EnterCriticalSection(void *);
__declspec(dllimport) void __stdcall LeaveCriticalSection(void *);
__declspec(dllimport) int __stdcall DeleteFileW(const wchar *);
__declspec(dllimport) int __stdcall MoveFileExW(const wchar *, const wchar *, u32);
__declspec(dllimport) u64 __stdcall VirtualQuery(const void *, void *, u64);

typedef u64 SOCKET;
#define INVALID_SOCKET ((SOCKET)~0ull)
typedef struct { u16 family; u16 port; u32 addr; u8 zero[8]; } sockaddr_in_t;
__declspec(dllimport) int __stdcall WSAStartup(u16, void *);
__declspec(dllimport) SOCKET __stdcall socket(int, int, int);
__declspec(dllimport) int __stdcall bind(SOCKET, const void *, int);
__declspec(dllimport) int __stdcall listen(SOCKET, int);
__declspec(dllimport) SOCKET __stdcall accept(SOCKET, void *, int *);
__declspec(dllimport) int __stdcall connect(SOCKET, const void *, int);
__declspec(dllimport) int __stdcall send(SOCKET, const char *, int, int);
__declspec(dllimport) int __stdcall recv(SOCKET, char *, int, int);
__declspec(dllimport) int __stdcall closesocket(SOCKET);
__declspec(dllimport) int __stdcall setsockopt(SOCKET, int, int, const char *, int);
__declspec(dllimport) u16 __stdcall htons(u16);
__declspec(dllimport) u32 __stdcall inet_addr(const char *);
__declspec(dllimport) int __stdcall WSAGetLastError(void);

#pragma function(memset, memcpy)
void *memset(void *d, int c, u64 n) { u8 *p = d; while (n--) *p++ = (u8)c; return d; }
void *memcpy(void *d, const void *s, u64 n) { u8 *p = d; const u8 *q = s; while (n--) *p++ = *q++; return d; }
int _fltused = 0;

#define MOD_VERSION "0.2.0"

// ------------------------------------------------------------------ game layout (build 26185246)
// ASMBuildingMaster
#define B_TYPE      0x3b8   // Data.bType
#define B_FLAG      0x3c1   // Data.constructed
#define B_ID        0x3e0   // building id (spawnBuilding assigns it)
#define B_WORKERS   0x4c0   // fieldWorkersNeeded
#define B_FIELDPTS  0x660   // FieldPoints (TArray<FVector>)
#define B_CLOCKWISE 0x670   // borderIsClockwise
#define B_TRIANG    0x678   // fieldPointsTriangulated (finishBuilding's argument)
#define B_BORDER    0x6a8   // fieldBorderPoints (TArray<FVector>)
#define B_MARKERS   0xb98   // instanced mesh component SetupBuilding creates (fn 0x4d4d040); not a UPROPERTY
// APawnCPP
#define P_CURSOR    0x658   // ground point under the cursor (FVector)
#define P_ROADPTS   0x780   // roadPoints (TArray<FVector>)
#define P_ROADSTART 0x7a8   // roadStartPos
#define P_PLOTTYPE  0xe78   // placePlotType
#define P_ISMARKET  0xe7a
#define P_ISEXT     0xe7b   // isExtension
#define P_FIELDPTS  0xe90   // FieldPoints (TArray<FFieldPoint>, 0x38 bytes, position at +0x10)
#define P_CLOSED    0xef0   // fieldClosed
#define P_WORKERS   0xf10   // fieldWorkersNeeded

// ------------------------------------------------------------------ small string helpers
static int wlen(const wchar *s) { int n = 0; while (s[n]) n++; return n; }
static void wcat(wchar *d, int cap, const wchar *s) { int n = wlen(d); while (*s && n < cap - 1) d[n++] = *s++; d[n] = 0; }
static void wcat_a(wchar *d, int cap, const char *s) { int n = wlen(d); while (*s && n < cap - 1) d[n++] = (wchar)(u8)*s++; d[n] = 0; }

// UTF-16 (n units) -> UTF-8, returns bytes written (no terminator)
static int to_utf8(const wchar *s, int n, char *out, int cap) {
    int o = 0;
    for (int i = 0; i < n && s[i]; i++) {
        u32 c = s[i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) { c = 0x10000 + ((c - 0xD800) << 10) + (s[i + 1] - 0xDC00); i++; }
        if (c < 0x80) { if (o + 1 > cap) break; out[o++] = (char)c; }
        else if (c < 0x800) { if (o + 2 > cap) break; out[o++] = (char)(0xC0 | (c >> 6)); out[o++] = (char)(0x80 | (c & 63)); }
        else if (c < 0x10000) { if (o + 3 > cap) break; out[o++] = (char)(0xE0 | (c >> 12)); out[o++] = (char)(0x80 | ((c >> 6) & 63)); out[o++] = (char)(0x80 | (c & 63)); }
        else { if (o + 4 > cap) break; out[o++] = (char)(0xF0 | (c >> 18)); out[o++] = (char)(0x80 | ((c >> 12) & 63)); out[o++] = (char)(0x80 | ((c >> 6) & 63)); out[o++] = (char)(0x80 | (c & 63)); }
    }
    return o;
}

// ------------------------------------------------------------------ files: log, outbox, inbox
static wchar g_dir[520];          // folder of this DLL (the Lua mod folder)
static wchar g_log_path[520], g_out_path[520], g_in_path[520];
static u8 g_lock[64];             // CRITICAL_SECTION (40 bytes on x64)

static void append_file(const wchar *path, const char *s, u32 n) {
    void *h = CreateFileW(path, 4 /*FILE_APPEND_DATA*/, 3, 0, 4 /*OPEN_ALWAYS*/, 0x80, 0);
    if (h == (void *)(i64)-1) return;
    u32 w;
    WriteFile(h, s, n, &w, 0);
    CloseHandle(h);
}

typedef struct { char buf[1000]; u32 n; } line_t;
static void ls(line_t *l, const char *s) { while (*s && l->n < sizeof(l->buf) - 2) l->buf[l->n++] = *s++; }
static void lsn(line_t *l, const char *s, int n) { for (int i = 0; i < n && l->n < sizeof(l->buf) - 2; i++) l->buf[l->n++] = s[i]; }
static void lw(line_t *l, const wchar *s, int max) { l->n += (u32)to_utf8(s, max, l->buf + l->n, (int)(sizeof(l->buf) - 2 - l->n)); }
static void lhex(line_t *l, u64 v) {
    char t[19]; int i = 18; t[i] = 0;
    do { t[--i] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v && i > 2);
    t[--i] = 'x'; t[--i] = '0';
    ls(l, t + i);
}
static void ldec(line_t *l, i64 v) {
    char t[24]; int i = 23; t[i] = 0; int neg = v < 0; u64 u = neg ? (u64)(-v) : (u64)v;
    do { t[--i] = (char)('0' + u % 10); u /= 10; } while (u);
    if (neg) t[--i] = '-';
    ls(l, t + i);
}
static void lend(line_t *l) {                  // to the log
    l->buf[l->n++] = '\n';
    EnterCriticalSection(g_lock); append_file(g_log_path, l->buf, l->n); LeaveCriticalSection(g_lock);
    l->n = 0;
}
static void lend_to(line_t *l, const wchar *path) {
    l->buf[l->n++] = '\n';
    EnterCriticalSection(g_lock); append_file(path, l->buf, l->n); LeaveCriticalSection(g_lock);
    l->n = 0;
}
static void inbox(const char *s) { line_t l = {0}; ls(&l, s); lend_to(&l, g_in_path); }

// ------------------------------------------------------------------ game build check
static u8 *g_base;
typedef struct { const char *name; u32 rva; u8 bytes[16]; } sig_t;
enum { S_THUNK, S_SPAWN, S_FRO, S_SETUP, S_FINISH, S_FIELD, S_ROAD, S_GROW, S_HOVER, S_COUNT };
static sig_t g_sigs[S_COUNT] = {
    {"exec_writeUnitDebugLog", 0x4afd810, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x30,0x33}},
    {"spawnBuilding",          0x4ca1bb0, {0x40,0x53,0x55,0x56,0x57,0x41,0x56,0x41,0x57,0x48,0x81,0xec,0xe8,0x00,0x00,0x00}},
    {"findRegionAndOwner",     0x4d39b40, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x7c,0x24,0x10,0x55,0x48,0x8d,0x6c,0x24,0xa9}},
    {"SetupBuilding",          0x4d1a650, {0x4c,0x8b,0xdc,0x55,0x49,0x8d,0xab,0xe8,0xfd,0xff,0xff,0x48,0x81,0xec,0x10,0x03}},
    {"finishBuilding",         0x4d37620, {0x4c,0x8b,0xdc,0x55,0x49,0x8d,0xab,0xa8,0xfe,0xff,0xff,0x48,0x81,0xec,0x50,0x02}},
    {"commitField",            0x4b35700, {0x4c,0x8b,0xdc,0x55,0x57,0x49,0x8d,0xab,0x58,0xfe,0xff,0xff,0x48,0x81,0xec,0x98}},   // + 02 00 00
    {"commitRoad",             0x4b368c0, {0x40,0x55,0x53,0x56,0x57,0x41,0x57,0x48,0x8d,0xac,0x24,0x00,0xff,0xff,0xff,0x48}},   // + 81 ec
    {"TArray<FVector>::ResizeGrow", 0x10c2af0, {0x48,0x89,0x5c,0x24,0x08,0x48,0x89,0x74,0x24,0x10,0x57,0x48,0x83,0xec,0x30,0x48}},
    {"setHoveredBuilding",     0x4b6ef70, {0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x20,0x48,0x8b,0x81,0x10,0x07,0x00}},   // reads pawn+0x710
};

static int check_build(void) {
    line_t l = {0};
    int ok = 1;
    for (int i = 0; i < S_COUNT; i++) {
        u8 *p = g_base + g_sigs[i].rva;
        int m = 1;
        for (int k = 0; k < 16; k++) if (p[k] != g_sigs[i].bytes[k]) m = 0;
        ls(&l, "check "); ls(&l, g_sigs[i].name); ls(&l, m ? " ok" : " MISMATCH"); lend(&l);
        ok &= m;
    }
    u8 *sb = g_base + g_sigs[S_SETUP].rva;
    if (sb[16] != 0x00 || sb[17] != 0x00) { ls(&l, "check SetupBuilding tail MISMATCH"); lend(&l); ok = 0; }
    u8 *cf = g_base + g_sigs[S_FIELD].rva;
    if (cf[16] != 0x02 || cf[17] != 0x00 || cf[18] != 0x00) { ls(&l, "check commitField tail MISMATCH"); lend(&l); ok = 0; }
    u8 *cr = g_base + g_sigs[S_ROAD].rva;
    if (cr[16] != 0x81 || cr[17] != 0xec) { ls(&l, "check commitRoad tail MISMATCH"); lend(&l); ok = 0; }
    return ok;
}

// ------------------------------------------------------------------ game calls
typedef void *(*spawn_fn)(void *engine, int btype, double *loc, double *rot);
typedef void (*fro_fn)(void *building, void *region);
typedef void (*setup_fn)(void *building);
typedef void (*finish_fn)(void *building, void *arg);

static int g_ready;
static int g_in_cmd;                          // set while we apply a remote command (no echo)

// ------------------------------------------------------------------ command parsing
typedef struct { wchar *data; int num; int max; } fstring_t;

static const wchar *skip_ws(const wchar *s) { while (*s == ' ') s++; return s; }
static const wchar *word(const wchar *s, const char *w) {
    s = skip_ws(s);
    while (*w) { if (*s != (wchar)*w) return 0; s++; w++; }
    return (*s == ' ' || *s == 0) ? s : 0;
}
static const wchar *parse_hex(const wchar *s, u64 *out) {
    s = skip_ws(s);
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    u64 v = 0; int any = 0;
    for (;; s++) {
        wchar c = *s; int d;
        if (c >= '0' && c <= '9') d = c - '0'; else if (c >= 'a' && c <= 'f') d = c - 'a' + 10; else if (c >= 'A' && c <= 'F') d = c - 'A' + 10; else break;
        v = v * 16 + (u64)d; any = 1;
    }
    *out = v;
    return any ? s : 0;
}
static const wchar *parse_num(const wchar *s, double *out) {
    s = skip_ws(s);
    int neg = 0; if (*s == '-') { neg = 1; s++; }
    double v = 0; int any = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; any = 1; }
    if (*s == '.') { s++; double f = 0.1; while (*s >= '0' && *s <= '9') { v += (*s - '0') * f; f *= 0.1; s++; any = 1; } }
    *out = neg ? -v : v;
    return any ? s : 0;
}
// next space-separated token into an ASCII buffer
static const wchar *parse_tok(const wchar *s, char *out, int cap) {
    s = skip_ws(s);
    int n = 0;
    while (*s && *s != ' ' && n < cap - 1) { out[n++] = (char)(*s < 128 ? *s : '_'); s++; }
    out[n] = 0;
    return n ? s : 0;
}

// ------------------------------------------------------------------ hooks
// Each hooked function starts with position-independent instructions; we copy whole
// instructions (STOLEN bytes) to a trampoline and jump back after them.
static int g_in_commit;                      // inside a player's commitField/commitRoad (not a replay)

static void write_abs_jmp(u8 *p, u64 target) {        // jmp qword ptr [rip+0]; dq target  (14 bytes)
    p[0] = 0xFF; p[1] = 0x25; p[2] = p[3] = p[4] = p[5] = 0;
    for (int i = 0; i < 8; i++) p[6 + i] = (u8)(target >> (8 * i));
}

static void *install_hook(int sig, int stolen, void *hook) {
    u8 *fn = g_base + g_sigs[sig].rva;
    u8 *tr = (u8 *)VirtualAlloc(0, 64, 0x3000, 0x40);
    if (!tr) return 0;
    for (int i = 0; i < stolen; i++) tr[i] = fn[i];
    write_abs_jmp(tr + stolen, (u64)(fn + stolen));
    u32 old;
    if (!VirtualProtect(fn, 14, 0x40, &old)) return 0;
    write_abs_jmp(fn, (u64)hook);
    VirtualProtect(fn, 14, old, &old);
    FlushInstructionCache(GetCurrentProcess(), fn, 14);
    return tr;
}

// SetupBuilding: report every building set up
static setup_fn g_setup_orig;
static void report_building(void *b) {
    line_t l = {0};
    ls(&l, "setup "); lhex(&l, (u64)b);
    ls(&l, " "); ldec(&l, *(int *)((u8 *)b + B_ID));
    ls(&l, " "); ldec(&l, *(int *)((u8 *)b + B_TYPE));
    ls(&l, g_in_cmd ? " remote" : (g_in_commit == 2 ? " road" : (g_in_commit ? " field" : " local")));
    lend_to(&l, g_out_path);
}
// a building made by a player's commitField (field, pasture, market, residential plot): dump the
// state commitField gave it, before SetupBuilding uses it (B_* offsets above), plus two blocks of
// residential plot geometry (doubles) that commitField copies in
#define FB_G1 0x938
#define FB_G1N 0x30
#define FB_G2 0xa60
#define FB_G2N 0xc0
static struct { char buf[24000]; u32 n; } g_big;
static void big_s(const char *s) { while (*s && g_big.n < sizeof(g_big.buf) - 2) g_big.buf[g_big.n++] = *s++; }
static void big_i(i64 v) { line_t t = {0}; ldec(&t, v); t.buf[t.n] = 0; big_s(t.buf); }
static void big_pts(u8 *arr) {
    u8 *data = *(u8 **)arr; int num = *(int *)(arr + 8);
    if (num > 400) num = 400;
    big_s(" "); big_i(num);
    for (int i = 0; i < num; i++) {
        double *v = (double *)(data + (u64)i * 0x18);
        for (int k = 0; k < 3; k++) { big_s(" "); big_i((i64)(v[k] * 10.0)); }
    }
}
static void big_hex(u8 *p, int n) {
    big_s(" ");
    for (int i = 0; i < n && g_big.n < sizeof(g_big.buf) - 3; i++) {
        g_big.buf[g_big.n++] = "0123456789abcdef"[p[i] >> 4];
        g_big.buf[g_big.n++] = "0123456789abcdef"[p[i] & 15];
    }
}
static void dump_field(void *b) {
    u8 *p = (u8 *)b;
    g_big.n = 0;
    big_s("fielddata 0x"); { line_t t = {0}; lhex(&t, (u64)b); t.buf[t.n] = 0; big_s(t.buf + 2); }
    big_s(" "); big_i(*(int *)(p + B_WORKERS)); big_s(" "); big_i(p[B_FLAG]); big_s(" "); big_i(p[B_CLOCKWISE]);
    big_s(" P"); big_pts(p + B_FIELDPTS);
    big_s(" B"); big_pts(p + B_BORDER);
    big_s(" H"); big_hex(p + FB_G1, FB_G1N); big_hex(p + FB_G2, FB_G2N);
    g_big.buf[g_big.n++] = '\n';
    EnterCriticalSection(g_lock); append_file(g_out_path, g_big.buf, g_big.n); LeaveCriticalSection(g_lock);
}
static void hook_setup(void *b) {
    // any building that arrives with a shape (player fields/plots, AI plots): send its shape too
    if (b && !g_in_cmd && g_in_commit != 2 && (g_in_commit || *(int *)((u8 *)b + B_BORDER + 8) > 0)) dump_field(b);
    g_setup_orig(b);
    if (b) report_building(b);
}

// a TArray<FVector> (data, num) as " n x y z x y z ..."
static void put_points(line_t *l, u8 *data, int num, int stride, int off) {
    ls(l, " "); ldec(l, num);
    for (int i = 0; i < num; i++) {
        double *v = (double *)(data + (u64)i * (u64)stride + (u64)off);
        for (int k = 0; k < 3; k++) { ls(l, " "); ldec(l, (i64)(v[k] * 10.0)); }   // tenths of a unit
    }
}

// commitField(pawn): the player's drawn area (P_* offsets above), before the game consumes it.
// commitField and commitRoad return the object they made (the caller uses it): pass it through.
typedef void *(*pawn_fn)(void *pawn);
static pawn_fn g_field_orig, g_road_orig;
static void *hook_field(void *pawn) {
    if (!g_in_cmd && pawn) {
        u8 *p = (u8 *)pawn;
        line_t l = {0};
        ls(&l, "field "); lhex(&l, (u64)pawn);
        ls(&l, " "); ldec(&l, p[P_PLOTTYPE]); ls(&l, " "); ldec(&l, p[P_ISMARKET]); ls(&l, " "); ldec(&l, p[P_ISEXT]);
        ls(&l, " "); ldec(&l, *(int *)(p + P_WORKERS)); ls(&l, " "); ldec(&l, p[P_CLOSED]);
        int n = *(int *)(p + P_FIELDPTS + 8);
        if (n > 60) n = 60;
        put_points(&l, *(u8 **)(p + P_FIELDPTS), n, 0x38, 0x10);
        lend_to(&l, g_out_path);
        g_in_commit = 1;
    }
    void *made = g_field_orig(pawn);
    g_in_commit = 0;
    return made;
}
// commitRoad(pawn): roadPoints (FVector) and roadStartPos on the pawn.
// A successful commit empties roadPoints; a refused one leaves them. Report only successes.
static line_t g_road_line;
static void *hook_road(void *pawn) {
    int capture = (!g_in_cmd && pawn);
    if (capture) {
        u8 *p = (u8 *)pawn;
        g_road_line.n = 0;
        ls(&g_road_line, "road "); lhex(&g_road_line, (u64)pawn);
        int n = *(int *)(p + P_ROADPTS + 8);
        if (n > 60) n = 60;
        put_points(&g_road_line, p + P_ROADSTART, 1, 0x18, 0);
        put_points(&g_road_line, *(u8 **)(p + P_ROADPTS), n, 0x18, 0);
        g_in_commit = 2;                             // buildings made by a road commit: the replay remakes them
    }
    int before = pawn ? *(int *)((u8 *)pawn + P_ROADPTS + 8) : 0;
    void *made = g_road_orig(pawn);
    g_in_commit = 0;
    if (capture && before > 0 && *(int *)((u8 *)pawn + P_ROADPTS + 8) == 0) lend_to(&g_road_line, g_out_path);
    return made;
}

static int install_hooks(void) {
    g_setup_orig = (setup_fn)install_hook(S_SETUP, 18, (void *)&hook_setup);
    g_field_orig = (pawn_fn)install_hook(S_FIELD, 19, (void *)&hook_field);
    g_road_orig = (pawn_fn)install_hook(S_ROAD, 15, (void *)&hook_road);  // push x5 + lea rbp
    return g_setup_orig && g_field_orig && g_road_orig;
}

// ------------------------------------------------------------------ commands: game
// build <btype> <x> <y> <z> <yaw> <engineHex> <regionHex>   (a remote fact: reported as "remote")
// buildlocal ...same...                                    (test bot: reported as "local", like a player's)
static __declspec(noinline) void cmd_build(const wchar *s, int remote) {
    line_t l = {0};
    double t, x, y, z, yaw; u64 eng, reg;
    if (!(s = parse_num(s, &t)) || !(s = parse_num(s, &x)) || !(s = parse_num(s, &y)) || !(s = parse_num(s, &z)) ||
        !(s = parse_num(s, &yaw)) || !(s = parse_hex(s, &eng)) || !(s = parse_hex(s, &reg))) {
        ls(&l, "build: bad arguments"); lend(&l); return;
    }
    if (!eng) { ls(&l, "build: no engine"); lend(&l); return; }
    double loc[3] = {x, y, z};
    double rot[3] = {0.0, yaw, 0.0};           // FRotator: Pitch, Yaw, Roll
    g_in_cmd = remote;
    void *b = ((spawn_fn)(g_base + g_sigs[S_SPAWN].rva))((void *)eng, (int)t, loc, rot);
    if (b) {
        if (reg) ((fro_fn)(g_base + g_sigs[S_FRO].rva))(b, (void *)reg);
        ((setup_fn)(g_base + g_sigs[S_SETUP].rva))(b);
        ((finish_fn)(g_base + g_sigs[S_FINISH].rva))(b, (u8 *)b + B_TRIANG);
    }
    g_in_cmd = 0;
    ls(&l, "build: "); lhex(&l, (u64)b); ls(&l, " type "); ldec(&l, (i64)t); lend(&l);
}

// fieldbuild <type> <x> <y> <z> <yaw> <engineHex> <regionHex> <workers> <flag> <clockwise>
//            P <n> <xyz in tenths>... B <n> <xyz>... H <hex 0x30> <hex 0xc0>
typedef void (*grow_fn)(void *arr, int old_num);
static const wchar *parse_int(const wchar *s, i64 *out) { double d; s = parse_num(s, &d); *out = (i64)d; return s; }
static const wchar *fill_points(const wchar *s, u8 *arr) {
    i64 n;
    if (!(s = parse_int(s, &n)) || n < 0 || n > 400) return 0;
    grow_fn grow = (grow_fn)(g_base + g_sigs[S_GROW].rva);
    for (i64 i = 0; i < n; i++) {
        i64 c[3];
        for (int k = 0; k < 3; k++) if (!(s = parse_int(s, &c[k]))) return 0;
        int old = *(int *)(arr + 8);
        *(int *)(arr + 8) = old + 1;
        if (*(u32 *)(arr + 12) < (u32)(old + 1)) grow(arr, old);
        double *v = (double *)(*(u8 **)arr + (u64)old * 0x18);
        v[0] = c[0] / 10.0; v[1] = c[1] / 10.0; v[2] = c[2] / 10.0;
    }
    return s;
}
static const wchar *fill_hex(const wchar *s, u8 *dst, int n) {
    s = skip_ws(s);
    for (int i = 0; i < n; i++) {
        int v = 0;
        for (int k = 0; k < 2; k++) {
            wchar c = *s++; int d;
            if (c >= '0' && c <= '9') d = c - '0'; else if (c >= 'a' && c <= 'f') d = c - 'a' + 10; else return 0;
            v = v * 16 + d;
        }
        dst[i] = (u8)v;
    }
    return s;
}
static __declspec(noinline) void cmd_fieldbuild(const wchar *s) {
    line_t l = {0};
    double t, x, y, z, yaw; u64 eng, reg; i64 workers, flag, cw;
    if (!(s = parse_num(s, &t)) || !(s = parse_num(s, &x)) || !(s = parse_num(s, &y)) || !(s = parse_num(s, &z)) ||
        !(s = parse_num(s, &yaw)) || !(s = parse_hex(s, &eng)) || !(s = parse_hex(s, &reg)) ||
        !(s = parse_int(s, &workers)) || !(s = parse_int(s, &flag)) || !(s = parse_int(s, &cw)) || !eng) {
        ls(&l, "fieldbuild: bad header"); lend(&l); return;
    }
    double loc[3] = {x, y, z};
    double rot[3] = {0.0, yaw, 0.0};
    g_in_cmd = 1;
    u8 *b = (u8 *)((spawn_fn)(g_base + g_sigs[S_SPAWN].rva))((void *)eng, (int)t, loc, rot);
    if (!b) { g_in_cmd = 0; ls(&l, "fieldbuild: spawn failed"); lend(&l); return; }
    const wchar *r = word(s, "P");
    if (r) r = fill_points(r, b + B_FIELDPTS);
    if (r) r = word(r, "B");
    if (r) r = fill_points(r, b + B_BORDER);
    if (r) r = word(r, "H");
    if (r) r = fill_hex(r, b + FB_G1, FB_G1N);
    if (r) r = fill_hex(r, b + FB_G2, FB_G2N);
    if (!r) { ls(&l, "fieldbuild: bad payload (building kept, shape may be partial)"); lend(&l); }
    *(int *)(b + B_WORKERS) = (int)workers;
    b[B_FLAG] = (u8)flag;
    b[B_CLOCKWISE] = (u8)cw;
    if (reg) ((fro_fn)(g_base + g_sigs[S_FRO].rva))(b, (void *)reg);
    ((setup_fn)(g_base + g_sigs[S_SETUP].rva))(b);
    g_in_cmd = 0;
    ls(&l, "fieldbuild: "); lhex(&l, (u64)b); ls(&l, " type "); ldec(&l, (i64)t);
    ls(&l, " points "); ldec(&l, *(int *)(b + B_FIELDPTS + 8)); ls(&l, " border "); ldec(&l, *(int *)(b + B_BORDER + 8)); lend(&l);
}

// testfield <same as fieldbuild>: the lab bot's stand-in for a player's commitField. Same build,
// but inside a "player commit" so the capture path runs exactly as for a real field.
static __declspec(noinline) void cmd_testfield(const wchar *s) {
    int saved = g_in_cmd;
    g_in_commit = 1;
    // build without the remote flag: the SetupBuilding hook then dumps it like a player's field
    double t, x, y, z, yaw; u64 eng, reg; i64 workers, flag, cw;
    line_t l = {0};
    if (!(s = parse_num(s, &t)) || !(s = parse_num(s, &x)) || !(s = parse_num(s, &y)) || !(s = parse_num(s, &z)) ||
        !(s = parse_num(s, &yaw)) || !(s = parse_hex(s, &eng)) || !(s = parse_hex(s, &reg)) ||
        !(s = parse_int(s, &workers)) || !(s = parse_int(s, &flag)) || !(s = parse_int(s, &cw)) || !eng) {
        g_in_commit = 0; ls(&l, "testfield: bad header"); lend(&l); return;
    }
    double loc[3] = {x, y, z};
    double rot[3] = {0.0, yaw, 0.0};
    g_in_cmd = 0;
    u8 *b = (u8 *)((spawn_fn)(g_base + g_sigs[S_SPAWN].rva))((void *)eng, (int)t, loc, rot);
    if (b) {
        const wchar *r = word(s, "P");
        if (r) r = fill_points(r, b + B_FIELDPTS);
        if (r) r = word(r, "B");
        if (r) r = fill_points(r, b + B_BORDER);
        *(int *)(b + B_WORKERS) = (int)workers; b[B_FLAG] = (u8)flag; b[B_CLOCKWISE] = (u8)cw;
        if (reg) ((fro_fn)(g_base + g_sigs[S_FRO].rva))(b, (void *)reg);
        ((setup_fn)(g_base + g_sigs[S_SETUP].rva))(b);
    }
    g_in_commit = 0;
    g_in_cmd = saved;
    ls(&l, "testfield: "); lhex(&l, (u64)b); lend(&l);
}

// cursor <pawnHex> <x> <y> <z>: the pawn's ground point under the cursor (P_CURSOR, FVector),
// which fieldAddPoint uses; lets a replay place a passive lord's field points
static __declspec(noinline) void cmd_cursor(const wchar *s) {
    line_t l = {0};
    u64 pawn; double x, y, z;
    if (!(s = parse_hex(s, &pawn)) || !(s = parse_num(s, &x)) || !(s = parse_num(s, &y)) || !(s = parse_num(s, &z)) || !pawn) {
        ls(&l, "cursor: bad arguments"); lend(&l); return;
    }
    double *v = (double *)((u8 *)pawn + P_CURSOR);
    v[0] = x; v[1] = y; v[2] = z;
}

// peek <buildingHex>: debug - the building's B_MARKERS component and whether it still looks like a
// live object (vtable inside the exe image). Reads only committed, readable memory.
static u64 g_image_size;
static int readable(const void *p, u64 n) {
    u8 mbi[48];                                  // MEMORY_BASIC_INFORMATION (x64)
    if (!p || VirtualQuery(p, mbi, sizeof(mbi)) != sizeof(mbi)) return 0;
    u64 base = *(u64 *)mbi, size = *(u64 *)(mbi + 24);
    u32 state = *(u32 *)(mbi + 32), prot = *(u32 *)(mbi + 36);
    if (state != 0x1000 /*MEM_COMMIT*/ || prot == 0 || (prot & 0x101) /*NOACCESS|GUARD*/) return 0;
    return (u64)p + n <= base + size;
}
static int in_image(u64 v) { return v >= (u64)g_base && v < (u64)g_base + g_image_size; }
static __declspec(noinline) void cmd_peek(const wchar *s) {
    line_t l = {0};
    u64 b;
    if (!parse_hex(s, &b) || !readable((void *)b, B_MARKERS + 8)) { ls(&l, "peek: bad address"); lend(&l); return; }
    u64 c = *(u64 *)(b + B_MARKERS);
    ls(&l, "peek "); lhex(&l, b); ls(&l, in_image(*(u64 *)b) ? " alive" : " DEAD");
    ls(&l, " type "); ldec(&l, *(int *)(b + B_TYPE)); ls(&l, " markers "); lhex(&l, c);
    if (c && !readable((void *)c, 0x10)) ls(&l, " UNMAPPED");
    else if (c) { ls(&l, in_image(*(u64 *)c) ? " ok" : " FREED"); ls(&l, " flags "); lhex(&l, *(u32 *)(c + 8)); }
    lend(&l);
}

// hover <pawnHex> <buildingHex|0>: lab - what the cursor does when it moves onto a building (or off
// every building): the pawn's hovered building changes, hiding the old one's markers, showing the new one's
typedef void (*hover_fn)(void *pawn, void *building);
static __declspec(noinline) void cmd_hover(const wchar *s) {
    line_t l = {0};
    u64 pawn, b;
    if (!(s = parse_hex(s, &pawn)) || !parse_hex(s, &b) || !pawn) { ls(&l, "hover: bad arguments"); lend(&l); return; }
    ((hover_fn)(g_base + g_sigs[S_HOVER].rva))((void *)pawn, (void *)b);
}

// srand <seed>: seed the C runtime generator the game's FMath::Rand uses
static __declspec(noinline) void cmd_srand(const wchar *s) {
    line_t l = {0};
    double seed;
    if (!parse_num(s, &seed)) { ls(&l, "srand: bad argument"); lend(&l); return; }
    static const wchar ucrt[] = {'u','c','r','t','b','a','s','e','.','d','l','l',0};
    void *m = GetModuleHandleW(ucrt);
    void (*srand_fn)(unsigned) = m ? (void (*)(unsigned))GetProcAddress(m, "srand") : 0;
    if (!srand_fn) { ls(&l, "srand: ucrtbase srand not found"); lend(&l); return; }
    srand_fn((unsigned)seed);
    ls(&l, "srand: seeded "); ldec(&l, (i64)seed); lend(&l);
}

// ------------------------------------------------------------------ network
static volatile SOCKET g_sock = INVALID_SOCKET;   // the peer connection
static volatile SOCKET g_listen = INVALID_SOCKET;
static volatile int g_net_role;                   // 0 none, 1 host, 2 join
static u16 g_port;
static char g_join_ip[64];
static wchar g_saves_dir[520];
static u8 g_send_lock[64];

static int send_all(SOCKET s, const char *p, int n) {
    while (n > 0) {
        int k = send(s, p, n, 0);
        if (k <= 0) return 0;
        p += k; n -= k;
    }
    return 1;
}

static int safe_name(const char *n) {
    if (!*n) return 0;
    for (const char *p = n; *p; p++) {
        char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) return 0;
    }
    return n[0] != '.';
}
// the protocol only ever transfers the shared world: coop_world.sav, coop_world_descr.sav, coop_world_coat_N.png
static int world_file(const char *n) {
    const char *w = "coop_world";
    while (*w) if (*n++ != *w++) return 0;
    return 1;
}

// receive loop: lines -> inbox "MSG <line>", "FILE <name> <len>\n<bytes>" -> saves dir
// one connection at a time, so the receive buffers can be static
static char r_buf[65536], r_line[8192];
static wchar r_fpath[600], r_ftmp[600];
static __declspec(noinline) void recv_loop(SOCKET s) {
    char *buf = r_buf, *linebuf = r_line; int ln = 0;
    void *fh = 0; i64 file_left = 0; char fname[128] = {0};
    wchar *fpath = r_fpath, *ftmp = r_ftmp;
    for (;;) {
        int k = recv(s, buf, 65536, 0);
        if (k <= 0) break;
        int i = 0;
        while (i < k) {
            if (file_left > 0) {
                int take = (int)((k - i) < file_left ? (k - i) : file_left);
                u32 w; WriteFile(fh, buf + i, (u32)take, &w, 0);
                i += take; file_left -= take;
                if (file_left == 0) {
                    CloseHandle(fh); fh = 0;
                    MoveFileExW(ftmp, fpath, 1 /*MOVEFILE_REPLACE_EXISTING*/);
                    line_t l = {0}; ls(&l, "FILE_DONE "); ls(&l, fname); lend_to(&l, g_in_path);
                }
                continue;
            }
            char c = buf[i++];
            if (c == '\n') {
                linebuf[ln] = 0;
                if (ln > 5 && linebuf[0] == 'F' && linebuf[1] == 'I' && linebuf[2] == 'L' && linebuf[3] == 'E' && linebuf[4] == ' ') {
                    // FILE <name> <len>
                    int p = 5, q = 0;
                    while (linebuf[p] && linebuf[p] != ' ' && q < 127) fname[q++] = linebuf[p++];
                    fname[q] = 0;
                    i64 len = 0;
                    while (linebuf[p] == ' ') p++;
                    while (linebuf[p] >= '0' && linebuf[p] <= '9') len = len * 10 + (linebuf[p++] - '0');
                    // only a guest receives files, and only the world (never overwrite other saves)
                    if (g_net_role != 2 || !safe_name(fname) || !world_file(fname) || len <= 0 || len > 512ll * 1024 * 1024) {
                        inbox("NET error bad_file_header");
                        closesocket(s);
                        return;
                    }
                    fpath[0] = 0; wcat(fpath, 600, g_saves_dir); wcat_a(fpath, 600, fname);
                    ftmp[0] = 0; wcat(ftmp, 600, fpath); wcat_a(ftmp, 600, ".part");
                    fh = CreateFileW(ftmp, 0x40000000 /*GENERIC_WRITE*/, 0, 0, 2 /*CREATE_ALWAYS*/, 0x80, 0);
                    if (fh == (void *)(i64)-1) { inbox("NET error cannot_write_file"); closesocket(s); return; }
                    file_left = len;
                } else {
                    line_t l = {0}; ls(&l, "MSG "); lsn(&l, linebuf, ln); lend_to(&l, g_in_path);
                }
                ln = 0;
            } else if (c != '\r') {
                if (ln < 8191) linebuf[ln++] = c;
            }
        }
    }
    if (fh) { CloseHandle(fh); DeleteFileW(ftmp); }
}

static void set_nodelay(SOCKET s) { int one = 1; setsockopt(s, 6 /*IPPROTO_TCP*/, 1 /*TCP_NODELAY*/, (const char *)&one, 4); }

static u32 __stdcall host_thread(void *arg) {
    (void)arg;
    SOCKET ls_ = socket(2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 6);
    int one = 1; setsockopt(ls_, 0xffff /*SOL_SOCKET*/, 4 /*SO_REUSEADDR*/, (const char *)&one, 4);
    sockaddr_in_t a = {0}; a.family = 2; a.port = htons(g_port); a.addr = 0;   // INADDR_ANY
    if (bind(ls_, &a, sizeof(a)) != 0 || listen(ls_, 1) != 0) {
        line_t l = {0}; ls(&l, "NET error listen "); ldec(&l, WSAGetLastError()); lend_to(&l, g_in_path);
        closesocket(ls_); return 0;
    }
    g_listen = ls_;
    { line_t l = {0}; ls(&l, "NET listening "); ldec(&l, g_port); lend_to(&l, g_in_path); }
    for (;;) {
        SOCKET c = accept(ls_, 0, 0);
        if (c == INVALID_SOCKET) break;
        if (g_sock != INVALID_SOCKET) {                 // one guest at a time for now
            send_all(c, "REFUSE full\n", 12);
            closesocket(c);
            continue;
        }
        set_nodelay(c);
        g_sock = c;
        inbox("NET connected");
        recv_loop(c);
        closesocket(c);
        g_sock = INVALID_SOCKET;
        inbox("NET disconnected");
    }
    return 0;
}

static u32 __stdcall join_thread(void *arg) {
    (void)arg;
    for (int attempt = 0; attempt < 120; attempt++) {
        SOCKET s = socket(2, 1, 6);
        sockaddr_in_t a = {0}; a.family = 2; a.port = htons(g_port); a.addr = inet_addr(g_join_ip);
        if (connect(s, &a, sizeof(a)) == 0) {
            set_nodelay(s);
            g_sock = s;
            inbox("NET connected");
            recv_loop(s);
            closesocket(s);
            g_sock = INVALID_SOCKET;
            inbox("NET disconnected");
            return 0;
        }
        closesocket(s);
        if (attempt == 0) inbox("NET connecting");
        Sleep(1000);
    }
    inbox("NET error connect_timeout");
    return 0;
}

static int g_wsa_ok;
static int net_init(void) {
    if (g_wsa_ok) return 1;
    static u8 wsadata[512];
    if (WSAStartup(0x0202, wsadata) != 0) return 0;
    g_wsa_ok = 1;
    return 1;
}

// net host <port> | net join <ip> <port> | net send <text> | net sendfile <path> <name>
static __declspec(noinline) void cmd_net(const wchar *s, int n_total, const wchar *start) {
    line_t l = {0};
    const wchar *r;
    if ((r = word(s, "host"))) {
        double port;
        if (g_net_role || !parse_num(r, &port) || !net_init()) { ls(&l, "net host: refused"); lend(&l); return; }
        g_port = (u16)port; g_net_role = 1;
        CreateThread(0, 0, host_thread, 0, 0, 0);
        ls(&l, "net host: port "); ldec(&l, g_port); lend(&l);
    } else if ((r = word(s, "join"))) {
        double port;
        if (g_net_role || !(r = parse_tok(r, g_join_ip, sizeof(g_join_ip))) || !parse_num(r, &port) || !net_init()) { ls(&l, "net join: refused"); lend(&l); return; }
        g_port = (u16)port; g_net_role = 2;
        CreateThread(0, 0, join_thread, 0, 0, 0);
        ls(&l, "net join: "); ls(&l, g_join_ip); ls(&l, " "); ldec(&l, g_port); lend(&l);
    } else if ((r = word(s, "send"))) {
        r = skip_ws(r);
        SOCKET sk = g_sock;
        if (sk == INVALID_SOCKET) { ls(&l, "net send: not connected"); lend(&l); return; }
        static char out[16384];
        int n = to_utf8(r, n_total - (int)(r - start), out, sizeof(out) - 1);
        out[n++] = '\n';
        EnterCriticalSection(g_send_lock);
        int ok = send_all(sk, out, n);
        LeaveCriticalSection(g_send_lock);
        if (!ok) { ls(&l, "net send: failed"); lend(&l); }
    } else if ((r = word(s, "sendfile"))) {
        // sendfile <name>: a file of the game's save folder
        char name[128];
        if (!parse_tok(r, name, sizeof(name)) || !safe_name(name)) { ls(&l, "net sendfile: bad name"); lend(&l); return; }
        static wchar path[600];
        path[0] = 0; wcat(path, 600, g_saves_dir); wcat_a(path, 600, name);
        int pn = wlen(path);
        SOCKET sk = g_sock;
        if (sk == INVALID_SOCKET) { ls(&l, "net sendfile: not connected"); lend(&l); return; }
        void *h = CreateFileW(path, 0x80000000 /*GENERIC_READ*/, 1, 0, 3 /*OPEN_EXISTING*/, 0x80, 0);
        if (h == (void *)(i64)-1) { ls(&l, "net sendfile: cannot open "); lw(&l, path, pn); lend(&l); return; }
        i64 size = 0; GetFileSizeEx(h, &size);
        static line_t hdr; hdr.n = 0; ls(&hdr, "FILE "); ls(&hdr, name); ls(&hdr, " "); ldec(&hdr, size); hdr.buf[hdr.n++] = '\n';
        EnterCriticalSection(g_send_lock);
        int ok = send_all(sk, hdr.buf, (int)hdr.n);
        static char chunk[65536];
        i64 left = size;
        while (ok && left > 0) {
            u32 got = 0;
            if (!ReadFile(h, chunk, sizeof(chunk), &got, 0) || got == 0) { ok = 0; break; }
            ok = send_all(sk, chunk, (int)got);
            left -= got;
        }
        LeaveCriticalSection(g_send_lock);
        CloseHandle(h);
        ls(&l, ok ? "net sendfile: sent " : "net sendfile: FAILED "); ls(&l, name); ls(&l, " "); ldec(&l, size); lend(&l);
    } else {
        ls(&l, "net: unknown"); lend(&l);
    }
}

// ------------------------------------------------------------------ command entry
// replacement for exec_writeUnitDebugLog: void exec(UObject* ctx, FFrame* stack, void* result)
static void __fastcall on_command(void *ctx, u8 *stack, void *result) {
    (void)ctx; (void)result;
    u8 *locals = *(u8 **)(stack + 0x28);      // FFrame::Locals: the parameter block
    fstring_t *arg = (fstring_t *)locals;     // the only parameter: FString newLogEntry
    if (!arg || !arg->data || arg->num <= 0) return;
    const wchar *s = arg->data, *rest;
    int n = arg->num - 1;                     // Num counts the terminator
    if ((rest = word(s, "net"))) { cmd_net(rest, n, s); return; }
    line_t l = {0};
    ls(&l, "cmd: "); lw(&l, s, n); lend(&l);
    if ((rest = word(s, "ping"))) { inbox("PONG " MOD_VERSION); }
    else if ((rest = word(s, "buildlocal"))) cmd_build(rest, 0);
    else if ((rest = word(s, "build"))) cmd_build(rest, 1);
    else if ((rest = word(s, "srand"))) cmd_srand(rest);
    else if ((rest = word(s, "peek"))) cmd_peek(rest);
    else if ((rest = word(s, "hover"))) cmd_hover(rest);
    else if ((rest = word(s, "cursor"))) cmd_cursor(rest);
    else if ((rest = word(s, "fieldbuild"))) cmd_fieldbuild(rest);
    else if ((rest = word(s, "testfield"))) cmd_testfield(rest);
    else if ((rest = word(s, "remote"))) { double v = 0; parse_num(rest, &v); g_in_cmd = v != 0; }
    else { ls(&l, "cmd: unknown"); lend(&l); }
}

static int patch_thunk(void) {
    u8 *p = g_base + g_sigs[S_THUNK].rva;
    u32 old;
    if (!VirtualProtect(p, 12, 0x40, &old)) return 0;
    u64 target = (u64)&on_command;
    p[0] = 0x48; p[1] = 0xB8;                 // mov rax, imm64
    for (int i = 0; i < 8; i++) p[2 + i] = (u8)(target >> (8 * i));
    p[10] = 0xFF; p[11] = 0xE0;               // jmp rax
    VirtualProtect(p, 12, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 12);
    return 1;
}

// ------------------------------------------------------------------ paths
static void path_from_env_or_dir(wchar *dst, const char *env, const char *file) {
    wchar var[64]; int i = 0;
    while (env[i] && i < 63) { var[i] = (wchar)env[i]; i++; }
    var[i] = 0;
    if (GetEnvironmentVariableW(var, dst, 519) > 0) return;
    dst[0] = 0; wcat(dst, 520, g_dir); wcat_a(dst, 520, "run\\"); wcat_a(dst, 520, file);
}

int __stdcall DllMain(void *inst, u32 reason, void *reserved) {
    (void)reserved;
    if (reason != 1 /*DLL_PROCESS_ATTACH*/ || g_ready) return 1;
    InitializeCriticalSection(g_lock);
    InitializeCriticalSection(g_send_lock);
    // the folder of this DLL
    GetModuleFileNameW(inst, g_dir, 519);
    int n = wlen(g_dir);
    while (n > 0 && g_dir[n - 1] != '\\' && g_dir[n - 1] != '/') n--;
    g_dir[n] = 0;
    { static wchar run[540]; run[0] = 0; wcat(run, 540, g_dir); wcat_a(run, 540, "run"); CreateDirectoryW(run, 0); }
    path_from_env_or_dir(g_log_path, "COOP_NATIVE_LOG", "native.log");
    path_from_env_or_dir(g_out_path, "COOP_NATIVE_OUT", "outbox.txt");
    path_from_env_or_dir(g_in_path, "COOP_NATIVE_IN", "inbox.txt");
    // the game's save folder (received worlds go there)
    static const wchar lad[] = {'L','O','C','A','L','A','P','P','D','A','T','A',0};
    if (GetEnvironmentVariableW(lad, g_saves_dir, 400) > 0) wcat_a(g_saves_dir, 520, "\\ManorLords\\Saved\\SaveGames\\");
    g_base = (u8 *)GetModuleHandleW(0);
    g_image_size = *(u32 *)(g_base + *(u32 *)(g_base + 0x3c) + 24 + 56);   // OptionalHeader.SizeOfImage
    line_t l = {0};
    ls(&l, "coopnative " MOD_VERSION " loaded, exe base "); lhex(&l, (u64)g_base); lend(&l);
    if (!check_build()) { ls(&l, "unknown game build: nothing installed"); lend(&l); inbox("NATIVE refused unknown_game_build"); return 1; }
    if (!patch_thunk()) { ls(&l, "VirtualProtect failed"); lend(&l); inbox("NATIVE refused patch_failed"); return 1; }
    g_ready = 1;
    ls(&l, "command channel installed"); lend(&l);
    if (install_hooks()) { ls(&l, "hooks installed (SetupBuilding, commitField, commitRoad)"); lend(&l); }
    else { ls(&l, "hooks FAILED"); lend(&l); }
    inbox("NATIVE ready " MOD_VERSION);
    return 1;
}
