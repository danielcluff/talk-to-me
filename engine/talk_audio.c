#include "talk_audio.h"

#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define TA_NUM_BUFFERS   3
#define TA_BUFFER_FRAMES 1024

struct ta_player {
    AudioQueueRef       queue;
    AudioQueueBufferRef buffers[TA_NUM_BUFFERS];
    ta_pull_cb          pull;
    void *              user;
    int32_t             channels;
    int32_t             primed;
    atomic_int          running;
};

static void ta_fill(ta_player * p, AudioQueueBufferRef buf) {
    float * out = (float *) buf->mAudioData;
    const size_t frames = TA_BUFFER_FRAMES;
    size_t got = p->pull ? p->pull(p->user, out, frames) : 0;
    if (got > frames) {
        got = frames;
    }
    if (got < frames) {
        memset(out + got * p->channels, 0, (frames - got) * p->channels * sizeof(float));
    }
    buf->mAudioDataByteSize = (UInt32) (frames * p->channels * sizeof(float));
}

static void ta_callback(void * user, AudioQueueRef q, AudioQueueBufferRef buf) {
    ta_player * p = (ta_player *) user;
    ta_fill(p, buf);
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

ta_player * ta_player_create(double sample_rate, int32_t channels, ta_pull_cb pull, void * user, int32_t * status) {
    ta_player * p = (ta_player *) calloc(1, sizeof(ta_player));
    if (!p) {
        return NULL;
    }
    p->pull     = pull;
    p->user     = user;
    p->channels = channels > 0 ? channels : 1;

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = sample_rate;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
    fmt.mChannelsPerFrame = (UInt32) p->channels;
    fmt.mBitsPerChannel   = 32;
    fmt.mBytesPerFrame    = (UInt32) (p->channels * sizeof(float));
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = fmt.mBytesPerFrame;

    // NULL run loop: callbacks arrive on an internal AudioQueue thread.
    OSStatus st = AudioQueueNewOutput(&fmt, ta_callback, p, NULL, NULL, 0, &p->queue);
    if (st == noErr) {
        for (int i = 0; i < TA_NUM_BUFFERS && st == noErr; i++) {
            st = AudioQueueAllocateBuffer(p->queue, (UInt32) (TA_BUFFER_FRAMES * fmt.mBytesPerFrame), &p->buffers[i]);
        }
    }
    if (status) {
        *status = (int32_t) st;
    }
    if (st != noErr) {
        if (p->queue) {
            AudioQueueDispose(p->queue, true);
        }
        free(p);
        return NULL;
    }
    return p;
}

void ta_player_free(ta_player * p) {
    if (!p) {
        return;
    }
    AudioQueueStop(p->queue, true);
    AudioQueueDispose(p->queue, true);
    free(p);
}

int32_t ta_player_start(ta_player * p) {
    if (atomic_load(&p->running)) {
        return 0;
    }
    if (!p->primed) {
        for (int i = 0; i < TA_NUM_BUFFERS; i++) {
            ta_fill(p, p->buffers[i]);
            AudioQueueEnqueueBuffer(p->queue, p->buffers[i], 0, NULL);
        }
        p->primed = 1;
    }
    OSStatus st = AudioQueueStart(p->queue, NULL);
    if (st == noErr) {
        atomic_store(&p->running, 1);
    }
    return (int32_t) st;
}

int32_t ta_player_pause(ta_player * p) {
    if (!atomic_load(&p->running)) {
        return 0;
    }
    OSStatus st = AudioQueuePause(p->queue);
    if (st == noErr) {
        atomic_store(&p->running, 0);
    }
    return (int32_t) st;
}

int32_t ta_player_is_running(const ta_player * p) {
    return atomic_load(&((ta_player *) p)->running);
}
