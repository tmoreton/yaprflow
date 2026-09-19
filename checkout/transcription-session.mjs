const transcriptionModel = 'gpt-4o-transcribe';

export const supportedTranscriptionLanguages = [
  'en', 'es', 'zh', 'hi', 'ar', 'pt', 'fr', 'de', 'ja', 'ko'
];

const supportedLanguageSet = new Set(supportedTranscriptionLanguages);

export function normalizeTranscriptionLanguage(language = 'en') {
  const normalized = typeof language === 'string' ? language.trim().toLowerCase() : '';
  return supportedLanguageSet.has(normalized) ? normalized : 'en';
}

export function createTranscriptionSessionConfig(language = 'en') {
  return {
    type: 'transcription',
    audio: {
      input: {
        transcription: {
          model: transcriptionModel,
          language: normalizeTranscriptionLanguage(language)
        },
        turn_detection: {
          type: 'server_vad',
          threshold: 0.5,
          prefix_padding_ms: 300,
          silence_duration_ms: 500
        }
      }
    }
  };
}
