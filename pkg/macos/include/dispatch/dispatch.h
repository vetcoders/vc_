#ifndef DISPATCH_DISPATCH_H_
#define DISPATCH_DISPATCH_H_

#include <stddef.h>

typedef void *dispatch_queue_t;
typedef const void *dispatch_data_t;

#define DISPATCH_DATA_DESTRUCTOR_DEFAULT ((void *)0)

dispatch_queue_t dispatch_get_main_queue(void);

#endif
