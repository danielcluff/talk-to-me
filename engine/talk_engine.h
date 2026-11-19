// talk_engine: the only C surface over llama.cpp + libmtmd audio generation.
//
// Everything model-specific stays inside libmtmd; this shim ports the generic
// driver loop of llama.cpp's tools/tts/tts.cpp so one engine runs every TTS
// pipeline libmtmd supports. Not thread-safe: one engine per thread.

#ifndef TALK_ENGINE_H
#define TALK_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct te_engine te_engine;

typedef struct {
    const char * model_path;  // backbone GGUF
    const char * mmproj_path; // audio projector / vocoder GGUF
    int32_t      n_threads;   // <= 0: llama.cpp default
    int32_t      use_gpu;     // 0: CPU only, else Metal
} te_load_params;

typedef struct {
    const char * text;  // UTF-8 text to speak (one chunk; the caller splits long text)
    const char * voice; // NULL or "": the model's default voice
    const char * lang;  // NULL or "": the template's default
    float        speed; // <= 0: 1.0
    uint32_t     seed;  // UINT32_MAX: random
} te_synth_params;

typedef struct {
    double prompt_s;  // text preparation + backbone prompt pass
    double gen_s;     // frame generation
    double vocoder_s; // waveform output
    double audio_s;   // seconds of audio produced
    int32_t n_frames;
} te_timings;

// Receives float PCM, channels interleaved. Return non-zero to cancel.
typedef int32_t (*te_audio_cb)(void * user, const float * pcm, size_t n_samples);

// log_level: 0 errors only, 1 + warnings, 2 + info, 3 + debug
void         te_set_log_level(int32_t log_level);

te_load_params te_load_params_default(void);
te_synth_params te_synth_params_default(void);

// Returns NULL on failure, with a message in err.
te_engine *  te_load(const te_load_params * params, char * err, size_t err_size);
void         te_free(te_engine * engine);

int32_t      te_sample_rate(const te_engine * engine);
int32_t      te_channels(const te_engine * engine);
const char * te_pipeline_name(const te_engine * engine);
int32_t      te_voice_count(const te_engine * engine);
const char * te_voice_name(const te_engine * engine, int32_t idx); // idx 0 is the default

// Returns 0 on success, 1 on error (message in err), 2 if cancelled by the callback.
int32_t      te_synthesize(te_engine * engine, const te_synth_params * params,
                           te_audio_cb cb, void * user, te_timings * timings,
                           char * err, size_t err_size);

#ifdef __cplusplus
}
#endif

#endif
