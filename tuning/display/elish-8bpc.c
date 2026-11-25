#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <drm.h>
#include <drm_mode.h>
#include <drm_fourcc.h>

/* gnome-shell 50 picks a 10-bit scanout format before any 8-bit format.
 * This panel's DPU then shows garbage that a client screenshot does not.
 * Rewriting the plane IN_FORMATS blob makes the 10-bit formats look
 * unsupported, so mutter falls through to an 8-bit format. The rewrite
 * runs only when ELISH_8BPC=1, which is set for gnome-shell alone.
 */

static int (*real_ioctl)(int, unsigned long, ...);

static int is_tenbit(uint32_t format)
{
    switch (format) {
    case DRM_FORMAT_XRGB2101010:
    case DRM_FORMAT_XBGR2101010:
    case DRM_FORMAT_ARGB2101010:
    case DRM_FORMAT_ABGR2101010:
    case DRM_FORMAT_RGBX1010102:
    case DRM_FORMAT_RGBA1010102:
    case DRM_FORMAT_BGRX1010102:
    case DRM_FORMAT_BGRA1010102:
        return 1;
    default:
        return 0;
    }
}

static void rewrite_blob(struct drm_mode_get_blob *blob)
{
    struct drm_format_modifier_blob *header;
    uint32_t *formats;
    uint32_t i, changed = 0;
    size_t need;

    if (!blob || blob->data == 0 || blob->length < sizeof(*header))
        return;
    if (getenv("ELISH_8BPC") == NULL)
        return;

    header = (struct drm_format_modifier_blob *)(uintptr_t)blob->data;
    if (header->version != FORMAT_BLOB_CURRENT)
        return;
    if (header->count_formats == 0 || header->count_formats > 64)
        return;
    if (header->count_modifiers > 128)
        return;
    need = (size_t)header->formats_offset +
           (size_t)header->count_formats * sizeof(uint32_t);
    if (need > blob->length)
        return;
    need = (size_t)header->modifiers_offset +
           (size_t)header->count_modifiers * sizeof(struct drm_format_modifier);
    if (header->count_modifiers && need > blob->length)
        return;

    formats = (uint32_t *)((char *)header + header->formats_offset);
    for (i = 0; i < header->count_formats; i++) {
        if (is_tenbit(formats[i])) {
            formats[i] = DRM_FORMAT_XRGB8888;
            changed++;
        }
    }
    if (changed) {
        FILE *log = fopen("/tmp/elish-8bpc.log", "a");
        if (log) {
            fprintf(log, "rewrote %u 10-bit formats in blob %u\n",
                    changed, blob->blob_id);
            fclose(log);
        }
    }
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    void *arg;
    int rc;

    if (!real_ioctl)
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);
    rc = real_ioctl(fd, request, arg);
    if (rc == 0 && request == DRM_IOCTL_MODE_GETPROPBLOB)
        rewrite_blob(arg);
    return rc;
}
