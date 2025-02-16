#include <bits/setjmp.h>
#include "stdfn.h"

int setjmp(__jmp_buf) {
    return 0;
};

void longjmp(__jmp_buf, int) {
    gp_exit(EXIT_FAILURE);
};

void __SIG_IGN(int) {};
