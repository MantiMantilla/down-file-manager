#include "cdirent.h"

#include <sys/attr.h>
#include <sys/vnode.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define CDIRENT_BUFSIZE (256 * 1024)

struct cdirent_ctx {
    int fd;
    char *buf;
    char *cursor;
    int remaining;   // entries left in the current buffer
};

static struct attrlist make_attrlist(void) {
    struct attrlist al;
    memset(&al, 0, sizeof(al));
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS |
                    ATTR_CMN_FILEID;
    al.dirattr = ATTR_DIR_ENTRYCOUNT;
    al.fileattr = ATTR_FILE_DATALENGTH;
    return al;
}

static cdirent_kind kind_from_vtype(uint32_t t) {
    switch (t) {
        case VREG: return CDIRENT_FILE;
        case VDIR: return CDIRENT_DIR;
        case VLNK: return CDIRENT_SYMLINK;
        default: return CDIRENT_OTHER;
    }
}

/// Decodes one packed entry starting at `entry` (which begins with the uint32 length).
/// Field order follows getattrlist(2): RETURNED_ATTRS, ERROR, then common attrs by bit
/// order, then dir attrs, then file attrs. Only attributes present in `returned` are packed.
/// All reads go through memcpy because fields are only 4-byte aligned.
static void decode_entry(const char *entry, cdirent_entry *out) {
    memset(out, 0, sizeof(*out));
    out->entry_count = -1;

    const char *p = entry + sizeof(uint32_t);  // skip length
    attribute_set_t returned;
    memcpy(&returned, p, sizeof(returned));
    p += sizeof(returned);

    if (returned.commonattr & ATTR_CMN_ERROR) {
        uint32_t e; memcpy(&e, p, sizeof(e)); p += sizeof(e);
        out->error = (int32_t)e;
    }
    if (returned.commonattr & ATTR_CMN_NAME) {
        attrreference_t ref; memcpy(&ref, p, sizeof(ref));
        const char *name = p + ref.attr_dataoffset;
        size_t len = ref.attr_length > 0 ? ref.attr_length - 1 : 0;  // length includes NUL
        if (len >= sizeof(out->name)) len = sizeof(out->name) - 1;
        memcpy(out->name, name, len);
        out->name[len] = '\0';
        out->name_len = (uint32_t)len;
        p += sizeof(ref);
    }
    if (returned.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t t; memcpy(&t, p, sizeof(t)); p += sizeof(t);
        out->kind = kind_from_vtype(t);
    }
    if (returned.commonattr & ATTR_CMN_CRTIME) {
        struct timespec ts; memcpy(&ts, p, sizeof(ts)); p += sizeof(ts);
        out->crtime_sec = ts.tv_sec; out->crtime_nsec = ts.tv_nsec;
    }
    if (returned.commonattr & ATTR_CMN_MODTIME) {
        struct timespec ts; memcpy(&ts, p, sizeof(ts)); p += sizeof(ts);
        out->mtime_sec = ts.tv_sec; out->mtime_nsec = ts.tv_nsec;
    }
    if (returned.commonattr & ATTR_CMN_ACCESSMASK) {
        uint32_t m; memcpy(&m, p, sizeof(m)); p += sizeof(m);
        out->mode = m;
    }
    if (returned.commonattr & ATTR_CMN_FLAGS) {
        uint32_t f; memcpy(&f, p, sizeof(f)); p += sizeof(f);
        out->flags = f;
    }
    if (returned.commonattr & ATTR_CMN_FILEID) {
        uint64_t id; memcpy(&id, p, sizeof(id)); p += sizeof(id);
        out->file_id = id;
    }
    if (returned.dirattr & ATTR_DIR_ENTRYCOUNT) {
        uint32_t c; memcpy(&c, p, sizeof(c)); p += sizeof(c);
        out->entry_count = (int32_t)c;
    }
    if (returned.fileattr & ATTR_FILE_DATALENGTH) {
        off_t len; memcpy(&len, p, sizeof(len)); p += sizeof(len);
        out->size = (uint64_t)len;
    }
}

cdirent_ctx *cdirent_open(const char *path, int *err) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { *err = errno; return NULL; }
    cdirent_ctx *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) { close(fd); *err = ENOMEM; return NULL; }
    ctx->buf = malloc(CDIRENT_BUFSIZE);
    if (!ctx->buf) { close(fd); free(ctx); *err = ENOMEM; return NULL; }
    ctx->fd = fd;
    return ctx;
}

int cdirent_next(cdirent_ctx *ctx, cdirent_entry *out, int *err) {
    if (ctx->remaining == 0) {
        struct attrlist al = make_attrlist();
        int n = getattrlistbulk(ctx->fd, &al, ctx->buf, CDIRENT_BUFSIZE, 0);
        if (n < 0) { *err = errno; return -1; }
        if (n == 0) return 0;
        ctx->remaining = n;
        ctx->cursor = ctx->buf;
    }
    uint32_t len;
    memcpy(&len, ctx->cursor, sizeof(len));
    decode_entry(ctx->cursor, out);
    ctx->cursor += len;
    ctx->remaining -= 1;
    return 1;
}

void cdirent_close(cdirent_ctx *ctx) {
    if (!ctx) return;
    close(ctx->fd);
    free(ctx->buf);
    free(ctx);
}

int cdirent_stat(const char *path, cdirent_entry *out) {
    // getattrlist(2) (unlike the bulk call) rejects ATTR_CMN_ERROR and type-mismatched
    // attribute groups, so lstat first and request only the group that applies.
    struct stat st;
    if (lstat(path, &st) != 0) return errno;

    struct attrlist al = make_attrlist();
    al.commonattr &= ~ATTR_CMN_ERROR;
    if (S_ISDIR(st.st_mode)) {
        al.fileattr = 0;
    } else {
        al.dirattr = 0;
        if (!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode)) al.fileattr = 0;
    }
    // Room for the fixed attributes plus a maximal name.
    char buf[sizeof(uint32_t) + sizeof(attribute_set_t) + 256 + 1024];
    if (getattrlist(path, &al, buf, sizeof(buf), FSOPT_NOFOLLOW) != 0) {
        return errno;
    }
    decode_entry(buf, out);
    return 0;
}
