import Foundation
import CoreML

/// Service that coordinates loading the YAMNet CoreML model, extracting
/// optimal audio segments (Drop-Fokus Heuristic), and generating dense embeddings.
final class AudioEmbeddingService: @unchecked Sendable {
    private var model: MLModel?
    private let preprocessor = AudioPreprocessor()
    private var inputName: String?

    init() {
        loadModel()
    }

    /// Whether the CoreML embedding generator is fully loaded and functional.
    var isAvailable: Bool {
        model != nil && preprocessor.isAvailable
    }

    /// Attempt to load the compiled CoreML model dynamically from the main app bundle.
    private func loadModel() {
        let modelURL = Bundle.module.url(forResource: "YAMNet", withExtension: "mlmodelc") ??
                       Bundle.main.url(forResource: "YAMNet", withExtension: "mlmodelc")
        
        guard let resolvedURL = modelURL else {
            AppLogger.shared.log(
                "YAMNet.mlmodelc not found in Bundle.module or Bundle.main. Audio suggestion features will fall back or be disabled.",
                level: .warning,
                source: "AudioEmbedding"
            )
            return
        }

        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all // Leverage Neural Engine, GPU, and CPU
            let loadedModel = try MLModel(contentsOf: resolvedURL, configuration: configuration)
            self.model = loadedModel
            self.inputName = loadedModel.modelDescription.inputDescriptionsByName.keys.first ?? "audioSamples"
            let inputs = loadedModel.modelDescription.inputDescriptionsByName.keys.joined(separator: ", ")
            let outputs = loadedModel.modelDescription.outputDescriptionsByName.keys.joined(separator: ", ")
            AppLogger.shared.info("Successfully loaded YAMNet CoreML model dynamically. Inputs: [\(inputs)], Outputs: [\(outputs)]", source: "AudioEmbedding")
        } catch {
            AppLogger.shared.log(
                "Failed to load compiled CoreML model YAMNet: \(error.localizedDescription)",
                level: .error,
                source: "AudioEmbedding"
            )
        }
    }

    /// Generate a 1024-dimensional embedding for a single 15,600-sample window (0.975s at 16kHz).
    ///
    /// - Parameter samples: An array slice of exactly 15,600 Float samples.
    /// - Returns: A 1024-D Float embedding vector.
    func generateEmbedding(forSamples samples: ArraySlice<Float>) throws -> [Float] {
        guard let loadedModel = model else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreML model not loaded"])
        }

        guard samples.count == 15600 else {
            throw NSError(
                domain: "AudioEmbedding",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid sample count: expected exactly 15,600, got \(samples.count)"]
            )
        }

        // 1. Construct MLMultiArray for the inputs
        let shape: [NSNumber] = [15600]
        let multiArray = try MLMultiArray(shape: shape, dataType: .float32)
        
        // Fast copy into multiarray pointer (respecting ArraySlice index bounds)
        let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: 15600)
        let baseIndex = samples.startIndex
        for i in 0..<15600 {
            ptr[i] = samples[baseIndex + i]
        }

        // 2. Discover model input feature name dynamically or use cached
        let inputName = self.inputName ?? loadedModel.modelDescription.inputDescriptionsByName.keys.first ?? "audioSamples"

        // 3. Build dictionary feature provider
        let inputDict: [String: Any] = [inputName: multiArray]
        let inputProvider = try MLDictionaryFeatureProvider(dictionary: inputDict)

        // 4. Run CoreML prediction
        let prediction = try loadedModel.prediction(from: inputProvider)

        #if DEBUG
        // Log shapes and names of all predicted features for diagnostic purposes ONLY in DEBUG mode
        let featureNames = prediction.featureNames
        var debugDetails = ""
        for name in featureNames {
            if let val = prediction.featureValue(for: name) {
                if let multiArray = val.multiArrayValue {
                    let shape = multiArray.shape.map { "\($0)" }.joined(separator: ",")
                    debugDetails += "Name: '\(name)' Shape: [\(shape)]; "
                } else {
                    debugDetails += "Name: '\(name)' Type: \(val.type.rawValue); "
                }
            }
        }
        AppLogger.shared.debug("CoreML Prediction Outputs: \(debugDetails)", source: "AudioEmbedding")
        #endif

        // 5. Extract output embedding vector dynamically
        guard let embeddingFeature = prediction.featureValue(for: "embeddings") ?? 
                                     prediction.featureValue(for: "embedding") ??
                                     prediction.featureValue(for: "targetProbability") ??
                                     prediction.featureValue(for: "target") else {
            throw NSError(
                domain: "AudioEmbedding",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Output features 'embeddings' or 'embedding' not found in model prediction."]
            )
        }

        // 5b. Handle Dictionary output types (like 'targetProbability')
        if embeddingFeature.type == .dictionary {
            let dict = embeddingFeature.dictionaryValue
            let keys = dict.keys.compactMap { $0 as? String }.sorted()
            let vector = keys.map { Float(dict[$0]?.doubleValue ?? 0.0) }
            
            var paddedVector = [Float](repeating: 0.0, count: 1024)
            for i in 0..<min(vector.count, 1024) {
                paddedVector[i] = vector[i]
            }
            return paddedVector
        }

        guard let embeddingArray = embeddingFeature.multiArrayValue else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Embedding output is not a multiarray"])
        }

        // 6. Convert MultiArray to standard [Float]
        let count = embeddingArray.count
        var embedding = [Float](repeating: 0.0, count: count)
        let outPtr = embeddingArray.dataPointer.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count {
            embedding[i] = outPtr[i]
        }

        return embedding
    }

    /// Analyze a track using the Drop-Fokus Heuristic.
    /// Finds the loudest 30-second window, segments it, and generates a averaged master embedding.
    ///
    /// - Parameters:
    ///   - path: Absolute path of the audio file.
    ///   - totalDuration: Total duration of the track in seconds.
    /// - Returns: A tuple containing the 1024-D master embedding and the start offset of the drop in seconds.
    func analyzeTrackDrop(at path: String, totalDuration: Double) async throws -> (embedding: [Float], offset: Double) {
        guard isAvailable else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "CoreML audio preprocessor or model not available"])
        }

        // Rule 1: For short songs (<45s), analyze the whole song
        if totalDuration < 45.0 {
            guard let samples = try await preprocessor.resampleTo16kHzMono(at: path) else {
                throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Resampling failed"])
            }
            let master = try processAveragedEmbedding(for: samples)
            return (master, 0.0)
        }

        // Rule 2: Exclude intro (15%) and outro (10%)
        let skipIntro = totalDuration * 0.15
        let skipOutro = totalDuration * 0.10
        let middleDuration = totalDuration - skipIntro - skipOutro

        // Decode the entire middle segment (16kHz mono is very small in RAM, e.g. ~3 min = ~11 MB)
        guard let samples = try await preprocessor.resampleTo16kHzMono(at: path, startOffset: skipIntro, duration: middleDuration) else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Resampling middle segment failed"])
        }

        // Step 1: Slice into 10-second segments (160,000 samples each at 16kHz)
        let segmentSamples = 160_000
        let segmentCount = samples.count / segmentSamples

        guard segmentCount > 0 else {
            // Fall back to entire middle samples if too short
            let master = try processAveragedEmbedding(for: samples)
            return (master, skipIntro)
        }

        // Step 2: Calculate RMS energy for each 10s segment
        var segmentEnergies = [Double](repeating: 0.0, count: segmentCount)
        for s in 0..<segmentCount {
            let offset = s * segmentSamples
            var sumSquare: Double = 0.0
            for i in 0..<segmentSamples {
                let value = Double(samples[offset + i])
                sumSquare += value * value
            }
            segmentEnergies[s] = sqrt(sumSquare / Double(segmentSamples))
        }

        // Step 3: Find the loudest 30-second window (3 consecutive 10s segments)
        var maxEnergy = -1.0
        var bestStartIndex = 0

        // Slide window of size 3
        if segmentCount >= 3 {
            for i in 0..<(segmentCount - 2) {
                let threeSegmentEnergy = segmentEnergies[i] + segmentEnergies[i+1] + segmentEnergies[i+2]
                if threeSegmentEnergy > maxEnergy {
                    maxEnergy = threeSegmentEnergy
                    bestStartIndex = i
                }
            }
        } else {
            // Less than 30 seconds of middle audio: choose the single loudest segment
            for i in 0..<segmentCount {
                if segmentEnergies[i] > maxEnergy {
                    maxEnergy = segmentEnergies[i]
                    bestStartIndex = i
                }
            }
        }

        // Step 4: Extract the exact 30s samples
        let dropOffsetInMiddle = Double(bestStartIndex * 10)
        let dropStartSample = bestStartIndex * segmentSamples
        let dropDurationSamples = min(segmentSamples * 3, samples.count - dropStartSample)

        let dropSamples = Array(samples[dropStartSample..<(dropStartSample + dropDurationSamples)])

        // Step 5: Process averaged embedding for this 30s block
        let master = try processAveragedEmbedding(for: dropSamples)
        let actualOffset = skipIntro + dropOffsetInMiddle

        return (master, actualOffset)
    }

    /// Process a continuous block of raw samples, chunk it into 15.600 sample windows,
    /// generate embeddings for each, and return the mathematical mean vector.
    private func processAveragedEmbedding(for samples: [Float]) throws -> [Float] {
        let segmented = AudioPreprocessor.segment(samples: samples, windowSize: 15600)
        guard !segmented.isEmpty else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio segment too short for embedding window"])
        }

        var accumulated = [Float](repeating: 0.0, count: 1024) // Holds sum vector
        var successCount = 0

        for window in segmented {
            do {
                let vec = try generateEmbedding(forSamples: window)
                guard vec.count == 1024 else { continue }
                for i in 0..<1024 {
                    accumulated[i] += vec[i]
                }
                successCount += 1
            } catch {
                // Log and ignore individual window failures to stay robust
                AppLogger.shared.debug("Window prediction failed: \(error.localizedDescription)", source: "AudioEmbedding")
            }
        }

        guard successCount > 0 else {
            throw NSError(domain: "AudioEmbedding", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate embeddings for any sample windows"])
        }

        // Average the accumulated vectors
        for i in 0..<1024 {
            accumulated[i] /= Float(successCount)
        }

        return accumulated
    }
}
