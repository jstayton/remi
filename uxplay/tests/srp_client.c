#define OPENSSL_SUPPRESS_DEPRECATED

#include "srp_client.h"

#include <string.h>

#include <openssl/bn.h>
#include <openssl/srp.h>

static void hash_bignum(SHA_CTX *context, const BIGNUM *number) {
    unsigned char bytes[512];
    int length = BN_bn2bin(number, bytes);
    SHA1_Update(context, bytes, (size_t) length);
}

// H(PAD(a) | PAD(b)), padded to the group's size as RFC 5054 says.
static BIGNUM *hash_padded_pair(const BIGNUM *a, const BIGNUM *b, int padded_length) {
    unsigned char bytes[1024];
    unsigned char digest[SHA_DIGEST_LENGTH];
    BN_bn2binpad(a, bytes, padded_length);
    BN_bn2binpad(b, bytes + padded_length, padded_length);
    SHA1(bytes, (size_t) (2 * padded_length), digest);
    return BN_bin2bn(digest, SHA_DIGEST_LENGTH, NULL);
}

void srp_client_respond(srp_client_t *srp, const char *pin) {
    SRP_gN *group = SRP_get_default_gN("2048");
    const BIGNUM *N = group->N;
    const BIGNUM *g = group->g;
    int N_length = BN_num_bytes(N);
    BN_CTX *bn = BN_CTX_new();
    BIGNUM *a = BN_new(), *A = BN_new(), *t1 = BN_new(), *t2 = BN_new(), *S = BN_new();
    BIGNUM *B = BN_bin2bn(srp->server_public_key, (int) srp->server_public_key_length, NULL);
    BN_rand(a, 256, -1, 0);
    BN_mod_exp(A, g, a, N, bn);
    srp->client_public_key_length = BN_bn2bin(A, srp->client_public_key);

    unsigned char inner[SHA_DIGEST_LENGTH], digest[SHA_DIGEST_LENGTH];
    SHA_CTX context;
    SHA1_Init(&context);
    SHA1_Update(&context, SRP_CLIENT_USER ":", strlen(SRP_CLIENT_USER ":"));
    SHA1_Update(&context, pin, strlen(pin));
    SHA1_Final(inner, &context);
    SHA1_Init(&context);
    SHA1_Update(&context, srp->salt, srp->salt_length);
    SHA1_Update(&context, inner, sizeof(inner));
    SHA1_Final(digest, &context);
    BIGNUM *x = BN_bin2bn(digest, SHA_DIGEST_LENGTH, NULL);
    BIGNUM *k = hash_padded_pair(N, g, N_length);
    BIGNUM *u = hash_padded_pair(A, B, N_length);

    // S = (B - k g^x)^(a + u x)
    BN_mod_exp(t1, g, x, N, bn);
    BN_mod_mul(t1, k, t1, N, bn);
    BN_mod_sub(t1, B, t1, N, bn);
    BN_mul(t2, u, x, bn);
    BN_add(t2, a, t2);
    BN_mod_exp(S, t1, t2, N, bn);

    unsigned char counter[4] = {0, 0, 0, 0};
    for (int half = 0; half < 2; half++) {
        counter[3] = (unsigned char) half;
        SHA1_Init(&context);
        hash_bignum(&context, S);
        SHA1_Update(&context, counter, sizeof(counter));
        SHA1_Final(srp->session_key + half * SHA_DIGEST_LENGTH, &context);
    }

    unsigned char hash_N[SHA_DIGEST_LENGTH], hash_g[SHA_DIGEST_LENGTH], hash_user[SHA_DIGEST_LENGTH];
    SHA1_Init(&context);
    hash_bignum(&context, N);
    SHA1_Final(hash_N, &context);
    SHA1_Init(&context);
    hash_bignum(&context, g);
    SHA1_Final(hash_g, &context);
    SHA1((const unsigned char *) SRP_CLIENT_USER, strlen(SRP_CLIENT_USER), hash_user);
    for (int i = 0; i < SHA_DIGEST_LENGTH; i++) {
        hash_N[i] ^= hash_g[i];
    }
    SHA1_Init(&context);
    SHA1_Update(&context, hash_N, sizeof(hash_N));
    SHA1_Update(&context, hash_user, sizeof(hash_user));
    SHA1_Update(&context, srp->salt, srp->salt_length);
    hash_bignum(&context, A);
    hash_bignum(&context, B);
    SHA1_Update(&context, srp->session_key, sizeof(srp->session_key));
    SHA1_Final(srp->proof, &context);

    SHA1_Init(&context);
    hash_bignum(&context, A);
    SHA1_Update(&context, srp->proof, sizeof(srp->proof));
    SHA1_Update(&context, srp->session_key, sizeof(srp->session_key));
    SHA1_Final(srp->expected_server_proof, &context);

    BN_free(a);
    BN_free(A);
    BN_free(B);
    BN_free(x);
    BN_free(k);
    BN_free(u);
    BN_free(t1);
    BN_free(t2);
    BN_free(S);
    BN_CTX_free(bn);
}
