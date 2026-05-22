#ifndef USA_INI_H
#define USA_INI_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

void ini_read(const OEMCHAR *path, const OEMCHAR *title, const INITBL *tbl, UINT count);
void ini_write(const OEMCHAR *path, const OEMCHAR *title, const INITBL *tbl, UINT count);

#ifdef __cplusplus
}
#endif

#endif
