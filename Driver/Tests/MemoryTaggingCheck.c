#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor)) static void report_tags(void) {
    void *values[32];
    int tagged = 0;
    for (unsigned i = 0; i < 32; i++) {
        values[i] = malloc(128 + 16 * i);
        tagged += (((uintptr_t)values[i] >> 56) & 0xf) != 0;
    }
    for (unsigned i = 0; i < 32; i++) free(values[i]);
    printf("Tagged test-process heap allocations: %d/32\n", tagged);
    if (!tagged) exit(2);
}
