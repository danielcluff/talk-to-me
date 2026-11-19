// talk_engine: C shim over llama.cpp + libmtmd audio generation.
// The synthesis loop mirrors tools/tts/tts.cpp and the server's process_tts_slots(),
// so model-specific behavior stays inside libmtmd.

#include "talk_engine.h"

#include "chat.h"
#include "common.h"
#include "log.h"
#include "sampling.h"
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <exception>
#include <string>

namespace {

std::atomic<int32_t> g_log_level{0};

void log_cb(enum ggml_log_level level, const char * text, void * /*user*/) {
    const int32_t thold = g_log_level.load();
    int32_t lvl;
    switch (level) {
        case GGML_LOG_LEVEL_ERROR: lvl = 0; break;
        case GGML_LOG_LEVEL_WARN:  lvl = 1; break;
        case GGML_LOG_LEVEL_INFO:  lvl = 2; break;
        case GGML_LOG_LEVEL_CONT:  lvl = 2; break;
        default:                   lvl = 3; break;
    }
    if (lvl <= thold) {
        fputs(text, stderr);
    }
}

void set_err(char * err, size_t err_size, const char * fmt, ...) {
    if (!err || err_size == 0) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_size, fmt, ap);
    va_end(ap);
}

const char * pipeline_name(mtmd_gen_audio_type t) {
    switch (t) {
        case MTMD_GEN_AUDIO_TYPE_QWEN3TTS:       return "qwen3-tts";
        case MTMD_GEN_AUDIO_TYPE_POCKETTTS:      return "pocket-tts";
        case MTMD_GEN_AUDIO_TYPE_SOPRANO:        return "soprano";
        case MTMD_GEN_AUDIO_TYPE_LFM3A:          return "lfm3-audio";
        case MTMD_GEN_AUDIO_TYPE_CHATTERBOX:     return "chatterbox";
        case MTMD_GEN_AUDIO_TYPE_DRAMA3:         return "drama3";
        case MTMD_GEN_AUDIO_TYPE_ZONOS3:         return "zonos3";
        case MTMD_GEN_AUDIO_TYPE_YUE2:           return "yue2";
        case MTMD_GEN_AUDIO_TYPE_MINIMAX_MUSIC3: return "minimax-music3";
        case MTMD_GEN_AUDIO_TYPE_FISH_S2:        return "fish-s2";
        case MTMD_GEN_AUDIO_TYPE_KOKORO:         return "kokoro";
        case MTMD_GEN_AUDIO_TYPE_TINY_VOCA:      return "tiny-voca";
        case MTMD_GEN_AUDIO_TYPE_VOXCPM2:        return "voxcpm2";
        default:                                 return "none";
    }
}

double now_s() {
    return ggml_time_us() / 1e6;
}

} // namespace

struct te_engine {
    common_params                 params;
    common_init_result_ptr        init;
    llama_model *                 model = nullptr;
    llama_context *               lctx  = nullptr;
    common_sampler *              smpl  = nullptr;
    mtmd::context_ptr             mctx;
    common_chat_templates_ptr     tmpls;
    mtmd_helper::gen_audio        gen;
    mtmd_gen_audio_info           info{};
};

extern "C" {

void te_set_log_level(int32_t log_level) {
    g_log_level.store(log_level);
    // common's LOG_* macros go through common_log, not the ggml callback
    common_log_set_verbosity_thold(log_level >= 3 ? 10 : (log_level >= 2 ? 1 : -1));
    llama_log_set(log_cb, nullptr);
    mtmd_helper_log_set(log_cb, nullptr);
}

te_load_params te_load_params_default(void) {
    te_load_params p{};
    p.model_path  = nullptr;
    p.mmproj_path = nullptr;
    p.n_threads   = 0;
    p.use_gpu     = 1;
    return p;
}

te_synth_params te_synth_params_default(void) {
    te_synth_params p{};
    p.text  = nullptr;
    p.voice = nullptr;
    p.lang  = nullptr;
    p.speed = 1.0f;
    p.seed  = UINT32_MAX;
    return p;
}

te_engine * te_load(const te_load_params * lp, char * err, size_t err_size) {
    if (!lp || !lp->model_path || !lp->mmproj_path) {
        set_err(err, err_size, "model_path and mmproj_path are required");
        return nullptr;
    }

    static bool backend_ready = false;
    if (!backend_ready) {
        llama_log_set(log_cb, nullptr);
        mtmd_helper_log_set(log_cb, nullptr);
        llama_backend_init();
        backend_ready = true;
    }

    auto * e = new te_engine();
    try {
        common_params & p = e->params;
        p.model.path  = lp->model_path;
        p.mmproj.path = lp->mmproj_path;
        p.embedding   = true; // pass hidden states to the audio generation helper
        // same sampling defaults as llama-tts (LLAMA_EXAMPLE_TTS)
        p.sampling.penalty_repeat = 1.05f;
        p.sampling.penalty_last_n = -1;
        if (lp->n_threads > 0) {
            p.cpuparams.n_threads       = lp->n_threads;
            p.cpuparams_batch.n_threads = lp->n_threads;
        }
        if (!lp->use_gpu) {
            p.n_gpu_layers   = 0;
            p.mmproj_use_gpu = false;
        }
        // what common_params_parse() does after reading the CLI: resolve
        // n_threads = -1 to the core count (left unresolved, it breaks allocations)
        postprocess_cpu_params(p.cpuparams, nullptr);
        postprocess_cpu_params(p.cpuparams_batch, &p.cpuparams);

        e->init  = common_init_from_params(p);
        e->model = e->init ? e->init->model() : nullptr;
        e->lctx  = e->init ? e->init->context() : nullptr;
        e->smpl  = e->init ? e->init->sampler(0) : nullptr;
        if (!e->model || !e->lctx || !e->smpl) {
            set_err(err, err_size, "failed to load model %s", lp->model_path);
            delete e;
            return nullptr;
        }

        mtmd_context_params mp = mtmd_context_params_default();
        mp.use_gpu = p.mmproj_use_gpu;
        e->mctx.reset(mtmd_init_from_file(lp->mmproj_path, e->model, mp));
        if (!e->mctx) {
            set_err(err, err_size, "failed to load mmproj %s", lp->mmproj_path);
            delete e;
            return nullptr;
        }
        e->info = mtmd_gen_audio_get_info(e->mctx.get());
        if (e->info.type == MTMD_GEN_AUDIO_TYPE_NONE) {
            set_err(err, err_size, "mmproj does not support audio generation");
            delete e;
            return nullptr;
        }

        e->tmpls = common_chat_templates_init(e->model, "");

        e->gen.init(e->lctx, e->mctx.get());
        if (!e->gen.valid()) {
            set_err(err, err_size, "the context cannot run the audio generation of this model");
            delete e;
            return nullptr;
        }
    } catch (const std::exception & ex) {
        set_err(err, err_size, "load failed: %s", ex.what());
        delete e;
        return nullptr;
    }
    return e;
}

void te_free(te_engine * e) {
    delete e;
}

int32_t te_sample_rate(const te_engine * e) { return e ? e->info.sample_rate : 0; }
int32_t te_channels(const te_engine * e)    { return e ? e->info.n_channels : 0; }
const char * te_pipeline_name(const te_engine * e) { return e ? pipeline_name(e->info.type) : "none"; }
int32_t te_voice_count(const te_engine * e) { return e ? e->info.n_voices : 0; }

const char * te_voice_name(const te_engine * e, int32_t idx) {
    return e ? mtmd_gen_audio_voice_name(e->mctx.get(), idx) : nullptr;
}

int32_t te_synthesize(te_engine * e, const te_synth_params * sp,
                      te_audio_cb cb, void * user, te_timings * timings,
                      char * err, size_t err_size) {
    if (!e || !sp || !sp->text) {
        set_err(err, err_size, "engine and text are required");
        return 1;
    }
    te_timings t{};
    const double t0 = now_s();

    try {
        mtmd_context * mctx = e->mctx.get();
        std::string voice = sp->voice ? sp->voice : "";
        const std::string lang = sp->lang ? sp->lang : "";

        // a model with predefined voices needs one, the first by default
        mtmd::bitmap_ptr speaker;
        if (e->info.n_voices > 0) {
            if (voice.empty()) {
                voice = mtmd_gen_audio_voice_name(mctx, 0);
            }
            speaker.reset(mtmd_gen_audio_get_voice(mctx, voice.c_str()));
            if (!speaker) {
                set_err(err, err_size, "unknown voice \"%s\"", voice.c_str());
                return 1;
            }
        }

        // the model's "tts" chat template: normalization + text to phonemes
        const std::string text = sp->text;
        std::string prompt = common_chat_get_tts_prompt(e->tmpls.get(), text, lang, voice,
            [mctx](const std::string & word) {
                char buf[512];
                return mtmd_gen_audio_g2p(mctx, word.c_str(), buf, sizeof(buf)) > 0 ? std::string(buf) : std::string();
            });
        if (prompt.empty()) {
            prompt = text;
        }

        e->gen.reset();
        common_sampler_reset(e->smpl);

        mtmd_helper_gen_audio_inp inp = mtmd_helper_gen_audio_inp_default();
        inp.seq_id      = 0;
        inp.prompt      = prompt.c_str();
        inp.prompt_len  = prompt.size();
        inp.speaker_ref = speaker.get();
        inp.lang        = lang.empty() ? nullptr : lang.c_str();
        inp.top_k       = e->params.sampling.top_k;
        inp.top_p       = e->params.sampling.top_p;
        inp.seed        = sp->seed;
        inp.speed       = sp->speed > 0.0f ? sp->speed : 1.0f;
        inp.out_type    = MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM;

        const int32_t rc = e->gen.set_input(&inp);
        if (rc != 0) {
            set_err(err, err_size, rc == 2 ? "input not supported by this model (speed?)" : "set_input failed");
            return 1;
        }

        for (;;) {
            const int32_t ret = e->gen.step_prompt(llama_n_batch(e->lctx));
            if (ret < 0) {
                set_err(err, err_size, "prompt processing failed");
                return 1;
            }
            if (ret == 0) {
                break;
            }
        }
        const double t1 = now_s();
        t.prompt_s = t1 - t0;

        auto sample = [&]() -> llama_token {
            llama_token tok = common_sampler_sample(e->smpl, e->lctx, -1);
            common_sampler_accept(e->smpl, tok, true);
            return tok;
        };

        const int max_new = e->gen.max_frames(-1);
        llama_token sampled = sample();
        const float * h_state = llama_get_embeddings_ith(e->lctx, -1);
        bool stop = false;
        while (!stop && (max_new <= 0 || t.n_frames < max_new)) {
            const float * h_next = nullptr;
            if (e->gen.step_gen(sampled, h_state, &h_next, &stop) != 0) {
                set_err(err, err_size, "step_gen failed at frame %d", t.n_frames);
                return 1;
            }
            if (!h_next) {
                break;
            }
            t.n_frames++;
            h_state = h_next;
            sampled = sample();
        }
        const double t2 = now_s();
        t.gen_s = t2 - t1;

        int32_t      sample_rate = 0;
        const char * data        = nullptr;
        size_t       data_len    = 0;
        int64_t      n_samples   = 0;
        // like the server: push any buffered codes through the decoder, then collect
        if (e->gen.flush() != 0 || e->gen.get_output(&sample_rate, &data, &data_len, &n_samples) != 0) {
            set_err(err, err_size, "get_output failed");
            return 1;
        }
        const double t3 = now_s();
        t.vocoder_s = t3 - t2;
        t.audio_s   = sample_rate > 0 ? (double) n_samples / sample_rate : 0.0;

        if (timings) {
            *timings = t;
        }
        if (cb && data_len > 0) {
            if (cb(user, reinterpret_cast<const float *>(data), data_len / sizeof(float)) != 0) {
                return 2;
            }
        }
    } catch (const std::exception & ex) {
        set_err(err, err_size, "synthesis failed: %s", ex.what());
        return 1;
    }
    return 0;
}

} // extern "C"
