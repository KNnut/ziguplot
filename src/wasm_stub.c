#include <stdio.h>

void (*signal(int, void *(int)))(int) {
    return 0;
}

int system(const char *) {
    return 0;
}

FILE *tmpfile(void) {
    return fmemopen(NULL, 8192, "w+");
}
