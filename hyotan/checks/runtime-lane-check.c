#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Regression for ARM64 single-structure halfword lane decoding. Each lane
// gets a distinct value, so collapsing odd lanes onto even lanes is visible.
#define LOAD_LANES(suffix) \
    "movi v0.16b, #0\n" \
    "ld1 {v0.h}[0], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[1], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[2], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[3], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[4], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[5], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[6], [%[p]]" suffix "\n" \
    "ld1 {v0.h}[7], [%[p]]" suffix "\n" \
    "str q0, [%[out]]\n"

#define STORE_LANES(suffix) \
    "ldr q0, [%[in]]\n" \
    "st1 {v0.h}[0], [%[p]]" suffix "\n" \
    "st1 {v0.h}[1], [%[p]]" suffix "\n" \
    "st1 {v0.h}[2], [%[p]]" suffix "\n" \
    "st1 {v0.h}[3], [%[p]]" suffix "\n" \
    "st1 {v0.h}[4], [%[p]]" suffix "\n" \
    "st1 {v0.h}[5], [%[p]]" suffix "\n" \
    "st1 {v0.h}[6], [%[p]]" suffix "\n" \
    "st1 {v0.h}[7], [%[p]]" suffix "\n"

static int check(const char *name, const uint16_t *expected, const uint16_t *actual) {
    int okay = memcmp(expected, actual, 16) == 0;
    printf("%s=%s values=", name, okay ? "ok" : "FAIL");
    for (int i = 0; i < 8; i++)
        printf("%s%u", i ? "," : "", actual[i]);
    putchar('\n');
    return okay ? 0 : 1;
}

int main(void) {
    const uint16_t values[8] = {101, 202, 303, 404, 505, 606, 707, 808};
    uint16_t output[8] = {0};
    const uint16_t *input = values;
    int failures = 0;

    __asm__ volatile(LOAD_LANES("\nadd %[p], %[p], #2")
                     : [p] "+r"(input) : [out] "r"(output) : "v0", "memory");
    failures += check("ld1-halfword-no-offset", values, output);

    input = values;
    __asm__ volatile(LOAD_LANES(", #2")
                     : [p] "+r"(input) : [out] "r"(output) : "v0", "memory");
    failures += check("ld1-halfword-post-immediate", values, output);

    input = values;
    uintptr_t stride = 2;
    __asm__ volatile(LOAD_LANES(", %[stride]")
                     : [p] "+r"(input) : [out] "r"(output), [stride] "r"(stride)
                     : "v0", "memory");
    failures += check("ld1-halfword-post-register", values, output);

    uint16_t *destination = output;
    __asm__ volatile(STORE_LANES("\nadd %[p], %[p], #2")
                     : [p] "+r"(destination) : [in] "r"(values) : "v0", "memory");
    failures += check("st1-halfword-no-offset", values, output);

    destination = output;
    __asm__ volatile(STORE_LANES(", #2")
                     : [p] "+r"(destination) : [in] "r"(values) : "v0", "memory");
    failures += check("st1-halfword-post-immediate", values, output);

    destination = output;
    __asm__ volatile(STORE_LANES(", %[stride]")
                     : [p] "+r"(destination) : [in] "r"(values), [stride] "r"(stride)
                     : "v0", "memory");
    failures += check("st1-halfword-post-register", values, output);
    return failures != 0;
}
