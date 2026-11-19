// libtalk: the Talk to Me core as a C library, for the macOS app.
//
// The app links libtalk.a plus the engine archive (libtalk_engine_all.a).
// talk_start() runs the same core and local HTTP API as `talktome serve`, so
// the CLI, hooks and the browser extension keep working while the app runs.
// The app itself calls talk_call(), which routes exactly like the HTTP API
// (same paths, same JSON) without a socket or token.

#ifndef TALK_H
#define TALK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Receives every core event as JSON, on a background thread:
//   {"seq":12,"type":"chunk_started","job":"j_3","index":0,"count":5,"state":""}
// types: job_queued job_started chunk_started job_finished player_state model_state
typedef void (*talk_event_cb)(void * user, const char * event_json);

enum {
    TALK_OK            = 0,
    TALK_ERR_SETUP     = 1, // paths or settings could not be loaded
    TALK_ERR_PORT      = 2, // the API port is held by something that would not hand it over
    TALK_ERR_STARTED   = 3, // talk_start was already called
    TALK_ERR_INTERNAL  = 4,
};

// Start the core and the HTTP API on 127.0.0.1:<settings.port>.
// home: the user's home directory, or NULL for $HOME. A running
// `talktome serve` is asked to shut down so the app can take the port.
int32_t talk_start(const char * home, talk_event_cb cb, void * user);

// In-process API call: method "GET" | "POST" | "PATCH" | "DELETE", path like
// "/v1/models", body JSON or NULL. Returns the response JSON (free it with
// talk_free); *status (optional) receives the HTTP status code.
char *  talk_call(const char * method, const char * path, const char * body, int32_t * status);

void    talk_free(char * p);

#ifdef __cplusplus
}
#endif

#endif
