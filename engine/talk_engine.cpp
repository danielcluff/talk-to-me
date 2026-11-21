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
#include <memory>
#include <mutex>
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

// The voice, summary and listening models load on different threads (engine,
// briefing, recognizer); the backend is set up once for all of them.
static void init_backend() {
    static std::once_flag once;
    std::call_once(once, [] {
        llama_log_set(log_cb, nullptr);
        mtmd_helper_log_set(log_cb, nullptr);
        llama_backend_init();
    });
}

te_engine * te_load(const te_load_params * lp, char * err, size_t err_size) {
    if (!lp || !lp->model_path || !lp->mmproj_path) {
        set_err(err, err_size, "model_path and mmproj_path are required");
        return nullptr;
    }

    init_backend();

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

// ---------------------------------------------------------------- text generation

struct te_llm {
    llama_model *             model = nullptr;
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr tmpls;
};

te_llm * te_llm_load(const char * model_path, int32_t use_gpu, char * err, size_t err_size) {
    if (!model_path) {
        set_err(err, err_size, "model_path is required");
        return nullptr;
    }
    init_backend();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = use_gpu ? 999 : 0;
    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) {
        set_err(err, err_size, "failed to load %s", model_path);
        return nullptr;
    }
    auto * llm = new te_llm();
    llm->model = model;
    llm->vocab = llama_model_get_vocab(model);
    try {
        llm->tmpls = common_chat_templates_init(model, "");
    } catch (const std::exception & ex) {
        set_err(err, err_size, "chat template: %s", ex.what());
        te_llm_free(llm);
        return nullptr;
    }
    return llm;
}

void te_llm_free(te_llm * llm) {
    if (!llm) return;
    if (llm->model) llama_model_free(llm->model);
    delete llm;
}

static void llm_batch(llama_batch_ext * batch, const llama_token * tokens, int32_t n, llama_pos pos0) {
    llama_batch_ext_clear(batch);
    for (int32_t i = 0; i < n; ++i) {
        const int32_t idx = llama_batch_ext_add_token(batch, 0, tokens[i]);
        const llama_pos pos = pos0 + i;
        llama_batch_ext_set_pos(batch, idx, &pos);
    }
    llama_batch_ext_set_output_logits(batch, n - 1, true);
}

int32_t te_llm_generate(te_llm * llm, const char * user_message, int32_t max_tokens,
                        char * out, size_t out_size, char * err, size_t err_size) {
    if (!llm || !user_message || !out || out_size == 0) {
        set_err(err, err_size, "bad arguments");
        return -1;
    }
    out[0] = 0;
    try {
        common_chat_templates_inputs inputs;
        common_chat_msg msg;
        msg.role = "user";
        msg.content = user_message;
        inputs.messages.push_back(msg);
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = false; // Qwen3: answer directly
        const std::string prompt = common_chat_templates_apply(llm->tmpls.get(), inputs).prompt.str();

        std::vector<llama_token> tokens = common_tokenize(llm->vocab, prompt, true, true);
        const int32_t n_max = max_tokens > 0 ? max_tokens : 200;
        const int32_t n_ctx_train = llama_model_n_ctx_train(llm->model);
        if ((int32_t) tokens.size() + n_max > n_ctx_train) {
            set_err(err, err_size, "report too long for the model (%d tokens)", (int) tokens.size());
            return -1;
        }

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = (uint32_t) (tokens.size() + n_max + 16);
        cp.n_batch = (uint32_t) tokens.size();
        cp.no_perf = true;
        // owned, so an exception below (tokenizing a piece, appending) frees them
        std::unique_ptr<llama_context, decltype(&llama_free)> ctx_owner(llama_init_from_model(llm->model, cp), &llama_free);
        llama_context * ctx = ctx_owner.get();
        if (!ctx) {
            set_err(err, err_size, "failed to create a context");
            return -1;
        }

        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> smpl_owner(
            llama_sampler_chain_init(llama_sampler_chain_default_params()), &llama_sampler_free);
        llama_sampler * smpl = smpl_owner.get();
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.3f));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(42));

        std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch_owner(llama_batch_ext_init(ctx), &llama_batch_ext_free);
        llama_batch_ext * batch = batch_owner.get();
        llm_batch(batch, tokens.data(), (int32_t) tokens.size(), 0);
        llama_pos pos = (llama_pos) tokens.size();
        std::string reply;
        int32_t rc = 0;
        for (int32_t i = 0; i < n_max; ++i) {
            if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0) {
                set_err(err, err_size, "decode failed");
                rc = -1;
                break;
            }
            const llama_token t = llama_sampler_sample(smpl, ctx, -1);
            if (llama_vocab_is_eog(llm->vocab, t)) break;
            reply += common_token_to_piece(llm->vocab, t, false);
            llm_batch(batch, &t, 1, pos++);
        }
        if (rc != 0) return rc;

        const size_t n = std::min(reply.size(), out_size - 1);
        memcpy(out, reply.data(), n);
        out[n] = 0;
        return (int32_t) n;
    } catch (const std::exception & ex) {
        set_err(err, err_size, "generation failed: %s", ex.what());
        return -1;
    }
}

// ---------------------------------------------------------------- speech recognition

struct te_asr {
    llama_model *             model = nullptr;
    const llama_vocab *       vocab = nullptr;
    mtmd::context_ptr         mctx;
    common_chat_templates_ptr tmpls;
};

te_asr * te_asr_load(const char * model_path, const char * mmproj_path, int32_t use_gpu, char * err, size_t err_size) {
    if (!model_path || !mmproj_path) {
        set_err(err, err_size, "model_path and mmproj_path are required");
        return nullptr;
    }
    init_backend();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = use_gpu ? 999 : 0;
    llama_model * model = llama_model_load_from_file(model_path, mp);
    if (!model) {
        set_err(err, err_size, "failed to load %s", model_path);
        return nullptr;
    }
    auto * asr = new te_asr();
    asr->model = model;
    asr->vocab = llama_model_get_vocab(model);
    mtmd_context_params cp = mtmd_context_params_default();
    cp.use_gpu = use_gpu != 0;
    asr->mctx.reset(mtmd_init_from_file(mmproj_path, model, cp));
    if (!asr->mctx || !mtmd_support_audio(asr->mctx.get())) {
        set_err(err, err_size, "%s is not an audio projector", mmproj_path);
        te_asr_free(asr);
        return nullptr;
    }
    try {
        asr->tmpls = common_chat_templates_init(model, "");
    } catch (const std::exception & ex) {
        set_err(err, err_size, "chat template: %s", ex.what());
        te_asr_free(asr);
        return nullptr;
    }
    return asr;
}

void te_asr_free(te_asr * asr) {
    if (!asr) return;
    asr->mctx.reset();
    if (asr->model) llama_model_free(asr->model);
    delete asr;
}

int32_t te_asr_sample_rate(const te_asr * asr) {
    return asr ? mtmd_get_audio_sample_rate(asr->mctx.get()) : 0;
}

int32_t te_asr_transcribe(te_asr * asr, const float * pcm, size_t n_samples, const char * hint,
                          char * out, size_t out_size, char * err, size_t err_size) {
    if (!asr || !pcm || n_samples == 0 || !out || out_size == 0) {
        set_err(err, err_size, "bad arguments");
        return -1;
    }
    out[0] = 0;
    llama_context * ctx = nullptr;
    llama_sampler * smpl = nullptr;
    llama_batch_ext * batch = nullptr;
    mtmd_input_chunks * chunks = nullptr;
    mtmd_bitmap * bitmap = nullptr;
    int32_t rc = 0;
    try {
        // the model's transcription prompt, with hint words where the model takes them
        const double seconds = (double) n_samples / (double) mtmd_get_audio_sample_rate(asr->mctx.get());
        const std::string hints = hint ? hint : "";
        common_chat_prompt_preset preset = common_chat_get_asr_prompt(asr->tmpls.get(), "en", 0.0, hints);
        if (preset.needs_audio_length) preset = common_chat_get_asr_prompt(asr->tmpls.get(), "en", seconds, hints);
        if (!preset.has_context && !hints.empty()) {
            preset = common_chat_get_asr_prompt(asr->tmpls.get(), "en", preset.needs_audio_length ? seconds : 0.0, "");
        }
        const std::string marker = mtmd_default_marker();
        const std::string user = preset.media_first ? marker + preset.user : preset.user + marker;

        common_chat_templates_inputs inputs;
        if (!preset.system.empty()) {
            common_chat_msg sys;
            sys.role = "system";
            sys.content = preset.system;
            inputs.messages.push_back(sys);
        }
        common_chat_msg msg;
        msg.role = "user";
        msg.content = user;
        inputs.messages.push_back(msg);
        inputs.add_generation_prompt = true;
        inputs.use_jinja = true;
        inputs.enable_thinking = false;
        const std::string prompt = common_chat_templates_apply(asr->tmpls.get(), inputs).prompt.str();

        llama_context_params lp = llama_context_default_params();
        lp.n_ctx = 4096;
        lp.n_batch = 2048;
        lp.no_perf = true;
        ctx = llama_init_from_model(asr->model, lp);
        if (!ctx) throw std::runtime_error("failed to create a context");

        bitmap = mtmd_bitmap_init_from_audio(n_samples, pcm);
        chunks = mtmd_input_chunks_init();
        mtmd_input_text text{ prompt.c_str(), prompt.size(), true, true };
        const mtmd_bitmap * bitmaps[] = { bitmap };
        if (mtmd_tokenize(asr->mctx.get(), chunks, &text, bitmaps, 1) != 0) throw std::runtime_error("tokenize failed");
        llama_pos n_past = 0;
        if (mtmd_helper_eval_chunks(asr->mctx.get(), ctx, chunks, 0, 0, (int32_t) lp.n_batch, true, &n_past) != 0) {
            throw std::runtime_error("audio evaluation failed");
        }

        smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
        batch = llama_batch_ext_init(ctx);
        std::string transcript;
        for (int i = 0; i < 64; ++i) {
            const llama_token t = llama_sampler_sample(smpl, ctx, -1);
            if (llama_vocab_is_eog(asr->vocab, t)) break;
            transcript += common_token_to_piece(asr->vocab, t, false);
            llm_batch(batch, &t, 1, n_past++);
            if (llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0) throw std::runtime_error("decode failed");
        }
        const size_t n = std::min(transcript.size(), out_size - 1);
        memcpy(out, transcript.data(), n);
        out[n] = 0;
        rc = (int32_t) n;
    } catch (const std::exception & ex) {
        set_err(err, err_size, "transcription failed: %s", ex.what());
        rc = -1;
    }
    if (batch) llama_batch_ext_free(batch);
    if (smpl) llama_sampler_free(smpl);
    if (chunks) mtmd_input_chunks_free(chunks);
    if (bitmap) mtmd_bitmap_free(bitmap);
    if (ctx) llama_free(ctx);
    return rc;
}

} // extern "C"
