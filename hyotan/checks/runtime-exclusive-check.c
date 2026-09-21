#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>

// The stock Typst executable loops over LDXP x24,x23 / STXP w8,x24,x23.
// The former CAS decoder mask misclassified both instructions when Rt2's
// low two bits were 11. One bounded attempt exposes that bug without hanging.
#define PAIR_CHECK(load, store, width, name) do { \
    uint##width##_t pair[2] __attribute__((aligned(16))) = {17, 29}; \
    uint64_t first, second; \
    unsigned status; \
    __asm__ volatile( \
        "mov x1, %[ptr]\n" \
        "mov x24, #165\n" \
        "mov x23, #182\n" \
        "mov w8, #127\n" \
        load "\n" store "\n" \
        "mov %[first], x24\n" \
        "mov %[second], x23\n" \
        "mov %w[status], w8\n" \
        : [first] "=&r"(first), [second] "=&r"(second), [status] "=&r"(status) \
        : [ptr] "r"(pair) \
        : "x1", "x8", "x23", "x24", "memory"); \
    int okay = first == 17 && second == 29 && status == 0 && pair[0] == 17 && pair[1] == 29; \
    printf("%s=%s loaded=%" PRIu64 ",%" PRIu64 " status=%u stored=%" PRIu64 ",%" PRIu64 "\n", \
           name, okay ? "ok" : "FAIL", first, second, status, (uint64_t)pair[0], (uint64_t)pair[1]); \
    failures += !okay; \
} while (0)

static uint64_t cas64(uint64_t *value, uint64_t expected, uint64_t desired) {
    __asm__ volatile(".arch_extension lse\ncasal %x[old], %x[new], [%[ptr]]"
                     : [old] "+r"(expected)
                     : [new] "r"(desired), [ptr] "r"(value)
                     : "memory");
    return expected;
}

int main(void) {
    int failures = 0;
    PAIR_CHECK("ldxp x24, x23, [x1]", "stxp w8, x24, x23, [x1]", 64, "ldxp-stxp-64");
    PAIR_CHECK("ldaxp x24, x23, [x1]", "stlxp w8, x24, x23, [x1]", 64, "ldaxp-stlxp-64");
    PAIR_CHECK("ldxp w24, w23, [x1]", "stxp w8, w24, w23, [x1]", 32, "ldxp-stxp-32");
    PAIR_CHECK("ldaxp w24, w23, [x1]", "stlxp w8, w24, w23, [x1]", 32, "ldaxp-stlxp-32");
    uint64_t value = 17;
    uint64_t old = cas64(&value, 17, 99);
    int okay = old == 17 && value == 99;
    printf("casal-success=%s old=%" PRIu64 " stored=%" PRIu64 "\n", okay ? "ok" : "FAIL", old, value);
    failures += !okay;
    old = cas64(&value, 17, 123);
    okay = old == 99 && value == 99;
    printf("casal-failure=%s old=%" PRIu64 " stored=%" PRIu64 "\n", okay ? "ok" : "FAIL", old, value);
    failures += !okay;
    return failures ? 1 : 0;
}
