import CoreML
import WhisperKit

/// Raw model interfaces, captured without calling WhisperKit's unchecked dimension helpers.
struct WhisperGraphDescription: Sendable {
    struct Feature: Equatable, Sendable {
        var shape: [Int]
        var dataType: MLMultiArrayDataType
        var isMultiArray = true
        var isOptional = false
        var hasFixedShape = true
    }
    var inputs: [String: Feature]
    var outputs: [String: Feature]

    init(inputs: [String: Feature], outputs: [String: Feature]) {
        self.inputs = inputs; self.outputs = outputs
    }

    init(_ description: MLModelDescription) {
        func capture(_ features: [String: MLFeatureDescription]) -> [String: Feature] {
            features.mapValues { feature in
                let constraint = feature.multiArrayConstraint
                let shape = constraint?.shape.map(\.intValue) ?? []
                let fixed: Bool
                switch constraint?.shapeConstraint.type {
                case .unspecified: fixed = true
                case .enumerated: fixed = constraint?.shapeConstraint.enumeratedShapes.allSatisfy { $0.map(\.intValue) == shape } == true
                case .range:
                    let ranges = constraint?.shapeConstraint.sizeRangeForDimension ?? []
                    fixed = ranges.count == shape.count && shape.indices.allSatisfy { index in
                        let range = ranges[index].rangeValue
                        return range.location == shape[index] && range.length == 1
                    }
                default: fixed = false
                }
                return Feature(shape: shape,
                        dataType: feature.multiArrayConstraint?.dataType ?? .double,
                        isMultiArray: feature.type == .multiArray, isOptional: feature.isOptional, hasFixedShape: fixed)
            }
        }
        inputs = capture(description.inputDescriptionsByName)
        outputs = capture(description.outputDescriptionsByName)
    }
}

/// Adapters expose the same raw contract even when model computation is substituted in tests.
protocol WhisperGraphDescribing {
    var rawGraphDescription: WhisperGraphDescription? { get }
}
extension WhisperGraphDescribing where Self: WhisperMLModel {
    var rawGraphDescription: WhisperGraphDescription? { model.map { WhisperGraphDescription($0.modelDescription) } }
}
extension FeatureExtractor: WhisperGraphDescribing {}
extension AudioEncoder: WhisperGraphDescribing {}
extension TextDecoder: WhisperGraphDescribing {}
extension TextDecoderContextPrefill: WhisperGraphDescribing {}

enum WhisperGraphContract {
    /// 0.18 allocates Float16 decoder caches but copies MemoryLayout<FloatType>.size
    /// bytes per element. Its Intel Float32 alias cannot safely address those buffers.
    static func validateRuntimeABI(floatStride: Int = MemoryLayout<FloatType>.stride) throws {
        guard floatStride == MemoryLayout<Float16>.stride else { throw OfflineWhisperError.incompatibleRuntime }
    }

    static func validate(mel: WhisperGraphDescription, encoder: WhisperGraphDescription,
                         decoder: WhisperGraphDescription, prefill: WhisperGraphDescription?) throws -> WhisperRuntimeMetadata {
        try validateRuntimeABI()
        typealias F = WhisperGraphDescription.Feature
        func array(_ features: [String: F], _ name: String, rank: Int, types: [MLMultiArrayDataType], output: Bool = false) throws -> F {
            guard let f = features[name], f.isMultiArray, !output || !f.isOptional,
                  f.shape.count == rank, f.shape.allSatisfy({ $0 > 0 }), types.contains(f.dataType),
                  !output || f.hasFixedShape else { throw OfflineWhisperError.incompatibleGraph }
            return f
        }
        func inputs(_ graph: WhisperGraphDescription, _ provided: Set<String>) throws {
            guard graph.inputs.allSatisfy({ provided.contains($0.key) || $0.value.isOptional }) else {
                throw OfflineWhisperError.incompatibleGraph
            }
        }
        func shape(_ feature: F, _ expected: [Int]) throws {
            guard feature.shape == expected else { throw OfflineWhisperError.incompatibleGraph }
        }
        func match(_ output: F, _ input: F) throws {
            guard output.shape == input.shape, output.dataType == input.dataType else { throw OfflineWhisperError.incompatibleGraph }
        }
        try inputs(mel, ["audio"])
        try inputs(encoder, ["melspectrogram_features"])
        try inputs(decoder, ["input_ids", "cache_length", "key_cache", "value_cache", "kv_cache_update_mask", "encoder_output_embeds", "decoder_key_padding_mask"])
        // The pinned decoder's alignment indexing and timestamp contract use 1500
        // frames, from the 30-second / 3000 mel-frame Whisper window.
        try shape(array(mel.inputs, "audio", rank: 1, types: [.float32]), [480000])
        let melOut = try array(mel.outputs, "melspectrogram_features", rank: 4, types: [.float16, .float32], output: true)
        let melIn = try array(encoder.inputs, "melspectrogram_features", rank: 4, types: [.float16, .float32])
        try match(melOut, melIn)
        let encoded = try array(encoder.outputs, "encoder_output_embeds", rank: 4, types: [.float16, .float32], output: true)
        let decoderEmbeds = try array(decoder.inputs, "encoder_output_embeds", rank: 4, types: [.float16, .float32])
        try match(encoded, decoderEmbeds)
        let logits = try array(decoder.outputs, "logits", rank: 3, types: [.float16], output: true)
        let metadata = try WhisperRuntimeMetadata(logitsSize: logits.shape[2], encoderSize: encoded.shape[1], decoderSize: decoderEmbeds.shape[1])
        try shape(logits, [1,1,metadata.logitsSize])
        try shape(melOut, [1, metadata.logitsSize == 51866 ? 128 : 80, 1, 3000])
        try shape(encoded, [1,metadata.encoderSize,1,1500])
        for name in ["input_ids", "cache_length"] { try shape(array(decoder.inputs, name, rank: 1, types: [.int32]), [1]) }
        let key = try array(decoder.inputs, "key_cache", rank: 4, types: [.float16])
        let width = key.shape[1], context = key.shape[3]
        // Cache width is hidden size times decoder layer count. Reduced-layer distil
        // and turbo graphs remain valid; layer count does not identify a checkpoint.
        guard width % metadata.encoderSize == 0, (1...32).contains(width / metadata.encoderSize),
              (224...448).contains(context) else { throw OfflineWhisperError.incompatibleGraph }
        try shape(key, [1,width,1,context])
        try match(key, array(decoder.inputs, "value_cache", rank: 4, types: [.float16]))
        // Pinned prepareDecoderInputs emits Int32, forwarded unchanged by TextDecoderInput.
        // A manually supplied Float16 fixture does not establish production conversion.
        try shape(array(decoder.inputs, "kv_cache_update_mask", rank: 2, types: [.int32]), [1,context])
        try shape(array(decoder.inputs, "decoder_key_padding_mask", rank: 2, types: [.float16]), [1,context])
        for name in ["key_cache_updates", "value_cache_updates"] {
            try shape(array(decoder.outputs, name, rank: 4, types: [.float16], output: true), [1,width,1,1])
        }
        if decoder.outputs["alignment_heads_weights"] != nil {
            try shape(array(decoder.outputs, "alignment_heads_weights", rank: 2, types: [.float16], output: true), [1,1500])
        }
        if let prefill {
            try inputs(prefill, ["task", "language"])
            for name in ["task", "language"] { try shape(array(prefill.inputs, name, rank: 1, types: [.int32]), [1]) }
            for name in ["key_cache_prefill", "value_cache_prefill"] {
                try shape(array(prefill.outputs, name, rank: 4, types: [.float16], output: true), [1,width,1,3])
            }
        }
        return metadata
    }
}
