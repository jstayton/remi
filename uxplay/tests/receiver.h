// The patched UxPlay receiver under test, on 127.0.0.1. It's configured like
// Remi/AirPlay/AirPlayShim.c, but not advertised over Bonjour.
#ifndef REMI_TEST_RECEIVER_H
#define REMI_TEST_RECEIVER_H

#include <pthread.h>
#include <stdbool.h>

#include "dnssd.h"
#include "raop.h"

#define RECEIVER_HARDWARE_ADDRESS "02:00:00:00:00:01"

typedef struct {
    raop_t *raop;
    dnssd_t *dnssd;
    unsigned short port;
    pthread_mutex_t lock;
    char pin[5];
    // The base64 Ed25519 key of the one phone that has paired before, as AirPlayClientStore keeps it.
    char registered_key[64];
} receiver_t;

// Starts the receiver on a port the OS picks. Set REMI_TEST_VERBOSE to see UxPlay's log.
bool receiver_start(receiver_t *receiver);

void receiver_stop(receiver_t *receiver);

// The PIN the receiver last showed, as a user reads it off the screen, or "" if it hasn't shown one.
void receiver_shown_pin(receiver_t *receiver, char pin[5]);

// Makes the phone with this Ed25519 public key the one the receiver knows.
void receiver_register_client(receiver_t *receiver, const unsigned char public_key[32]);

#endif
