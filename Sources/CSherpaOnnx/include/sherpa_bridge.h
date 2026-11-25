#ifndef SHERPA_BRIDGE_H
#define SHERPA_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TZ_SenseVoiceHandle TZ_SenseVoiceHandle;

TZ_SenseVoiceHandle *tz_sensevoice_create(const char *model_path,
                                          const char *tokens_path,
                                          int32_t num_threads,
                                          const char *language);

/// Creates an offline recognizer for NVIDIA Parakeet TDT 0.6B v2 (English, NeMo transducer, int8).
/// Returns the SAME opaque handle type as tz_sensevoice_create(), so tz_sensevoice_transcribe(),
/// tz_sensevoice_free_string() and tz_sensevoice_destroy() work on it unchanged.
/// Output already carries punctuation and casing. Returns NULL if any path is NULL or the model fails to load.
TZ_SenseVoiceHandle *tz_parakeet_create(const char *encoder_path,
                                        const char *decoder_path,
                                        const char *joiner_path,
                                        const char *tokens_path,
                                        int32_t num_threads);

/// Transcribes mono float PCM samples [-1, 1]. Caller must free returned string with tz_sensevoice_free_string().
char *tz_sensevoice_transcribe(TZ_SenseVoiceHandle *handle,
                               const float *samples,
                               int32_t num_samples,
                               int32_t sample_rate);

void tz_sensevoice_free_string(char *str);

void tz_sensevoice_destroy(TZ_SenseVoiceHandle *handle);

#ifdef __cplusplus
}
#endif

#endif
