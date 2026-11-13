/*
 * tools/lua_coverage/ccov.c · the line hook of the measured Lua coverage (dev tooling, not shipped).
 * Loaded by cov_init.lua through package.loadlib into a lua5.4 test process. It records, per source file under
 * Crimson-Police/, every line the Lua VM runs (LUA_MASKLINE), and dump(file, label) writes them as
 * "<source>\t<line>,<line>,...". Line level only: the not-taken side of an if with no else and the operands of a
 * short-circuit (a and b) are not measured. Built by tools/lua_coverage/run.sh (cc -O2 -shared -fPIC); it declares
 * the few Lua 5.4 API calls it needs itself, so no Lua headers are needed (the lua5.4 binary exports them).
 */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct lua_State lua_State;
typedef struct lua_Debug {   /* Lua 5.4 layout (lua.h) */
    int event;
    const char *name;
    const char *namewhat;
    const char *what;
    const char *source;
    size_t srclen;
    int currentline;
    int linedefined;
    int lastlinedefined;
    unsigned char nups;
    unsigned char nparams;
    char isvararg;
    char istailcall;
    unsigned short ftransfer;
    unsigned short ntransfer;
    char short_src[60];
    void *i_ci;
} lua_Debug;
typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);
typedef int (*lua_CFunction)(lua_State *L);
extern void lua_sethook(lua_State *L, lua_Hook f, int mask, int count);
extern int lua_getinfo(lua_State *L, const char *what, lua_Debug *ar);
extern const char *luaL_checklstring(lua_State *L, int arg, size_t *l);
extern void lua_createtable(lua_State *L, int narr, int nrec);
extern void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
extern void lua_setfield(lua_State *L, int idx, const char *k);

#define LUA_MASKLINE (1 << 2)
#define MAXLINE 40000
#define MAXFILES 4096

typedef struct Rec {
    char *src;
    unsigned char *lines;
} Rec;

static Rec recs[MAXFILES];
static int nrec = 0;
static const char *lastPtr = NULL;   /* the source string of the last line event (Lua interns it) */
static Rec *lastRec = NULL;
static int lastSkip = 0;

static void Hook(lua_State *L, lua_Debug *ar) {
    int line = ar->currentline;
    if (!lua_getinfo(L, "S", ar)) return;
    const char *s = ar->source;
    Rec *r = NULL;
    if (s == lastPtr) {
        if (lastSkip) return;
        if (lastRec && strcmp(lastRec->src, s) == 0) r = lastRec;
    }
    if (!r) {
        if (s[0] != '@' || !strstr(s, "Crimson-Police/")) {
            lastPtr = s;
            lastSkip = 1;
            return;
        }
        for (int i = 0; i < nrec; i++)
            if (strcmp(recs[i].src, s) == 0) {
                r = &recs[i];
                break;
            }
        if (!r) {
            if (nrec >= MAXFILES) return;
            r = &recs[nrec++];
            r->src = strdup(s);
            r->lines = calloc(MAXLINE, 1);
            if (!r->src || !r->lines) {
                nrec--;
                return;
            }
        }
        lastPtr = s;
        lastRec = r;
        lastSkip = 0;
    }
    if (line > 0 && line < MAXLINE) r->lines[line] = 1;
}

static int Start(lua_State *L) {
    lua_sethook(L, Hook, LUA_MASKLINE, 0);
    return 0;
}

static int Dump(lua_State *L) {
    const char *fn = luaL_checklstring(L, 1, NULL);
    const char *label = luaL_checklstring(L, 2, NULL);
    FILE *f = fopen(fn, "w");
    if (!f) return 0;
    fprintf(f, "#spec %s\n", label);
    for (int i = 0; i < nrec; i++) {
        int first = 1;
        fprintf(f, "%s\t", recs[i].src + 1);
        for (int l = 0; l < MAXLINE; l++)
            if (recs[i].lines[l]) {
                fprintf(f, first ? "%d" : ",%d", l);
                first = 0;
            }
        fputc('\n', f);
    }
    fclose(f);
    return 0;
}

int luaopen_ccov(lua_State *L) {
    lua_createtable(L, 0, 2);
    lua_pushcclosure(L, Start, 0);
    lua_setfield(L, -2, "start");
    lua_pushcclosure(L, Dump, 0);
    lua_setfield(L, -2, "dump");
    return 1;
}
