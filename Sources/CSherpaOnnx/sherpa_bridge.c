#include "sherpa_bridge.h"
#include "../c-api-internal/c-api.h"
#include <stdlib.h>
#include <string.h>

struct TZ_SenseVoiceHandle {
    const SherpaOnnxOfflineRecognizer *recognizer;
};

TZ_SenseVoiceHandle *tz_sensevoice_create(const char *model_path,
                                          const char *tokens_path,
                                          int32_t num_threads,
                                          const char *language) {
    if (!model_path || !tokens_path) {
        return NULL;
    }

    const char *effective_lang = (language && language[0] != '\0') ? language : "auto";

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.sense_voice.model = model_path;
    // Follow user speechLocale ("auto" by default so English dictation is never forced into Chinese phonemes!)
    config.model_config.sense_voice.language = effective_lang;
    config.model_config.sense_voice.use_itn = 1;
    config.model_config.tokens = tokens_path;
    config.model_config.num_threads = num_threads > 0 ? num_threads : 4;
    config.model_config.debug = 0;
    config.model_config.provider = "cpu";

    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *rec = SherpaOnnxCreateOfflineRecognizer(&config);
    if (!rec) {
        return NULL;
    }

    TZ_SenseVoiceHandle *h = (TZ_SenseVoiceHandle *)calloc(1, sizeof(TZ_SenseVoiceHandle));
    if (!h) {
        SherpaOnnxDestroyOfflineRecognizer(rec);
        return NULL;
    }
    h->recognizer = rec;
    return h;
}

TZ_SenseVoiceHandle *tz_parakeet_create(const char *encoder_path,
                                        const char *decoder_path,
                                        const char *joiner_path,
                                        const char *tokens_path,
                                        int32_t num_threads) {
    if (!encoder_path || !decoder_path || !joiner_path || !tokens_path) {
        return NULL;
    }

    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));

    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;

    config.model_config.transducer.encoder = encoder_path;
    config.model_config.transducer.decoder = decoder_path;
    config.model_config.transducer.joiner = joiner_path;
    config.model_config.tokens = tokens_path;
    // NeMo TDT checkpoints are exported as "nemo_transducer" in sherpa-onnx.
    config.model_config.model_type = "nemo_transducer";
    // Benchmarked on Apple Silicon: 4 threads decode as fast as 8 (7s audio in ~0.16s).
    config.model_config.num_threads = num_threads > 0 ? num_threads : 4;
    config.model_config.debug = 0;
    config.model_config.provider = "cpu";

    config.decoding_method = "greedy_search";

    const SherpaOnnxOfflineRecognizer *rec = SherpaOnnxCreateOfflineRecognizer(&config);
    if (!rec) {
        return NULL;
    }

    TZ_SenseVoiceHandle *h = (TZ_SenseVoiceHandle *)calloc(1, sizeof(TZ_SenseVoiceHandle));
    if (!h) {
        SherpaOnnxDestroyOfflineRecognizer(rec);
        return NULL;
    }
    h->recognizer = rec;
    return h;
}

char *tz_sensevoice_transcribe(TZ_SenseVoiceHandle *handle,
                               const float *samples,
                               int32_t num_samples,
                               int32_t sample_rate) {
    if (!handle || !handle->recognizer || !samples || num_samples <= 0) {
        return strdup("");
    }

    const SherpaOnnxOfflineStream *stream = SherpaOnnxCreateOfflineStream(handle->recognizer);
    if (!stream) {
        return strdup("");
    }

    SherpaOnnxAcceptWaveformOffline(stream, sample_rate, samples, num_samples);
    SherpaOnnxDecodeOfflineStream(handle->recognizer, stream);

    const SherpaOnnxOfflineRecognizerResult *result = SherpaOnnxGetOfflineStreamResult(stream);
    char *out = NULL;
    if (result && result->text) {
        out = strdup(result->text);
    } else {
        out = strdup("");
    }

    if (result) {
        SherpaOnnxDestroyOfflineRecognizerResult(result);
    }
    SherpaOnnxDestroyOfflineStream(stream);
    return out;
}

void tz_sensevoice_free_string(char *str) {
    if (str) {
        free(str);
    }
}

void tz_sensevoice_destroy(TZ_SenseVoiceHandle *handle) {
    if (!handle) return;
    if (handle->recognizer) {
        SherpaOnnxDestroyOfflineRecognizer(handle->recognizer);
    }
    free(handle);
}
