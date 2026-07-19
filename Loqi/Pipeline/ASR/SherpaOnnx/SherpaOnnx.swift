/// swift-api-examples/SherpaOnnx.swift
/// Copyright (c)  2023  Xiaomi Corporation

import Foundation  // For NSString

/// Convert a String from swift to a `const char*` so that we can pass it to
/// the C language.
///
/// - Parameters:
///   - s: The String to convert.
/// - Returns: A pointer that can be passed to C as `const char*`

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

func sherpaOnnxFeatureConfig(
  sampleRate: Int = 16000,
  featureDim: Int = 80
) -> SherpaOnnxFeatureConfig {
  return SherpaOnnxFeatureConfig(
    sample_rate: Int32(sampleRate),
    feature_dim: Int32(featureDim)
  )
}

func sherpaOnnxHomophoneReplacerConfig(
  dictDir: String = "",
  lexicon: String = "",
  ruleFsts: String = ""
) -> SherpaOnnxHomophoneReplacerConfig {
  return SherpaOnnxHomophoneReplacerConfig(
    dict_dir: toCPointer(dictDir),
    lexicon: toCPointer(lexicon),
    rule_fsts: toCPointer(ruleFsts)
  )
}

// For offline APIs

func sherpaOnnxOfflineTransducerModelConfig(
  encoder: String = "",
  decoder: String = "",
  joiner: String = ""
) -> SherpaOnnxOfflineTransducerModelConfig {
  return SherpaOnnxOfflineTransducerModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    joiner: toCPointer(joiner)
  )
}

func sherpaOnnxOfflineParaformerModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineParaformerModelConfig {
  return SherpaOnnxOfflineParaformerModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineZipformerCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineZipformerCtcModelConfig {
  return SherpaOnnxOfflineZipformerCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWenetCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineWenetCtcModelConfig {
  return SherpaOnnxOfflineWenetCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
  return SherpaOnnxOfflineOmnilingualAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineMedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineMedAsrCtcModelConfig {
  return SherpaOnnxOfflineMedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineFireRedAsrCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineFireRedAsrCtcModelConfig {
  return SherpaOnnxOfflineFireRedAsrCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineNemoEncDecCtcModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineNemoEncDecCtcModelConfig {
  return SherpaOnnxOfflineNemoEncDecCtcModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineDolphinModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineDolphinModelConfig {
  return SherpaOnnxOfflineDolphinModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineWhisperModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  task: String = "transcribe",
  tailPaddings: Int = -1,
  enableTokenTimestamps: Bool = false,
  enableSegmentTimestamps: Bool = false
) -> SherpaOnnxOfflineWhisperModelConfig {
  return SherpaOnnxOfflineWhisperModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    task: toCPointer(task),
    tail_paddings: Int32(tailPaddings),
    enable_token_timestamps: enableTokenTimestamps ? 1 : 0,
    enable_segment_timestamps: enableSegmentTimestamps ? 1 : 0
  )
}

func sherpaOnnxOfflineCanaryModelConfig(
  encoder: String = "",
  decoder: String = "",
  srcLang: String = "en",
  tgtLang: String = "en",
  usePnc: Bool = true
) -> SherpaOnnxOfflineCanaryModelConfig {
  return SherpaOnnxOfflineCanaryModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    src_lang: toCPointer(srcLang),
    tgt_lang: toCPointer(tgtLang),
    use_pnc: usePnc ? 1 : 0
  )
}

func sherpaOnnxOfflineCohereTranscribeModelConfig(
  encoder: String = "",
  decoder: String = "",
  language: String = "",
  usePunct: Bool = true,
  useInverseTextNormalization: Bool = true
) -> SherpaOnnxOfflineCohereTranscribeModelConfig {
  return SherpaOnnxOfflineCohereTranscribeModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    language: toCPointer(language),
    use_punct: usePunct ? 1 : 0,
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineFireRedAsrModelConfig(
  encoder: String = "",
  decoder: String = ""
) -> SherpaOnnxOfflineFireRedAsrModelConfig {
  return SherpaOnnxOfflineFireRedAsrModelConfig(
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder)
  )
}

// there are two versions of Moonshine
// For v1, you need four models: preprocessor, encoder, uncachedDecoder, cachedDecoder
// For v2, you need two models: encoder, mergedDecoder
func sherpaOnnxOfflineMoonshineModelConfig(
  preprocessor: String = "",
  encoder: String = "",
  uncachedDecoder: String = "",
  cachedDecoder: String = "",
  mergedDecoder: String = ""
) -> SherpaOnnxOfflineMoonshineModelConfig {
  return SherpaOnnxOfflineMoonshineModelConfig(
    preprocessor: toCPointer(preprocessor),
    encoder: toCPointer(encoder),
    uncached_decoder: toCPointer(uncachedDecoder),
    cached_decoder: toCPointer(cachedDecoder),
    merged_decoder: toCPointer(mergedDecoder)
  )
}

func sherpaOnnxOfflineQwen3ASRModelConfig(
  convFrontend: String = "",
  encoder: String = "",
  decoder: String = "",
  tokenizer: String = "",
  maxTotalLen: Int = 512,
  maxNewTokens: Int = 128,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  hotwords: String = ""
) -> SherpaOnnxOfflineQwen3ASRModelConfig {
  return SherpaOnnxOfflineQwen3ASRModelConfig(
    conv_frontend: toCPointer(convFrontend),
    encoder: toCPointer(encoder),
    decoder: toCPointer(decoder),
    tokenizer: toCPointer(tokenizer),
    max_total_len: Int32(maxTotalLen),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineTdnnModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineTdnnModelConfig {
  return SherpaOnnxOfflineTdnnModelConfig(
    model: toCPointer(model)
  )
}

func sherpaOnnxOfflineSenseVoiceModelConfig(
  model: String = "",
  language: String = "",
  useInverseTextNormalization: Bool = false
) -> SherpaOnnxOfflineSenseVoiceModelConfig {
  return SherpaOnnxOfflineSenseVoiceModelConfig(
    model: toCPointer(model),
    language: toCPointer(language),
    use_itn: useInverseTextNormalization ? 1 : 0
  )
}

func sherpaOnnxOfflineLMConfig(
  model: String = "",
  scale: Float = 1.0
) -> SherpaOnnxOfflineLMConfig {
  return SherpaOnnxOfflineLMConfig(
    model: toCPointer(model),
    scale: scale
  )
}

func sherpaOnnxOfflineFunASRNanoModelConfig(
  encoderAdaptor: String = "",
  llm: String = "",
  embedding: String = "",
  tokenizer: String = "",
  systemPrompt: String = "You are a helpful assistant.",
  userPrompt: String = "语音转写：",
  maxNewTokens: Int = 512,
  temperature: Float = 1e-6,
  topP: Float = 0.8,
  seed: Int = 42,
  language: String = "",
  itn: Bool = true,
  hotwords: String = ""
) -> SherpaOnnxOfflineFunASRNanoModelConfig {
  return SherpaOnnxOfflineFunASRNanoModelConfig(
    encoder_adaptor: toCPointer(encoderAdaptor),
    llm: toCPointer(llm),
    embedding: toCPointer(embedding),
    tokenizer: toCPointer(tokenizer),
    system_prompt: toCPointer(systemPrompt),
    user_prompt: toCPointer(userPrompt),
    max_new_tokens: Int32(maxNewTokens),
    temperature: temperature,
    top_p: topP,
    seed: Int32(seed),
    language: toCPointer(language),
    itn: itn ? 1 : 0,
    hotwords: toCPointer(hotwords)
  )
}

func sherpaOnnxOfflineModelConfig(
  tokens: String,
  transducer: SherpaOnnxOfflineTransducerModelConfig = sherpaOnnxOfflineTransducerModelConfig(),
  paraformer: SherpaOnnxOfflineParaformerModelConfig = sherpaOnnxOfflineParaformerModelConfig(),
  nemoCtc: SherpaOnnxOfflineNemoEncDecCtcModelConfig = sherpaOnnxOfflineNemoEncDecCtcModelConfig(),
  whisper: SherpaOnnxOfflineWhisperModelConfig = sherpaOnnxOfflineWhisperModelConfig(),
  tdnn: SherpaOnnxOfflineTdnnModelConfig = sherpaOnnxOfflineTdnnModelConfig(),
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  modelType: String = "",
  modelingUnit: String = "cjkchar",
  bpeVocab: String = "",
  teleSpeechCtc: String = "",
  senseVoice: SherpaOnnxOfflineSenseVoiceModelConfig = sherpaOnnxOfflineSenseVoiceModelConfig(),
  moonshine: SherpaOnnxOfflineMoonshineModelConfig = sherpaOnnxOfflineMoonshineModelConfig(),
  fireRedAsr: SherpaOnnxOfflineFireRedAsrModelConfig = sherpaOnnxOfflineFireRedAsrModelConfig(),
  dolphin: SherpaOnnxOfflineDolphinModelConfig = sherpaOnnxOfflineDolphinModelConfig(),
  zipformerCtc: SherpaOnnxOfflineZipformerCtcModelConfig =
    sherpaOnnxOfflineZipformerCtcModelConfig(),
  canary: SherpaOnnxOfflineCanaryModelConfig = sherpaOnnxOfflineCanaryModelConfig(),
  wenetCtc: SherpaOnnxOfflineWenetCtcModelConfig =
    sherpaOnnxOfflineWenetCtcModelConfig(),
  omnilingual: SherpaOnnxOfflineOmnilingualAsrCtcModelConfig =
    sherpaOnnxOfflineOmnilingualAsrCtcModelConfig(),
  medasr: SherpaOnnxOfflineMedAsrCtcModelConfig =
    sherpaOnnxOfflineMedAsrCtcModelConfig(),
  funasrNano: SherpaOnnxOfflineFunASRNanoModelConfig =
    sherpaOnnxOfflineFunASRNanoModelConfig(),
  fireRedAsrCtc: SherpaOnnxOfflineFireRedAsrCtcModelConfig =
    sherpaOnnxOfflineFireRedAsrCtcModelConfig(),
  qwen3Asr: SherpaOnnxOfflineQwen3ASRModelConfig =
    sherpaOnnxOfflineQwen3ASRModelConfig(),
  cohereTranscribe: SherpaOnnxOfflineCohereTranscribeModelConfig =
    sherpaOnnxOfflineCohereTranscribeModelConfig()
) -> SherpaOnnxOfflineModelConfig {
  return SherpaOnnxOfflineModelConfig(
    transducer: transducer,
    paraformer: paraformer,
    nemo_ctc: nemoCtc,
    whisper: whisper,
    tdnn: tdnn,
    tokens: toCPointer(tokens),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider),
    model_type: toCPointer(modelType),
    modeling_unit: toCPointer(modelingUnit),
    bpe_vocab: toCPointer(bpeVocab),
    telespeech_ctc: toCPointer(teleSpeechCtc),
    sense_voice: senseVoice,
    moonshine: moonshine,
    fire_red_asr: fireRedAsr,
    dolphin: dolphin,
    zipformer_ctc: zipformerCtc,
    canary: canary,
    wenet_ctc: wenetCtc,
    omnilingual: omnilingual,
    medasr: medasr,
    funasr_nano: funasrNano,
    fire_red_asr_ctc: fireRedAsrCtc,
    qwen3_asr: qwen3Asr,
    cohere_transcribe: cohereTranscribe
  )
}

func sherpaOnnxOfflineRecognizerConfig(
  featConfig: SherpaOnnxFeatureConfig,
  modelConfig: SherpaOnnxOfflineModelConfig,
  lmConfig: SherpaOnnxOfflineLMConfig = sherpaOnnxOfflineLMConfig(),
  decodingMethod: String = "greedy_search",
  maxActivePaths: Int = 4,
  hotwordsFile: String = "",
  hotwordsScore: Float = 1.5,
  ruleFsts: String = "",
  ruleFars: String = "",
  blankPenalty: Float = 0.0,
  hr: SherpaOnnxHomophoneReplacerConfig = sherpaOnnxHomophoneReplacerConfig()
) -> SherpaOnnxOfflineRecognizerConfig {
  return SherpaOnnxOfflineRecognizerConfig(
    feat_config: featConfig,
    model_config: modelConfig,
    lm_config: lmConfig,
    decoding_method: toCPointer(decodingMethod),
    max_active_paths: Int32(maxActivePaths),
    hotwords_file: toCPointer(hotwordsFile),
    hotwords_score: hotwordsScore,
    rule_fsts: toCPointer(ruleFsts),
    rule_fars: toCPointer(ruleFars),
    blank_penalty: blankPenalty,
    hr: hr
  )
}

class SherpaOnnxOfflineRecongitionResult {
  /// A pointer to the underlying counterpart in C
  let result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>

  private lazy var _text: String = {
    guard let cstr = result.pointee.text else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _timestamps: [Float] = {
    guard let p = result.pointee.timestamps else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _durations: [Float] = {
    guard let p = result.pointee.durations else { return [] }
    return (0..<result.pointee.count).map { p[Int($0)] }
  }()

  private lazy var _lang: String = {
    guard let cstr = result.pointee.lang else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _emotion: String = {
    guard let cstr = result.pointee.emotion else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _event: String = {
    guard let cstr = result.pointee.event else { return "" }
    return String(cString: cstr)
  }()

  private lazy var _segmentTimestamps: [Float] = {
    guard let p = result.pointee.segment_timestamps else { return [] }
    return (0..<result.pointee.segment_count).map { p[Int($0)] }
  }()

  private lazy var _segmentDurations: [Float] = {
    guard let p = result.pointee.segment_durations else { return [] }
    return (0..<result.pointee.segment_count).map { p[Int($0)] }
  }()

  private lazy var _segmentTexts: [String] = {
    guard let arr = result.pointee.segment_texts_arr else { return [] }
    return (0..<result.pointee.segment_count).compactMap { idx -> String? in
      guard let ptr = arr[Int(idx)] else { return nil }
      return String(cString: ptr)
    }
  }()

  /// Return the actual recognition result.
  /// For English models, it contains words separated by spaces.
  /// For Chinese models, it contains Chinese words.
  var text: String { _text }
  var count: Int { Int(result.pointee.count) }
  var timestamps: [Float] { _timestamps }

  // Non-empty for TDT models. Empty for all other non-TDT models
  var durations: [Float] { _durations }

  // For SenseVoice models, it can be zh, en, ja, yue, ko
  // where zh is for Chinese
  // en is for English
  // ja is for Japanese
  // yue is for Cantonese
  // ko is for Korean
  var lang: String { _lang }

  // for SenseVoice models
  var emotion: String { _emotion }

  // for SenseVoice models
  var event: String { _event }

  // Segment-level timestamps (for Whisper with segment timestamps enabled)
  var segmentCount: Int { Int(result.pointee.segment_count) }
  var segmentTimestamps: [Float] { _segmentTimestamps }
  var segmentDurations: [Float] { _segmentDurations }
  var segmentTexts: [String] { _segmentTexts }

  init(result: UnsafePointer<SherpaOnnxOfflineRecognizerResult>) {
    self.result = result
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizerResult(result)
  }
}

class SherpaOnnxOfflineRecognizer {
  /// A pointer to the underlying counterpart in C
  private let recognizer: OpaquePointer

  init(
    config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>
  ) {
    guard let ptr = SherpaOnnxCreateOfflineRecognizer(config) else {
      fatalError("Failed to create SherpaOnnxOfflineRecognizer")
    }
    self.recognizer = ptr
  }

  deinit {
    SherpaOnnxDestroyOfflineRecognizer(recognizer)
  }

  /// Decode wave samples.
  ///
  /// - Parameters:
  ///   - samples: Audio samples normalized to the range [-1, 1]
  ///   - sampleRate: Sample rate of the input audio samples. Must match
  ///                 the one expected by the model.
  func decode(samples: [Float], sampleRate: Int = 16_000) -> SherpaOnnxOfflineRecongitionResult {
    let stream = createStream()
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate)
    decode(stream: stream)
    return getResult(stream: stream)
  }

  func setConfig(config: UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) {
    SherpaOnnxOfflineRecognizerSetConfig(recognizer, config)
  }

  func createStream() -> SherpaOnnxOfflineStreamWrapper {
    guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
      fatalError("Failed to create offline stream")
    }

    return SherpaOnnxOfflineStreamWrapper(stream: stream)
  }

  func decode(stream: SherpaOnnxOfflineStreamWrapper) {
    SherpaOnnxDecodeOfflineStream(recognizer, stream.stream)
  }

  func getResult(stream: SherpaOnnxOfflineStreamWrapper) -> SherpaOnnxOfflineRecongitionResult {
    guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream.stream) else {
      fatalError("Failed to get offline recognition result")
    }

    return SherpaOnnxOfflineRecongitionResult(result: resultPtr)
  }
}

class SherpaOnnxOfflineStreamWrapper {
  let stream: OpaquePointer

  init(stream: OpaquePointer) {
    self.stream = stream
  }

  deinit {
    SherpaOnnxDestroyOfflineStream(stream)
  }

  func setOption(key: String, value: String) {
    SherpaOnnxOfflineStreamSetOption(stream, toCPointer(key), toCPointer(value))
  }

  func acceptWaveform(samples: [Float], sampleRate: Int = 16_000) {
    SherpaOnnxAcceptWaveformOffline(stream, Int32(sampleRate), samples, Int32(samples.count))
  }
}

func sherpaOnnxSileroVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 512,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxSileroVadModelConfig {
  return SherpaOnnxSileroVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

func sherpaOnnxTenVadModelConfig(
  model: String = "",
  threshold: Float = 0.5,
  minSilenceDuration: Float = 0.25,
  minSpeechDuration: Float = 0.5,
  windowSize: Int = 256,
  maxSpeechDuration: Float = 5.0
) -> SherpaOnnxTenVadModelConfig {
  return SherpaOnnxTenVadModelConfig(
    model: toCPointer(model),
    threshold: threshold,
    min_silence_duration: minSilenceDuration,
    min_speech_duration: minSpeechDuration,
    window_size: Int32(windowSize),
    max_speech_duration: maxSpeechDuration
  )
}

func sherpaOnnxVadModelConfig(
  sileroVad: SherpaOnnxSileroVadModelConfig = sherpaOnnxSileroVadModelConfig(),
  sampleRate: Int32 = 16000,
  numThreads: Int = 1,
  provider: String = "cpu",
  debug: Int = 0,
  tenVad: SherpaOnnxTenVadModelConfig = sherpaOnnxTenVadModelConfig()
) -> SherpaOnnxVadModelConfig {
  return SherpaOnnxVadModelConfig(
    silero_vad: sileroVad,
    sample_rate: sampleRate,
    num_threads: Int32(numThreads),
    provider: toCPointer(provider),
    debug: Int32(debug),
    ten_vad: tenVad
  )
}


class SherpaOnnxSpeechSegmentWrapper {
  private let p: UnsafePointer<SherpaOnnxSpeechSegment>

  init(p: UnsafePointer<SherpaOnnxSpeechSegment>) {
    self.p = p
  }

  deinit {
    SherpaOnnxDestroySpeechSegment(p)
  }

  var start: Int {
    Int(p.pointee.start)
  }

  var n: Int {
    Int(p.pointee.n)
  }

  lazy var samples: [Float] = {
    Array(UnsafeBufferPointer(start: p.pointee.samples, count: n))
  }()
}

class SherpaOnnxVoiceActivityDetectorWrapper {
  /// A pointer to the underlying counterpart in C
  private let vad: OpaquePointer

  init(config: UnsafePointer<SherpaOnnxVadModelConfig>, buffer_size_in_seconds: Float) {
    guard let vad = SherpaOnnxCreateVoiceActivityDetector(config, buffer_size_in_seconds) else {
      fatalError("SherpaOnnxCreateVoiceActivityDetector returned nil")
    }
    self.vad = vad
  }

  deinit {
    SherpaOnnxDestroyVoiceActivityDetector(vad)
  }

  func acceptWaveform(samples: [Float]) {
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, Int32(samples.count))
  }

  func isEmpty() -> Bool {
    return SherpaOnnxVoiceActivityDetectorEmpty(vad) == 1
  }

  func isSpeechDetected() -> Bool {
    return SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
  }

  func pop() {
    SherpaOnnxVoiceActivityDetectorPop(vad)
  }

  func clear() {
    SherpaOnnxVoiceActivityDetectorClear(vad)
  }

  func front() -> SherpaOnnxSpeechSegmentWrapper {
    guard let p = SherpaOnnxVoiceActivityDetectorFront(vad) else {
      fatalError("SherpaOnnxVoiceActivityDetectorFront returned nil")
    }
    return SherpaOnnxSpeechSegmentWrapper(p: p)
  }

  func reset() {
    SherpaOnnxVoiceActivityDetectorReset(vad)
  }

  func flush() {
    SherpaOnnxVoiceActivityDetectorFlush(vad)
  }
}

// MARK: - Offline speaker diarization

func sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
  model: String = ""
) -> SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig {
  SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: toCPointer(model))
}

func sherpaOnnxOfflineSpeakerSegmentationModelConfig(
  pyannote: SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig =
    sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(),
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxOfflineSpeakerSegmentationModelConfig {
  SherpaOnnxOfflineSpeakerSegmentationModelConfig(
    pyannote: pyannote,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider))
}

func sherpaOnnxSpeakerEmbeddingExtractorConfig(
  model: String = "",
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxSpeakerEmbeddingExtractorConfig {
  SherpaOnnxSpeakerEmbeddingExtractorConfig(
    model: toCPointer(model),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider))
}

func sherpaOnnxFastClusteringConfig(
  numClusters: Int = -1,
  threshold: Float = 0.5
) -> SherpaOnnxFastClusteringConfig {
  SherpaOnnxFastClusteringConfig(
    num_clusters: Int32(numClusters),
    threshold: threshold)
}

func sherpaOnnxOfflineSpeakerDiarizationConfig(
  segmentation: SherpaOnnxOfflineSpeakerSegmentationModelConfig,
  embedding: SherpaOnnxSpeakerEmbeddingExtractorConfig,
  clustering: SherpaOnnxFastClusteringConfig,
  minDurationOn: Float = 0.3,
  minDurationOff: Float = 0.5
) -> SherpaOnnxOfflineSpeakerDiarizationConfig {
  SherpaOnnxOfflineSpeakerDiarizationConfig(
    segmentation: segmentation,
    embedding: embedding,
    clustering: clustering,
    min_duration_on: minDurationOn,
    min_duration_off: minDurationOff)
}

struct SherpaOnnxDiarizationSegmentValue: Sendable {
  let start: Float
  let end: Float
  let speaker: Int
}

/// @unchecked Sendable: the wrapper is used serially — created, handed to
/// one GCD closure for a single blocking `process` call, then discarded
/// (see VoiceprintService.diarizeFile). No shared mutable state.
final class SherpaOnnxOfflineSpeakerDiarizationWrapper: @unchecked Sendable {
  /// A pointer to the underlying counterpart in C
  private let impl: OpaquePointer

  init?(config: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>) {
    guard let ptr = SherpaOnnxCreateOfflineSpeakerDiarization(config) else {
      return nil
    }
    self.impl = ptr
  }

  deinit {
    SherpaOnnxDestroyOfflineSpeakerDiarization(impl)
  }

  var sampleRate: Int {
    Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(impl))
  }

  /// Diarize mono samples normalized to [-1, 1] at `sampleRate`. One long
  /// synchronous C call; `onProgress` fires on the calling thread with
  /// (processedChunks, totalChunks). Segments come back sorted by start.
  func process(
    samples: [Float],
    onProgress: (@Sendable (Int, Int) -> Void)? = nil
  ) -> [SherpaOnnxDiarizationSegmentValue] {
    final class ProgressBox {
      let report: @Sendable (Int, Int) -> Void
      init(_ report: @escaping @Sendable (Int, Int) -> Void) { self.report = report }
    }

    let result: OpaquePointer?
    if let onProgress {
      let box = ProgressBox(onProgress)
      let arg = Unmanaged.passRetained(box).toOpaque()
      defer { Unmanaged<ProgressBox>.fromOpaque(arg).release() }
      result = SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
        impl, samples, Int32(samples.count),
        { done, total, arg in
          guard let arg else { return 0 }
          Unmanaged<ProgressBox>.fromOpaque(arg)
            .takeUnretainedValue().report(Int(done), Int(total))
          return 0
        }, arg)
    } else {
      result = SherpaOnnxOfflineSpeakerDiarizationProcess(
        impl, samples, Int32(samples.count))
    }
    guard let result else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

    let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
    guard count > 0,
      let segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
    else { return [] }
    defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments) }

    return (0..<count).map { index in
      SherpaOnnxDiarizationSegmentValue(
        start: segments[index].start,
        end: segments[index].end,
        speaker: Int(segments[index].speaker))
    }
  }
}
