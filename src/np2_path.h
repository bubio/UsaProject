#ifndef UP_NP2_PATH_H
#define UP_NP2_PATH_H

#ifdef __cplusplus
extern "C" {
#endif

char *file_getname(const char *path);
char *file_getcd(const char *path);
void file_catname(char *path, const char *name, int maxlen);
void file_setcd(const char *exepath);
void file_cutname(char *path);
char *file_getext(const char *path);

void np2_set_datadir(const char *dir);

// Test-only accessors
const char *np2_path_debug_curpath(void);
void np2_path_debug_reset(void);

#ifdef __cplusplus
}
#endif

#endif
