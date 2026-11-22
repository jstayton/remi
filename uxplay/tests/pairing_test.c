// End-to-end tests of PIN pairing in Remi's patched UxPlay (uxplay/patches). Each test starts its
// own receiver and connects one phone to it, since the receiver takes one connection at a time
// and keeps its PIN state across them.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/rand.h>

#include "check.h"
#include "client.h"
#include "receiver.h"

// Mirrors the patches' MAX_PIN_ATTEMPTS and MAX_PIN_FAILURES.
#define PIN_ATTEMPTS 3
#define PIN_FAILURES 9

typedef struct {
    receiver_t receiver;
    client_t client;
    char pin[5];
} fixture_t;

// Asks for a PIN, as an iPhone does when the user picks the receiver, and reads it off "screen".
static bool start_pin(fixture_t *fixture) {
    bool started = CHECK(pin_start(&fixture->client) == 200);
    receiver_shown_pin(&fixture->receiver, fixture->pin);
    return started && CHECK(strlen(fixture->pin) == 4);
}

static void guess_wrong(fixture_t *fixture, int count) {
    char guess[5];
    snprintf(guess, sizeof(guess), "%04d", (atoi(fixture->pin) + 1) % 10000);
    for (int i = 0; i < count; i++) {
        CHECK(pair(&fixture->client, guess) == REFUSED_PROOF);
    }
}

// Reconnects, as a phone does after giving up. The receiver takes a moment to drop the old
// connection, and refuses a second one (409) until it has.
static bool reconnect(fixture_t *fixture) {
    client_close(&fixture->client);
    for (int attempt = 0; attempt < 100; attempt++) {
        if (!client_connect(&fixture->client, fixture->receiver.port)) {
            return false;
        }
        if (client_options(&fixture->client) == 200) {
            return true;
        }
        client_close(&fixture->client);
        usleep(20 * 1000);
    }
    return false;
}

// Pair-verifies as the phone the receiver knows.
static bool verify_registered_client(fixture_t *fixture) {
    receiver_register_client(&fixture->receiver, fixture->client.identity_public_key);
    return CHECK(pair_verify(&fixture->client) == 200);
}

static void test_pairs_with_the_shown_pin(fixture_t *fixture) {
    if (start_pin(fixture)) {
        CHECK(pair(&fixture->client, fixture->pin) == PAIRED);
    }
}

static void test_refuses_a_wrong_pin(fixture_t *fixture) {
    if (start_pin(fixture)) {
        guess_wrong(fixture, 1);
    }
}

// 0001: the SRP proof is a 20-byte SHA-1 digest.
static void test_refuses_a_proof_that_isnt_sha1_sized(fixture_t *fixture) {
    srp_client_t srp = {0};
    if (start_pin(fixture) && CHECK(pair_setup_pin_step_1(&fixture->client, &srp) == PAIRED)) {
        srp_client_respond(&srp, fixture->pin);
        CHECK(pair_setup_pin_step_2(&fixture->client, &srp, 64) == REFUSED_PROOF);
    }
}

// 0003: without PAIR-PIN-START, there's no PIN to pair with (upstream checked against 0000).
static void test_refuses_pairing_before_a_pin_is_shown(fixture_t *fixture) {
    CHECK(pair(&fixture->client, "0000") == REFUSED_START);
}

// 0003: a mistyped PIN can be retried.
static void test_pairs_after_a_mistyped_pin(fixture_t *fixture) {
    if (start_pin(fixture)) {
        guess_wrong(fixture, PIN_ATTEMPTS - 1);
        CHECK(pair(&fixture->client, fixture->pin) == PAIRED);
    }
}

// 0003: too many wrong PINs discard it.
static void test_discards_the_pin_after_too_many_wrong_ones(fixture_t *fixture) {
    if (start_pin(fixture)) {
        guess_wrong(fixture, PIN_ATTEMPTS);
        CHECK(pair(&fixture->client, fixture->pin) == REFUSED_START);
    }
}

// 0003: a PIN pairs one phone only.
static void test_discards_the_pin_after_pairing(fixture_t *fixture) {
    if (start_pin(fixture) && CHECK(pair(&fixture->client, fixture->pin) == PAIRED)) {
        CHECK(pair(&fixture->client, fixture->pin) == REFUSED_START);
    }
}

// 0004: new PINs don't bring new guesses forever, even from a new connection.
static void test_locks_out_pin_guessing(fixture_t *fixture) {
    for (int failures = 0; failures < PIN_FAILURES; failures += PIN_ATTEMPTS) {
        if (!start_pin(fixture)) {
            return;
        }
        guess_wrong(fixture, PIN_ATTEMPTS);
    }
    if (CHECK(reconnect(fixture))) {
        CHECK(pin_start(&fixture->client) == 470);
    }
}

// 0004: only wrong PINs in a row count toward the lockout. Twice, this makes 8 wrong guesses
// (2 on each of 4 PINs) and then pairs: 16 wrong in all, but never 9 in a row.
static void test_pairing_resets_the_lockout_count(fixture_t *fixture) {
    for (int round = 0; round < 2; round++) {
        for (int pins = 0; pins < 4; pins++) {
            if (!start_pin(fixture)) {
                return;
            }
            guess_wrong(fixture, 2);
        }
        if (!start_pin(fixture) || !CHECK(pair(&fixture->client, fixture->pin) == PAIRED)) {
            return;
        }
    }
    CHECK(pin_start(&fixture->client) == 200);
}

// 0002: a returning phone must present the key it paired with.
static void test_refuses_pair_verify_from_an_unknown_client(fixture_t *fixture) {
    unsigned char other_key[32];
    RAND_bytes(other_key, sizeof(other_key));
    receiver_register_client(&fixture->receiver, other_key);
    verifier_t verifier = {0};
    CHECK(pair_verify_step_1(&fixture->client, &verifier) == 470);
    verifier_free(&verifier);
}

// 0002: mirroring needs a finished pairing, not just a connection.
static void test_refuses_setup_without_pairing(fixture_t *fixture) {
    CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH) == 470);
}

static void test_refuses_setup_after_only_pair_setup(fixture_t *fixture) {
    if (start_pin(fixture) && CHECK(pair(&fixture->client, fixture->pin) == PAIRED)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH) == 470);
    }
}

static void test_refuses_setup_after_unfinished_pair_verify(fixture_t *fixture) {
    receiver_register_client(&fixture->receiver, fixture->client.identity_public_key);
    verifier_t verifier = {0};
    if (CHECK(pair_verify_step_1(&fixture->client, &verifier) == 200)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH) == 470);
    }
    verifier_free(&verifier);
}

// The first time, a phone pairs with the PIN, then verifies on the same connection.
static void test_allows_setup_after_pin_pairing_and_pair_verify(fixture_t *fixture) {
    if (start_pin(fixture) && CHECK(pair(&fixture->client, fixture->pin) == PAIRED) &&
        CHECK(pair_verify(&fixture->client) == 200)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH) == 200);
    }
}

// After that, it only verifies with the key it paired with.
static void test_allows_setup_after_pair_verify_from_a_registered_client(fixture_t *fixture) {
    if (verify_registered_client(fixture)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH) == 200);
    }
}

// 0002: SETUP's keys are copied into fixed-size buffers, so other sizes are refused.
static void test_refuses_setup_with_a_wrong_size_eiv(fixture_t *fixture) {
    if (verify_registered_client(fixture)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH - 1, SETUP_EKEY_LENGTH) == 400);
    }
}

static void test_refuses_setup_with_a_wrong_size_ekey(fixture_t *fixture) {
    if (verify_registered_client(fixture)) {
        CHECK(setup(&fixture->client, SETUP_EIV_LENGTH, SETUP_EKEY_LENGTH - 1) == 400);
    }
}

typedef struct {
    const char *name;
    void (*run)(fixture_t *fixture);
} test_t;

#define TEST(function) {#function, function}

static const test_t tests[] = {
    TEST(test_pairs_with_the_shown_pin),
    TEST(test_refuses_a_wrong_pin),
    TEST(test_refuses_a_proof_that_isnt_sha1_sized),
    TEST(test_refuses_pairing_before_a_pin_is_shown),
    TEST(test_pairs_after_a_mistyped_pin),
    TEST(test_discards_the_pin_after_too_many_wrong_ones),
    TEST(test_discards_the_pin_after_pairing),
    TEST(test_locks_out_pin_guessing),
    TEST(test_pairing_resets_the_lockout_count),
    TEST(test_refuses_pair_verify_from_an_unknown_client),
    TEST(test_refuses_setup_without_pairing),
    TEST(test_refuses_setup_after_only_pair_setup),
    TEST(test_refuses_setup_after_unfinished_pair_verify),
    TEST(test_allows_setup_after_pin_pairing_and_pair_verify),
    TEST(test_allows_setup_after_pair_verify_from_a_registered_client),
    TEST(test_refuses_setup_with_a_wrong_size_eiv),
    TEST(test_refuses_setup_with_a_wrong_size_ekey),
};

int main(void) {
    int count = (int) (sizeof(tests) / sizeof(tests[0]));
    int passed = 0;
    for (int i = 0; i < count; i++) {
        check_begin(tests[i].name);
        fixture_t fixture = {0};
        if (CHECK(receiver_start(&fixture.receiver)) &&
            CHECK(client_connect(&fixture.client, fixture.receiver.port))) {
            tests[i].run(&fixture);
        }
        client_close(&fixture.client);
        receiver_stop(&fixture.receiver);
        passed += check_end();
    }
    printf("%d of %d pairing tests passed\n", passed, count);
    return passed == count ? 0 : 1;
}
