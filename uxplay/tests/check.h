// Minimal test reporting for the C tests: CHECK records a failure without stopping the test.
#ifndef REMI_TEST_CHECK_H
#define REMI_TEST_CHECK_H

#include <stdbool.h>

#define CHECK(condition) check((condition), #condition, __FILE__, __LINE__)

// Returns `passed`, after reporting the expression if it failed.
bool check(bool passed, const char *expression, const char *file, int line);

// Starts counting failures toward the test named `name`.
void check_begin(const char *name);

// Prints whether the test passed, and returns whether it did.
bool check_end(void);

#endif
