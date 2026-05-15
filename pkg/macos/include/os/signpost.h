#ifndef OS_SIGNPOST_H_
#define OS_SIGNPOST_H_

#include <stdbool.h>
#include <stdint.h>
#include <os/log.h>

struct mach_header;
typedef uint64_t os_signpost_id_t;
typedef uint8_t os_signpost_type_t;

bool os_signpost_enabled(os_log_t log);
os_signpost_id_t os_signpost_id_generate(os_log_t log);
os_signpost_id_t os_signpost_id_make_with_pointer(os_log_t log, const void *ptr);
void _os_signpost_emit_with_name_impl(
    struct mach_header *dso,
    os_log_t log,
    os_signpost_type_t type,
    os_signpost_id_t spid,
    const char *name,
    const char *format,
    const uint8_t *buf,
    uint32_t size);

#endif
