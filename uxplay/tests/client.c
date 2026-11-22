#define OPENSSL_SUPPRESS_DEPRECATED

#include "client.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <plist/plist.h>

#define READ_TIMEOUT_SECONDS 10

typedef struct {
    int status;
    unsigned char *body;
    int body_length;
} response_t;

// ---- RTSP

bool client_connect(client_t *client, unsigned short port) {
    client->cseq = 0;
    client->identity = EVP_PKEY_Q_keygen(NULL, NULL, "ED25519");
    size_t key_length = sizeof(client->identity_public_key);
    EVP_PKEY_get_raw_public_key(client->identity, client->identity_public_key, &key_length);
    client->socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct timeval timeout = {READ_TIMEOUT_SECONDS, 0};
    setsockopt(client->socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int no_sigpipe = 1;
    setsockopt(client->socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return connect(client->socket, (struct sockaddr *) &address, sizeof(address)) == 0;
}

void client_close(client_t *client) {
    close(client->socket);
    EVP_PKEY_free(client->identity);
    client->identity = NULL;
}

static bool send_all(int socket, const void *bytes, size_t length) {
    const char *cursor = bytes;
    while (length > 0) {
        ssize_t sent = send(socket, cursor, length, 0);
        if (sent <= 0) {
            return false;
        }
        cursor += sent;
        length -= (size_t) sent;
    }
    return true;
}

static bool receive_all(int socket, void *bytes, size_t length) {
    char *cursor = bytes;
    while (length > 0) {
        ssize_t received = recv(socket, cursor, length, 0);
        if (received <= 0) {
            return false;
        }
        cursor += received;
        length -= (size_t) received;
    }
    return true;
}

// Sends a request and reads its response. A status of 0 means the connection failed.
static response_t request(client_t *client, const char *method, const char *url, const char *content_type,
                          const void *body, int body_length) {
    response_t response = {0};
    char head[512];
    int head_length = snprintf(head, sizeof(head),
                               "%s %s RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: AirPlay/900.1\r\n"
                               "Content-Type: %s\r\nContent-Length: %d\r\n\r\n",
                               method, url, ++client->cseq, content_type, body_length);
    if (!send_all(client->socket, head, (size_t) head_length) ||
        (body_length > 0 && !send_all(client->socket, body, (size_t) body_length))) {
        return response;
    }

    char header[4096];
    size_t length = 0;
    while (length < sizeof(header) - 1) {
        if (!receive_all(client->socket, header + length, 1)) {
            return response;
        }
        length++;
        if (length >= 4 && !memcmp(header + length - 4, "\r\n\r\n", 4)) {
            break;
        }
    }
    header[length] = '\0';
    int status = 0;
    if (sscanf(header, "RTSP/1.0 %d", &status) != 1) {
        return response;
    }
    const char *content_length = strcasestr(header, "\r\nContent-Length:");
    int response_length = content_length ? atoi(content_length + strlen("\r\nContent-Length:")) : 0;
    if (response_length > 0) {
        response.body = malloc((size_t) response_length);
        if (!receive_all(client->socket, response.body, (size_t) response_length)) {
            free(response.body);
            response.body = NULL;
            return response;
        }
        response.body_length = response_length;
    }
    response.status = status;
    return response;
}

static void response_free(response_t *response) {
    free(response->body);
    response->body = NULL;
}

// Sends `root` as a binary plist, and frees it.
static response_t request_plist(client_t *client, const char *method, const char *url, plist_t root) {
    char *body = NULL;
    uint32_t body_length = 0;
    plist_to_bin(root, &body, &body_length);
    plist_free(root);
    response_t response = request(client, method, url, "application/x-apple-binary-plist", body, (int) body_length);
    plist_mem_free(body);
    return response;
}

// Returns the data item `key` of a binary plist response, or false if it isn't there.
static bool response_data(const response_t *response, const char *key, unsigned char *out, size_t *out_length) {
    plist_t root = NULL;
    plist_from_bin((const char *) response->body, (uint32_t) response->body_length, &root);
    plist_t node = root ? plist_dict_get_item(root, key) : NULL;
    bool found = false;
    if (PLIST_IS_DATA(node)) {
        char *data = NULL;
        uint64_t data_length = 0;
        plist_get_data_val(node, &data, &data_length);
        if (data_length <= *out_length) {
            memcpy(out, data, data_length);
            *out_length = (size_t) data_length;
            found = true;
        }
        plist_mem_free(data);
    }
    plist_free(root);
    return found;
}

int client_options(client_t *client) {
    response_t response = request(client, "OPTIONS", "*", "text/parameters", NULL, 0);
    response_free(&response);
    return response.status;
}

// ---- PIN pairing

int pin_start(client_t *client) {
    response_t response = request(client, "POST", "/pair-pin-start", "application/octet-stream", NULL, 0);
    response_free(&response);
    return response.status;
}

pairing_result_t pair_setup_pin_step_1(client_t *client, srp_client_t *srp) {
    plist_t root = plist_new_dict();
    plist_dict_set_item(root, "method", plist_new_string("pin"));
    plist_dict_set_item(root, "user", plist_new_string(SRP_CLIENT_USER));
    response_t response = request_plist(client, "POST", "/pair-setup-pin", root);
    pairing_result_t result = REFUSED_START;
    if (response.status == 200) {
        srp->salt_length = sizeof(srp->salt);
        srp->server_public_key_length = sizeof(srp->server_public_key);
        bool is_valid = response_data(&response, "salt", srp->salt, &srp->salt_length) &&
                        response_data(&response, "pk", srp->server_public_key, &srp->server_public_key_length);
        result = is_valid ? PAIRED : BROKEN;
    } else if (response.status != 470) {
        result = BROKEN;
    }
    response_free(&response);
    return result;
}

pairing_result_t pair_setup_pin_step_2(client_t *client, const srp_client_t *srp, size_t proof_length) {
    unsigned char proof[64] = {0};
    memcpy(proof, srp->proof, sizeof(srp->proof));
    plist_t root = plist_new_dict();
    plist_dict_set_item(root, "pk", plist_new_data((const char *) srp->client_public_key,
                                                   (uint64_t) srp->client_public_key_length));
    plist_dict_set_item(root, "proof", plist_new_data((const char *) proof, proof_length));
    response_t response = request_plist(client, "POST", "/pair-setup-pin", root);
    pairing_result_t result = response.status == 470 ? REFUSED_PROOF : BROKEN;
    if (response.status == 200) {
        unsigned char server_proof[64];
        size_t server_proof_length = sizeof(server_proof);
        bool is_valid = response_data(&response, "proof", server_proof, &server_proof_length) &&
                        server_proof_length == SHA_DIGEST_LENGTH &&
                        !memcmp(server_proof, srp->expected_server_proof, SHA_DIGEST_LENGTH);
        result = is_valid ? PAIRED : BROKEN;
    }
    response_free(&response);
    return result;
}

// Derives a 16-byte key or IV from `secret`, as the first bytes of SHA-512(label | secret).
static void derive(const char *label, const unsigned char *secret, size_t secret_length, unsigned char out[16]) {
    unsigned char digest[SHA512_DIGEST_LENGTH];
    SHA512_CTX context;
    SHA512_Init(&context);
    SHA512_Update(&context, label, strlen(label));
    SHA512_Update(&context, secret, secret_length);
    SHA512_Final(digest, &context);
    memcpy(out, digest, 16);
}

// AES-128-GCM with a 16-byte IV, as pair-setup uses it. Returns false if decryption fails to authenticate.
static bool gcm(bool encrypts, const unsigned char key[16], const unsigned char iv[16], const unsigned char in[32],
                unsigned char out[32], unsigned char tag[16]) {
    EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
    int length = 0;
    EVP_CipherInit_ex(cipher, EVP_aes_128_gcm(), NULL, NULL, NULL, encrypts);
    EVP_CIPHER_CTX_ctrl(cipher, EVP_CTRL_GCM_SET_IVLEN, 16, NULL);
    EVP_CipherInit_ex(cipher, NULL, NULL, key, iv, encrypts);
    EVP_CipherUpdate(cipher, out, &length, in, 32);
    if (!encrypts) {
        EVP_CIPHER_CTX_ctrl(cipher, EVP_CTRL_GCM_SET_TAG, 16, tag);
    }
    bool is_valid = EVP_CipherFinal_ex(cipher, out + length, &length) == 1;
    if (encrypts) {
        EVP_CIPHER_CTX_ctrl(cipher, EVP_CTRL_GCM_GET_TAG, 16, tag);
    }
    EVP_CIPHER_CTX_free(cipher);
    return is_valid;
}

pairing_result_t pair_setup_pin_step_3(client_t *client, const srp_client_t *srp) {
    unsigned char key[16], iv[16], encrypted[32], tag[16];
    derive("Pair-Setup-AES-Key", srp->session_key, sizeof(srp->session_key), key);
    derive("Pair-Setup-AES-IV", srp->session_key, sizeof(srp->session_key), iv);
    iv[15]++;
    gcm(true, key, iv, client->identity_public_key, encrypted, tag);

    plist_t root = plist_new_dict();
    plist_dict_set_item(root, "epk", plist_new_data((const char *) encrypted, sizeof(encrypted)));
    plist_dict_set_item(root, "authTag", plist_new_data((const char *) tag, sizeof(tag)));
    response_t response = request_plist(client, "POST", "/pair-setup-pin", root);
    pairing_result_t result = response.status == 470 ? REFUSED_CONFIRM : BROKEN;
    if (response.status == 200) {
        unsigned char server_encrypted[32], server_tag[16], server_key[32];
        size_t encrypted_length = sizeof(server_encrypted), tag_length = sizeof(server_tag);
        // The receiver encrypts with the next IV.
        iv[15]++;
        bool is_valid = response_data(&response, "epk", server_encrypted, &encrypted_length) &&
                        encrypted_length == sizeof(server_encrypted) &&
                        response_data(&response, "authTag", server_tag, &tag_length) &&
                        tag_length == sizeof(server_tag) &&
                        gcm(false, key, iv, server_encrypted, server_key, server_tag);
        result = is_valid ? PAIRED : BROKEN;
    }
    response_free(&response);
    return result;
}

pairing_result_t pair(client_t *client, const char *pin) {
    srp_client_t srp = {0};
    pairing_result_t result = pair_setup_pin_step_1(client, &srp);
    if (result != PAIRED) {
        return result;
    }
    srp_client_respond(&srp, pin);
    result = pair_setup_pin_step_2(client, &srp, SHA_DIGEST_LENGTH);
    if (result != PAIRED) {
        return result;
    }
    return pair_setup_pin_step_3(client, &srp);
}

// ---- Pair-verify

int pair_verify_step_1(client_t *client, verifier_t *verifier) {
    verifier->ecdh = EVP_PKEY_Q_keygen(NULL, NULL, "X25519");
    size_t key_length = sizeof(verifier->ecdh_public_key);
    EVP_PKEY_get_raw_public_key(verifier->ecdh, verifier->ecdh_public_key, &key_length);
    unsigned char body[4 + 32 + 32] = {1, 0, 0, 0};
    memcpy(body + 4, verifier->ecdh_public_key, 32);
    memcpy(body + 4 + 32, client->identity_public_key, 32);
    response_t response = request(client, "POST", "/pair-verify", "application/octet-stream", body, sizeof(body));
    int status = response.status;
    if (status == 200) {
        if (response.body_length == 32 + 64) {
            memcpy(verifier->server_ecdh_public_key, response.body, 32);
        } else {
            status = 0;
        }
    }
    response_free(&response);
    return status;
}

int pair_verify_step_2(client_t *client, const verifier_t *verifier) {
    unsigned char secret[32];
    size_t secret_length = sizeof(secret);
    EVP_PKEY *server_ecdh =
        EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, verifier->server_ecdh_public_key, 32);
    EVP_PKEY_CTX *agreement = EVP_PKEY_CTX_new(verifier->ecdh, NULL);
    EVP_PKEY_derive_init(agreement);
    EVP_PKEY_derive_set_peer(agreement, server_ecdh);
    EVP_PKEY_derive(agreement, secret, &secret_length);
    EVP_PKEY_CTX_free(agreement);
    EVP_PKEY_free(server_ecdh);

    unsigned char key[16], iv[16];
    derive("Pair-Verify-AES-Key", secret, secret_length, key);
    derive("Pair-Verify-AES-IV", secret, secret_length, iv);

    unsigned char message[64], signature[64];
    size_t signature_length = sizeof(signature);
    memcpy(message, verifier->ecdh_public_key, 32);
    memcpy(message + 32, verifier->server_ecdh_public_key, 32);
    EVP_MD_CTX *signer = EVP_MD_CTX_new();
    EVP_DigestSignInit(signer, NULL, NULL, NULL, client->identity);
    EVP_DigestSign(signer, signature, &signature_length, message, sizeof(message));
    EVP_MD_CTX_free(signer);

    // The receiver's signature used the first 64 bytes of the keystream; the phone's uses the next.
    unsigned char body[4 + 64] = {0, 0, 0, 0}, skipped[64] = {0};
    int length = 0;
    EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(cipher, EVP_aes_128_ctr(), NULL, key, iv);
    EVP_EncryptUpdate(cipher, skipped, &length, skipped, sizeof(skipped));
    EVP_EncryptUpdate(cipher, body + 4, &length, signature, sizeof(signature));
    EVP_CIPHER_CTX_free(cipher);

    response_t response = request(client, "POST", "/pair-verify", "application/octet-stream", body, sizeof(body));
    response_free(&response);
    return response.status;
}

void verifier_free(verifier_t *verifier) {
    EVP_PKEY_free(verifier->ecdh);
    verifier->ecdh = NULL;
}

int pair_verify(client_t *client) {
    verifier_t verifier = {0};
    int status = pair_verify_step_1(client, &verifier);
    if (status == 200) {
        status = pair_verify_step_2(client, &verifier);
    }
    verifier_free(&verifier);
    return status;
}

// ---- SETUP

int setup(client_t *client, size_t eiv_length, size_t ekey_length) {
    unsigned char eiv[64] = {0}, ekey[128] = {0};
    plist_t root = plist_new_dict();
    plist_dict_set_item(root, "eiv", plist_new_data((const char *) eiv, eiv_length));
    plist_dict_set_item(root, "ekey", plist_new_data((const char *) ekey, ekey_length));
    plist_dict_set_item(root, "deviceID", plist_new_string(SRP_CLIENT_USER));
    plist_dict_set_item(root, "name", plist_new_string("Test iPhone"));
    response_t response = request_plist(client, "SETUP", "rtsp://127.0.0.1/1", root);
    response_free(&response);
    return response.status;
}
