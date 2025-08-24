#include <stdio.h>

int system(const char *) {
    return 0;
}

FILE *tmpfile(void) {
    return fmemopen(NULL, 8192, "w+");
}
