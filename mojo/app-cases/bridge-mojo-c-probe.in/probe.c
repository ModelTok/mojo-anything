/* Calls every function the Mojo probe exports and prints what came back. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct pair {
    int a;
    double b;
};

int probe_add(int a, int b);
size_t probe_len(const char *s);
void probe_fill(unsigned char *buf, size_t n);
struct pair probe_swap(struct pair p);
void probe_end(const char *s, char **end);

int main(void) {
    printf("add %d\n", probe_add(2, 3));
    printf("len %zu\n", probe_len("abc"));
    printf("len_null %zu\n", probe_len(NULL));
    unsigned char buf[6];
    memset(buf, 255, sizeof buf);
    probe_fill(buf, 4);
    printf("fill");
    for (int i = 0; i < 6; i++) printf(" %d", buf[i]);
    printf("\n");
    struct pair p = {1, 2.5};
    struct pair q = probe_swap(p);
    printf("swap %d %g\n", q.a, q.b);
    const char *s = "hello";
    char *end = NULL;
    probe_end(s, &end);
    printf("end %td\n", end - s);
    return 0;
}
