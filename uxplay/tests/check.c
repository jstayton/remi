#include "check.h"

#include <stdio.h>

static const char *current_test = NULL;
static int current_failures = 0;

bool check(bool passed, const char *expression, const char *file, int line) {
    if (!passed) {
        current_failures++;
        fprintf(stderr, "    %s:%d: %s: expected %s\n", file, line, current_test, expression);
    }
    return passed;
}

void check_begin(const char *name) {
    current_test = name;
    current_failures = 0;
}

bool check_end(void) {
    bool passed = current_failures == 0;
    printf("%s %s\n", passed ? "✔" : "✘", current_test);
    return passed;
}
