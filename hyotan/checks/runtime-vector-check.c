#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Bounded guest tests for the stock Typst instructions that previously raised
// SIGILL. Check actual lane values, narrow/widen halves, and aliasing.
int main(void) {
    int failures = 0;
    uint8_t bytes[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
    uint8_t output[16], expected[16];
    __asm__ volatile("ldr q0, [%0]\nrev16 v0.8b, v0.8b\nstr q0, [%1]"
                     :: "r"(bytes), "r"(output) : "v0", "memory");
    for (int i = 0; i < 16; i++) expected[i] = i < 8 ? bytes[i ^ 1] : 0;
    int okay = memcmp(output, expected, 16) == 0;
    printf("rev16-8b-alias=%s first=%u,%u last=%u,%u upper=%u\n",
           okay ? "ok" : "FAIL", output[0], output[1], output[6], output[7], output[15]);
    failures += !okay;
    __asm__ volatile("ldr q0, [%0]\nrev16 v1.16b, v0.16b\nstr q1, [%1]"
                     :: "r"(bytes), "r"(output) : "v0", "v1", "memory");
    for (int i = 0; i < 16; i++) expected[i] = bytes[i ^ 1];
    okay = memcmp(output, expected, 16) == 0;
    printf("rev16-16b=%s first=%u,%u last=%u,%u\n",
           okay ? "ok" : "FAIL", output[0], output[1], output[14], output[15]);
    failures += !okay;

    double doubles[2] = {1.25, -2.5};
    float singles[4] = {11, 22, 33, 44};
    uint32_t narrow[4];
    __asm__ volatile("ldr q0, [%0]\nfcvtn v0.2s, v0.2d\nstr q0, [%1]"
                     :: "r"(doubles), "r"(narrow) : "v0", "memory");
    uint32_t expect_low[4] = {0x3fa00000, 0xc0200000, 0, 0};
    okay = memcmp(narrow, expect_low, 16) == 0;
    printf("fcvtn-low-alias=%s bits=%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 "\n",
           okay ? "ok" : "FAIL", narrow[0], narrow[1], narrow[2], narrow[3]);
    failures += !okay;
    __asm__ volatile("ldr q0, [%0]\nldr q1, [%1]\nfcvtn2 v1.4s, v0.2d\nstr q1, [%2]"
                     :: "r"(doubles), "r"(singles), "r"(narrow) : "v0", "v1", "memory");
    uint32_t expect_high[4] = {0x41300000, 0x41b00000, 0x3fa00000, 0xc0200000};
    okay = memcmp(narrow, expect_high, 16) == 0;
    printf("fcvtn2-preserve-low=%s bits=%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 ",%08" PRIx32 "\n",
           okay ? "ok" : "FAIL", narrow[0], narrow[1], narrow[2], narrow[3]);
    failures += !okay;

    float widen_input[4] = {1.25, -2.5, 3.5, -4.75};
    uint64_t wide[2];
    __asm__ volatile("ldr q1, [%0]\nfcvtl v1.2d, v1.2s\nstr q1, [%1]"
                     :: "r"(widen_input), "r"(wide) : "v1", "memory");
    uint64_t wide_low[2] = {UINT64_C(0x3ff4000000000000), UINT64_C(0xc004000000000000)};
    okay = memcmp(wide, wide_low, 16) == 0;
    printf("fcvtl-low-alias=%s bits=%016" PRIx64 ",%016" PRIx64 "\n",
           okay ? "ok" : "FAIL", wide[0], wide[1]);
    failures += !okay;
    __asm__ volatile("ldr q2, [%0]\nfcvtl2 v3.2d, v2.4s\nstr q3, [%1]"
                     :: "r"(widen_input), "r"(wide) : "v2", "v3", "memory");
    uint64_t wide_high[2] = {UINT64_C(0x400c000000000000), UINT64_C(0xc013000000000000)};
    okay = memcmp(wide, wide_high, 16) == 0;
    printf("fcvtl2-high=%s bits=%016" PRIx64 ",%016" PRIx64 "\n",
           okay ? "ok" : "FAIL", wide[0], wide[1]);
    failures += !okay;
    return failures ? 1 : 0;
}
