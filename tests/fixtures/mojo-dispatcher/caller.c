/* Calls the dispatcher of tests/fixtures/mojo-dispatcher. `caller NAME ARGS...` prints one
   answer per pair; `caller --rss` prints the resident set after 1,000 and after 100,000
   call-and-free rounds; `caller --free-null` frees NULL. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *mojo_anything_call(const char *name, const char *args);
void mojo_anything_free(char *answer);

static long rss_kb(void) {
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    long kb = -1;
    if (!f) return -1;
    while (fgets(line, sizeof line, f))
        if (strncmp(line, "VmRSS:", 6) == 0) kb = atol(line + 6);
    fclose(f);
    return kb;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--rss") == 0) {
        long first = 0;
        for (int i = 1; i <= 100000; i++) {
            char *a = mojo_anything_call("repeat", "[[\"ab\",\"c\"],2,7]");
            mojo_anything_free(a);
            if (i == 1000) first = rss_kb();
        }
        printf("rss %ld %ld\n", first, rss_kb());
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--free-null") == 0) {
        mojo_anything_free(NULL);
        printf("freed\n");
        return 0;
    }
    for (int i = 1; i + 1 < argc; i += 2) {
        char *a = mojo_anything_call(argv[i], argv[i + 1]);
        printf("%s\n", a ? a : "(null)");
        mojo_anything_free(a);
    }
    return 0;
}
