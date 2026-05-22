// Path / current-directory management for NP2kai's dosio layer.
// Modeled after np2kai/sdl/dosio.c. Extracted from np2_glue.c so that the
// path logic can be unit-tested in isolation (no NP2kai globals required).
//
// The shape: a static curpath[MAX_PATH] holds a base directory followed by a
// filename slot. curfilep points at the filename slot. file_getcd("FOO")
// writes "FOO" at curfilep and returns the whole curpath.

#include <string.h>
#include <stddef.h>
#include "np2_path.h"
#include <common/milstr.h>

#ifndef MAX_PATH
#define MAX_PATH 1024
#endif

static char curpath[MAX_PATH] = "./";
static char *curfilep = curpath + 2;

char *file_getname(const char *path) {
    char *p = (char *)path;
    char *ret = p;
    if (p == NULL) return NULL;
    while (*p) {
        if (*p == '/' || *p == '\\') ret = p + 1;
        p++;
    }
    return ret;
}

char *file_getcd(const char *path) {
    if (path) {
        milstr_ncpy(curfilep, path, (int)(sizeof(curpath) - (curfilep - curpath)));
    }
    return curpath;
}

void file_catname(char *path, const char *name, int maxlen) {
    if (!path || !name) return;
    while (maxlen > 0) {
        if (*path == '\0') break;
        path++;
        maxlen--;
    }
    milstr_ncpy(path, name, maxlen);
}

void file_setcd(const char *exepath) {
    if (!exepath) return;
    milstr_ncpy(curpath, exepath, sizeof(curpath));
    curfilep = file_getname(curpath);
}

void file_cutname(char *path) {
    if (!path) return;
    char *p = file_getname(path);
    *p = '\0';
}

// Returns the extension portion (after the last '.'). If there's no '.',
// returns a pointer to the terminating '\0' (matching the SDL/Win backends).
char *file_getext(const char *path) {
    const char *p;
    const char *q;
    if (!path) return NULL;
    p = file_getname(path);
    q = NULL;
    while (*p != '\0') {
        if (*p == '.') q = p + 1;
        p++;
    }
    if (q == NULL) q = p;
    return (char *)q;
}

// Set the directory in which NP2kai should look for ROMs, fonts, etc.
// Trailing '/' is enforced so file_getcd("X") produces "<dir>/X".
void np2_set_datadir(const char *dir) {
    if (!dir || !dir[0]) return;
    size_t n = strlen(dir);
    if (n + 2 >= sizeof(curpath)) return;
    memcpy(curpath, dir, n);
    if (curpath[n - 1] != '/') {
        curpath[n] = '/';
        n++;
    }
    curpath[n] = '\0';
    curfilep = curpath + n;
}

// Test-only accessor: returns the current internal path buffer.
const char *np2_path_debug_curpath(void) {
    return curpath;
}

// Test-only: reset state to defaults.
void np2_path_debug_reset(void) {
    curpath[0] = '.';
    curpath[1] = '/';
    curpath[2] = '\0';
    curfilep = curpath + 2;
}
