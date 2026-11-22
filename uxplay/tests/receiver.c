#include "receiver.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>

#include "logger.h"
#include "stream.h"

static void on_log(void *cls, int level, const char *message) {
    if (getenv("REMI_TEST_VERBOSE")) {
        fprintf(stderr, "    [uxplay %d] %s\n", level, message);
    }
}

static void on_display_pin(void *cls, char *pin) {
    receiver_t *receiver = cls;
    pthread_mutex_lock(&receiver->lock);
    snprintf(receiver->pin, sizeof(receiver->pin), "%s", pin);
    pthread_mutex_unlock(&receiver->lock);
}

static bool on_check_register(void *cls, const char *public_key) {
    receiver_t *receiver = cls;
    pthread_mutex_lock(&receiver->lock);
    bool is_registered = receiver->registered_key[0] && !strcmp(public_key, receiver->registered_key);
    pthread_mutex_unlock(&receiver->lock);
    return is_registered;
}

// UxPlay calls several callbacks without NULL checks, as in AirPlayShim.c.
static void on_noop(void *cls) {}
static void on_conn_reset(void *cls, int reason) {}
static void on_conn_feedback(void *cls) {}
static void on_video_reset(void *cls, reset_type_t reset_type) {}
static void on_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {}
static void on_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {}
static double on_audio_set_client_volume(void *cls) { return 0.0; }
static void on_audio_set_volume(void *cls, float volume) {}
static void on_audio_set_metadata(void *cls, const void *buffer, int buflen) {}
static void on_audio_set_coverart(void *cls, const void *buffer, int buflen) {}
static void on_audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote) {}
static void on_audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {}
static void on_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *using_screen,
                                bool *is_media, uint64_t *audio_format) {}
static void on_video_report_size(void *cls, float *width_source, float *height_source, float *width, float *height) {}
static void on_mirror_video_running(void *cls, bool is_running) {}
static void on_report_client_request(void *cls, char *device_id, char *model, char *name, bool *admit) {
    *admit = true;
}
static void on_register_client(void *cls, const char *device_id, const char *public_key, const char *name) {}
static const char *on_passwd(void *cls, int *len) {
    *len = 0;
    return NULL;
}
static void on_export_dacp(void *cls, const char *active_remote, const char *dacp_id) {}
static int on_video_set_codec(void *cls, video_codec_t codec) { return 0; }

static raop_callbacks_t build_callbacks(receiver_t *receiver) {
    raop_callbacks_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.cls = receiver;
    callbacks.audio_process = on_audio_process;
    callbacks.video_process = on_video_process;
    callbacks.video_pause = on_noop;
    callbacks.video_resume = on_noop;
    callbacks.conn_feedback = on_conn_feedback;
    callbacks.conn_reset = on_conn_reset;
    callbacks.video_reset = on_video_reset;
    callbacks.conn_init = on_noop;
    callbacks.conn_destroy = on_noop;
    callbacks.audio_flush = on_noop;
    callbacks.video_flush = on_noop;
    callbacks.audio_set_client_volume = on_audio_set_client_volume;
    callbacks.audio_set_volume = on_audio_set_volume;
    callbacks.audio_set_metadata = on_audio_set_metadata;
    callbacks.audio_set_coverart = on_audio_set_coverart;
    callbacks.audio_stop_coverart_rendering = on_noop;
    callbacks.audio_remote_control_id = on_audio_remote_control_id;
    callbacks.audio_set_progress = on_audio_set_progress;
    callbacks.audio_get_format = on_audio_get_format;
    callbacks.video_report_size = on_video_report_size;
    callbacks.mirror_video_running = on_mirror_video_running;
    callbacks.report_client_request = on_report_client_request;
    callbacks.display_pin = on_display_pin;
    callbacks.register_client = on_register_client;
    callbacks.check_register = on_check_register;
    callbacks.passwd = on_passwd;
    callbacks.export_dacp = on_export_dacp;
    callbacks.video_set_codec = on_video_set_codec;
    return callbacks;
}

bool receiver_start(receiver_t *receiver) {
    memset(receiver, 0, sizeof(*receiver));
    pthread_mutex_init(&receiver->lock, NULL);

    char hardware_bytes[6] = {0x02, 0, 0, 0, 0, 0x01};
    int dnssd_error = 0;
    receiver->dnssd = dnssd_init("Remi Test", 9, hardware_bytes, sizeof(hardware_bytes), &dnssd_error, 1);
    raop_callbacks_t callbacks = build_callbacks(receiver);
    receiver->raop = raop_init(&callbacks);
    if (dnssd_error || !receiver->dnssd || !receiver->raop) {
        return false;
    }
    raop_set_log_callback(receiver->raop, on_log, receiver);
    raop_set_log_level(receiver->raop, getenv("REMI_TEST_VERBOSE") ? LOGGER_DEBUG : LOGGER_ERR);
    // An empty keyfile makes a new identity in memory.
    if (raop_init2(receiver->raop, 0, RECEIVER_HARDWARE_ADDRESS, "")) {
        return false;
    }
    raop_set_plist(receiver->raop, "pin", 0);
    unsigned short ports[3] = {0, 0, 0};
    raop_set_tcp_ports(receiver->raop, ports);
    raop_set_udp_ports(receiver->raop, ports);
    receiver->port = raop_get_port(receiver->raop);
    if (raop_start_httpd(receiver->raop, &receiver->port) < 0) {
        return false;
    }
    raop_set_port(receiver->raop, receiver->port);
    raop_set_dnssd(receiver->raop, receiver->dnssd);
    return true;
}

void receiver_stop(receiver_t *receiver) {
    if (receiver->raop) {
        raop_destroy(receiver->raop);
    }
    if (receiver->dnssd) {
        dnssd_destroy(receiver->dnssd);
    }
    pthread_mutex_destroy(&receiver->lock);
}

void receiver_shown_pin(receiver_t *receiver, char pin[5]) {
    pthread_mutex_lock(&receiver->lock);
    memcpy(pin, receiver->pin, 5);
    receiver->pin[0] = '\0';
    pthread_mutex_unlock(&receiver->lock);
}

void receiver_register_client(receiver_t *receiver, const unsigned char public_key[32]) {
    pthread_mutex_lock(&receiver->lock);
    EVP_EncodeBlock((unsigned char *) receiver->registered_key, public_key, 32);
    pthread_mutex_unlock(&receiver->lock);
}
