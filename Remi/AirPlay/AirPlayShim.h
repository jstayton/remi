// A small C surface over UxPlay's AirPlay library so Swift never sees its headers.
#ifndef REMI_AIRPLAY_SHIM_H
#define REMI_AIRPLAY_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct remi_airplay remi_airplay;

// Every callback runs on one of UxPlay's threads, never the main thread.
typedef struct {
    void *context;
    void (*log)(void *context, int level, const char *message);
    void (*client_requested)(void *context, const char *device_id, const char *model, const char *name);
    void (*mirroring_changed)(void *context, bool is_running);
    // H.264 only: Remi doesn't advertise H.265, so iPhones never send it.
    void (*video)(void *context, const uint8_t *data, int32_t length);
    void (*connection_lost)(void *context);
    void (*pin_requested)(void *context, const char *pin);
    void (*client_paired)(void *context, const char *device_id, const char *public_key, const char *name);
    bool (*is_client_paired)(void *context, const char *public_key);
} remi_airplay_callbacks;

// Starts the receiver (HTTP server + Bonjour) with PIN pairing required.
// hardware_address is "aa:bb:cc:dd:ee:ff"; keyfile persists the receiver's identity.
// Returns NULL and fills error on failure.
remi_airplay *remi_airplay_start(const char *name, const char *hardware_address, const char *keyfile,
                                 remi_airplay_callbacks callbacks, char *error, size_t error_size);

// Stops the receiver and drops any connection. Must not be called from a callback.
void remi_airplay_stop(remi_airplay *airplay);

#endif
