// A phone talking to the receiver over one connection, the way an iPhone does: RTSP requests
// carrying binary plists for PIN pairing (pair-setup-pin), pair-verify, and SETUP.
#ifndef REMI_TEST_CLIENT_H
#define REMI_TEST_CLIENT_H

#include <stdbool.h>
#include <stddef.h>

#include <openssl/evp.h>

#include "srp_client.h"

// The key sizes of a valid first SETUP.
#define SETUP_EIV_LENGTH 16
#define SETUP_EKEY_LENGTH 72

typedef struct {
    int socket;
    int cseq;
    // The phone's long-term Ed25519 identity, which PIN pairing registers and pair-verify proves.
    EVP_PKEY *identity;
    unsigned char identity_public_key[32];
} client_t;

// Connects a phone with a new identity.
bool client_connect(client_t *client, unsigned short port);

void client_close(client_t *client);

// An OPTIONS request, which every connection may send. Returns its status, or 0 if the connection failed.
int client_options(client_t *client);

// Asks the receiver to show a PIN. Returns the status.
int pin_start(client_t *client);

typedef enum {
    PAIRED,           // all three pair-setup-pin steps succeeded
    REFUSED_START,    // step 1 (the salt) was refused
    REFUSED_PROOF,    // step 2 (the phone's proof) was refused
    REFUSED_CONFIRM,  // step 3 (the phone's key) was refused
    BROKEN,           // a response was malformed, or the connection failed
} pairing_result_t;

// Step 1 sends the phone's user name and gets the receiver's salt and public key.
pairing_result_t pair_setup_pin_step_1(client_t *client, srp_client_t *srp);

// Step 2 sends the phone's proof, `proof_length` bytes of it, and checks the receiver's.
pairing_result_t pair_setup_pin_step_2(client_t *client, const srp_client_t *srp, size_t proof_length);

// Step 3 sends the phone's identity, and checks the receiver's reply carries its own, authenticated.
pairing_result_t pair_setup_pin_step_3(client_t *client, const srp_client_t *srp);

// Runs pair-setup-pin with `pin`, as far as the receiver allows.
pairing_result_t pair(client_t *client, const char *pin);

// A returning phone's pair-verify: X25519 key agreement, then proof of its Ed25519 identity.
typedef struct {
    EVP_PKEY *ecdh;
    unsigned char ecdh_public_key[32];
    unsigned char server_ecdh_public_key[32];
} verifier_t;

// Sends the phone's keys. Returns the status, or 0 if a 200 doesn't carry the receiver's key and signature.
int pair_verify_step_1(client_t *client, verifier_t *verifier);

// Signs both X25519 keys with the phone's identity, encrypted with keys from the shared secret.
int pair_verify_step_2(client_t *client, const verifier_t *verifier);

void verifier_free(verifier_t *verifier);

// Runs both pair-verify steps. Returns the first status that isn't 200, or 200.
int pair_verify(client_t *client);

// The first SETUP, which starts a mirroring session, with keys of the given sizes. Returns the status.
int setup(client_t *client, size_t eiv_length, size_t ekey_length);

#endif
