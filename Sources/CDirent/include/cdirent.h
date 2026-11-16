#ifndef CDIRENT_H
#define CDIRENT_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/// Object kinds (mirrors the subset of `enum vtype` Down cares about).
typedef enum {
    CDIRENT_OTHER = 0,
    CDIRENT_FILE = 1,
    CDIRENT_DIR = 2,
    CDIRENT_SYMLINK = 3,
} cdirent_kind;

/// One directory entry decoded from a getattrlistbulk(2) / getattrlist(2) buffer.
typedef struct {
    char name[1024];          // UTF-8, NUL terminated (APFS names are <= 255 UTF-8 bytes; HFS+ <= 765)
    uint32_t name_len;        // bytes, excluding NUL
    cdirent_kind kind;
    int32_t error;            // per-entry error (ATTR_CMN_ERROR); 0 on success
    uint64_t size;            // logical size for files / symlinks
    int64_t mtime_sec;
    int64_t mtime_nsec;
    int64_t crtime_sec;
    int64_t crtime_nsec;
    uint32_t flags;           // st_flags (UF_HIDDEN, ...)
    uint32_t mode;            // permission bits + type bits
    uint64_t file_id;         // inode number
    int32_t entry_count;      // directories only; -1 when unknown
} cdirent_entry;

/// Opaque bulk-enumeration context. Holds the syscall buffer and a cursor into it.
typedef struct cdirent_ctx cdirent_ctx;

/// Opens `path` as a directory (O_NOFOLLOW is NOT used so symlinked folders can be listed).
/// Returns NULL and sets *err (errno) on failure.
cdirent_ctx *cdirent_open(const char *path, int *err);

/// Decodes the next entry. Returns 1 on success, 0 at end of directory, -1 on error (*err = errno).
int cdirent_next(cdirent_ctx *ctx, cdirent_entry *out, int *err);

void cdirent_close(cdirent_ctx *ctx);

/// Single-path variant (no symlink following). Returns 0 on success or errno.
int cdirent_stat(const char *path, cdirent_entry *out);

#endif
