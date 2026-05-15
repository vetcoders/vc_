#ifndef OS_LOG_H_
#define OS_LOG_H_

#include <stdbool.h>
#include <stdint.h>

typedef void *os_log_t;
typedef uint8_t os_log_type_t;

enum {
    OS_LOG_TYPE_DEFAULT = 0x00,
    OS_LOG_TYPE_INFO = 0x01,
    OS_LOG_TYPE_DEBUG = 0x02,
    OS_LOG_TYPE_ERROR = 0x10,
    OS_LOG_TYPE_FAULT = 0x11,
};

os_log_t os_log_create(const char *subsystem, const char *category);
void os_release(void *object);
bool os_log_type_enabled(os_log_t oslog, os_log_type_t type);
void _os_log_impl(void *dso, os_log_t log, os_log_type_t type, const char *format, const uint8_t *buf, uint32_t size);

#define os_log_with_type(log, type, format, message) \
    _os_log_impl((void *)0, (log), (type), (format), (const uint8_t *)(message), 0)

#endif
