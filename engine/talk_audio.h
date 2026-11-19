// talk_audio: minimal AudioQueue output for float PCM.
//
// Pull model: AudioQueue's thread calls `pull` whenever a buffer drains; the
// callback copies up to n_frames of interleaved float samples and returns how
// many frames it wrote (the rest of the buffer is zero-filled). Buffers are
// small (~43 ms each, 3 in flight) so a change of cursor (stop, skip, next)
// is heard within ~130 ms without flushing the queue.

#ifndef TALK_AUDIO_H
#define TALK_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ta_player ta_player;

// Called on the AudioQueue thread. Must not block for long.
typedef size_t (*ta_pull_cb)(void * user, float * out, size_t n_frames);

// Returns NULL on failure; *status (optional) receives the OSStatus.
ta_player * ta_player_create(double sample_rate, int32_t channels, ta_pull_cb pull, void * user, int32_t * status);
void        ta_player_free(ta_player * p);

// Prime the buffers (first time) and start or resume the queue. Idempotent.
int32_t     ta_player_start(ta_player * p);
// Pause the hardware queue; enqueued buffers are kept, start() resumes.
int32_t     ta_player_pause(ta_player * p);
int32_t     ta_player_is_running(const ta_player * p);

#ifdef __cplusplus
}
#endif

#endif
