#include "AirPlayShim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dnssd.h"
#include "logger.h"
#include "raop.h"
#include "stream.h"

// dnssd_init's pin_pw: 1 = the client enters an on-screen PIN the first time it connects.
#define PIN_ACCESS_CONTROL 1
#define HARDWARE_ADDRESS_LENGTH 6
// Tested on iOS 27: a 1920 square still arrives as H.264, which is all Remi decodes.
#define DISPLAY_SIZE 1920

struct remi_airplay {
    raop_t *raop;
    dnssd_t *dnssd;
    remi_airplay_callbacks callbacks;
};

static void on_log(void *cls, int level, const char *message) {
    remi_airplay *airplay = cls;
    airplay->callbacks.log(airplay->callbacks.context, level, message);
}

static void on_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    remi_airplay *airplay = cls;
    if (data->data_len <= 0 || data->is_h265) {
        return;
    }
    airplay->callbacks.video(airplay->callbacks.context, data->data, data->data_len);
}

static void on_mirror_video_running(void *cls, bool is_running) {
    remi_airplay *airplay = cls;
    airplay->callbacks.mirroring_changed(airplay->callbacks.context, is_running);
}

static void on_conn_reset(void *cls, int reason) {
    remi_airplay *airplay = cls;
    airplay->callbacks.connection_lost(airplay->callbacks.context);
}

static void on_report_client_request(void *cls, char *device_id, char *model, char *name, bool *admit) {
    remi_airplay *airplay = cls;
    // Access control happens earlier, in PIN pairing and pair-verify (see uxplay/patches).
    *admit = true;
    airplay->callbacks.client_requested(airplay->callbacks.context, device_id ? device_id : "",
                                        model ? model : "", name ? name : "");
}

static void on_display_pin(void *cls, char *pin) {
    remi_airplay *airplay = cls;
    airplay->callbacks.pin_requested(airplay->callbacks.context, pin);
}

static void on_register_client(void *cls, const char *device_id, const char *public_key, const char *name) {
    remi_airplay *airplay = cls;
    airplay->callbacks.client_paired(airplay->callbacks.context, device_id, public_key, name);
}

static bool on_check_register(void *cls, const char *public_key) {
    remi_airplay *airplay = cls;
    return airplay->callbacks.is_client_paired(airplay->callbacks.context, public_key);
}

static const char *on_passwd(void *cls, int *len) {
    *len = 0;
    return NULL;
}

// UxPlay calls several callbacks without NULL checks, so audio and the rest get no-op stubs.
static void on_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {}
static void on_noop(void *cls) {}
static void on_conn_feedback(void *cls) {}
static void on_video_reset(void *cls, reset_type_t reset_type) {}
static double on_audio_set_client_volume(void *cls) { return 0.0; }
static void on_audio_set_volume(void *cls, float volume) {}
static void on_audio_set_metadata(void *cls, const void *buffer, int buflen) {}
static void on_audio_set_coverart(void *cls, const void *buffer, int buflen) {}
static void on_audio_remote_control_id(void *cls, const char *dacp_id, const char *active_remote) {}
static void on_audio_set_progress(void *cls, uint32_t *start, uint32_t *curr, uint32_t *end) {}
static void on_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf, bool *using_screen,
                                bool *is_media, uint64_t *audio_format) {}
static void on_video_report_size(void *cls, float *width_source, float *height_source, float *width, float *height) {}
static void on_export_dacp(void *cls, const char *active_remote, const char *dacp_id) {}
static int on_video_set_codec(void *cls, video_codec_t codec) { return 0; }

static bool parse_hardware_address(const char *string, char bytes[HARDWARE_ADDRESS_LENGTH]) {
    unsigned int values[HARDWARE_ADDRESS_LENGTH];
    char trailing;
    int count = sscanf(string, "%2x:%2x:%2x:%2x:%2x:%2x%c", &values[0], &values[1], &values[2], &values[3],
                       &values[4], &values[5], &trailing);
    if (count != HARDWARE_ADDRESS_LENGTH) {
        return false;
    }
    for (int i = 0; i < HARDWARE_ADDRESS_LENGTH; i++) {
        bytes[i] = (char) values[i];
    }
    return true;
}

static raop_callbacks_t build_raop_callbacks(remi_airplay *airplay) {
    raop_callbacks_t callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.cls = airplay;
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

static remi_airplay *fail(remi_airplay *airplay, char *error, size_t error_size, const char *message) {
    snprintf(error, error_size, "%s", message);
    remi_airplay_stop(airplay);
    return NULL;
}

remi_airplay *remi_airplay_start(const char *name, const char *hardware_address, const char *keyfile,
                                 remi_airplay_callbacks callbacks, char *error, size_t error_size) {
    char hardware_bytes[HARDWARE_ADDRESS_LENGTH];
    if (!parse_hardware_address(hardware_address, hardware_bytes)) {
        snprintf(error, error_size, "Invalid hardware address");
        return NULL;
    }

    remi_airplay *airplay = calloc(1, sizeof(remi_airplay));
    if (!airplay) {
        snprintf(error, error_size, "Out of memory");
        return NULL;
    }
    airplay->callbacks = callbacks;

    int dnssd_error = 0;
    airplay->dnssd = dnssd_init(name, (int) strlen(name), hardware_bytes, HARDWARE_ADDRESS_LENGTH, &dnssd_error,
                                PIN_ACCESS_CONTROL);
    if (dnssd_error || !airplay->dnssd) {
        airplay->dnssd = NULL;
        return fail(airplay, error, error_size, "Failed to initialize Bonjour");
    }

    raop_callbacks_t raop_callbacks = build_raop_callbacks(airplay);
    airplay->raop = raop_init(&raop_callbacks);
    if (!airplay->raop) {
        return fail(airplay, error, error_size, "Failed to initialize the AirPlay server");
    }
    raop_set_log_callback(airplay->raop, on_log, airplay);
    raop_set_log_level(airplay->raop, LOGGER_INFO);
    if (raop_init2(airplay->raop, 0, hardware_address, keyfile)) {
        free(airplay->raop);
        airplay->raop = NULL;
        return fail(airplay, error, error_size, "Failed to load the AirPlay identity key");
    }

    // A 0 PIN makes UxPlay generate a random one for each pairing attempt.
    raop_set_plist(airplay->raop, "pin", 0);

    // iOS scales its screen to fit the display a receiver advertises. UxPlay's default of
    // 1920x1080 squeezes portrait into 1080 pixels of height; a square gives both orientations 1920.
    raop_set_plist(airplay->raop, "width", DISPLAY_SIZE);
    raop_set_plist(airplay->raop, "height", DISPLAY_SIZE);

    // Port 0 lets the OS choose, which avoids macOS's own AirPlay Receiver on 7000.
    unsigned short tcp_ports[3] = {0, 0, 0};
    unsigned short udp_ports[3] = {0, 0, 0};
    raop_set_tcp_ports(airplay->raop, tcp_ports);
    raop_set_udp_ports(airplay->raop, udp_ports);

    unsigned short port = raop_get_port(airplay->raop);
    if (raop_start_httpd(airplay->raop, &port) < 0) {
        return fail(airplay, error, error_size, "Failed to start the AirPlay server");
    }
    raop_set_port(airplay->raop, port);
    raop_set_dnssd(airplay->raop, airplay->dnssd);

    if (dnssd_register_raop(airplay->dnssd, port) || dnssd_register_airplay(airplay->dnssd, port)) {
        return fail(airplay, error, error_size, "Failed to advertise over Bonjour");
    }
    return airplay;
}

void remi_airplay_stop(remi_airplay *airplay) {
    if (!airplay) {
        return;
    }
    if (airplay->dnssd) {
        dnssd_unregister_raop(airplay->dnssd);
        dnssd_unregister_airplay(airplay->dnssd);
    }
    if (airplay->raop) {
        raop_destroy(airplay->raop);
    }
    if (airplay->dnssd) {
        dnssd_destroy(airplay->dnssd);
    }
    free(airplay);
}
