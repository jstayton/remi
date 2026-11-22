// The SRP-6a math of PIN pairing as an iPhone does it: SHA-1, the 2048-bit group, and Apple's
// 40-byte session key. Like iOS, it hashes the salt exactly as it receives it.
#ifndef REMI_TEST_SRP_CLIENT_H
#define REMI_TEST_SRP_CLIENT_H

#include <stddef.h>

#include <openssl/sha.h>

// The user name a phone pairs as: its device ID.
#define SRP_CLIENT_USER "AA:BB:CC:DD:EE:FF"

typedef struct {
    // In: the salt and public key B the receiver sent.
    unsigned char salt[64];
    size_t salt_length;
    unsigned char server_public_key[512];
    size_t server_public_key_length;
    // Out: the phone's public key A, its proof M, the receiver's proof it expects back, and the session key.
    unsigned char client_public_key[256];
    int client_public_key_length;
    unsigned char proof[SHA_DIGEST_LENGTH];
    unsigned char expected_server_proof[SHA_DIGEST_LENGTH];
    unsigned char session_key[2 * SHA_DIGEST_LENGTH];
} srp_client_t;

// Computes the phone's side of pairing with `pin`.
void srp_client_respond(srp_client_t *srp, const char *pin);

#endif
