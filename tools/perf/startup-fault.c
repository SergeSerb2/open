// Negative-proof only. Never linked into the app or used in primary samples.
#include <time.h>
__attribute__((constructor)) static void delay_startup(void) {
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 200000000};
    nanosleep(&pause, 0);
}
