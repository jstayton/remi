// Tests of the SRP-6a half of PIN pairing, straight through UxPlay's pairing.c.
#include <stdio.h>
#include <string.h>

#include "check.h"
#include "pairing.h"
#include "srp_client.h"

#define RECEIVER_ID "02:00:00:00:00:01"

// Pairs once with PIN 1234, checking both proofs. Returns the salt's length, or 0 if pairing failed.
static int pair_once(pairing_t *pairing) {
    pairing_session_t *session = pairing_session_init(pairing);
    const char *salt = NULL, *server_public_key = NULL;
    int salt_length = 0, server_public_key_length = 0;
    if (srp_new_user(session, pairing, SRP_CLIENT_USER, "1234", &salt, &salt_length, &server_public_key,
                     &server_public_key_length)) {
        pairing_session_destroy(session);
        return 0;
    }
    srp_client_t srp = {0};
    memcpy(srp.salt, salt, (size_t) salt_length);
    srp.salt_length = (size_t) salt_length;
    memcpy(srp.server_public_key, server_public_key, (size_t) server_public_key_length);
    srp.server_public_key_length = (size_t) server_public_key_length;
    srp_client_respond(&srp, "1234");
    unsigned char proof[64] = {0};
    memcpy(proof, srp.proof, sizeof(srp.proof));
    bool is_valid = srp_validate_proof(session, pairing, srp.client_public_key, srp.client_public_key_length, proof,
                                       SHA_DIGEST_LENGTH, SHA_DIGEST_LENGTH) == 0 &&
                    !memcmp(proof, srp.expected_server_proof, SHA_DIGEST_LENGTH);
    pairing_session_destroy(session);
    return is_valid ? salt_length : 0;
}

// 0005: about 1 in 256 salts start with a zero byte, which csrp drops. Pairs until a few have,
// checking every pairing on the way.
static void test_pairs_when_the_salt_starts_with_zero(void) {
    int result = 0;
    pairing_t *pairing = pairing_init_generate(RECEIVER_ID, "", &result);
    if (!CHECK(pairing != NULL)) {
        return;
    }
    int short_salts = 0;
    // Expect about 800 tries; failing to see 3 short salts in 20,000 is vanishingly unlikely.
    for (int i = 0; i < 20000 && short_salts < 3; i++) {
        int salt_length = pair_once(pairing);
        if (!CHECK(salt_length > 0)) {
            break;
        }
        short_salts += salt_length < SRP_SALT_SIZE;
    }
    CHECK(short_salts == 3);
    pairing_destroy(pairing);
}

int main(void) {
    check_begin("test_pairs_when_the_salt_starts_with_zero");
    test_pairs_when_the_salt_starts_with_zero();
    return check_end() ? 0 : 1;
}
