import Foundation
import Accelerate

/// High-performance vector math operations optimized for Apple Silicon.
/// Leverages the modern Swift Accelerate framework (vDSP wrappers).
struct VectorMath {
    /// Calculate the Cosine Similarity between two floating-point vectors.
    /// Highly parallelized via AMX (Apple Matrix Coprocessor) / NEON vector registers.
    ///
    /// Range is [-1.0, 1.0], where 1.0 represents identical vectors.
    ///
    /// - Parameters:
    ///   - v1: First floating-point vector.
    ///   - v2: Second floating-point vector.
    /// - Returns: The cosine similarity value.
    static func cosineSimilarity(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count, !v1.isEmpty else {
            return 0.0
        }

        // 1. Vector Dot Product (A . B) using modern Swift vDSP wrapper
        let dotProduct = vDSP.dot(v1, v2)

        // 2. Magnitude of v1: ||A||
        let sumSquares1 = vDSP.sumOfSquares(v1)
        let magnitude1 = sqrt(sumSquares1)

        // 3. Magnitude of v2: ||B||
        let sumSquares2 = vDSP.sumOfSquares(v2)
        let magnitude2 = sqrt(sumSquares2)

        // Prevent division by zero
        guard magnitude1 > 0.0 && magnitude2 > 0.0 else {
            return 0.0
        }

        return dotProduct / (magnitude1 * magnitude2)
    }

    /// Calculate Euclidean Distance between two vectors.
    /// Used for basic fallback geometric distance metric.
    static func euclideanDistance(_ v1: [Float], _ v2: [Float]) -> Float {
        guard v1.count == v2.count, !v1.isEmpty else {
            return Float.infinity
        }

        // Compute difference: v1 - v2 using modern Swift vDSP wrapper
        let diff = vDSP.subtract(v1, v2)
        
        // Sum of squares of differences
        let sumSquares = vDSP.sumOfSquares(diff)
        
        return sqrt(sumSquares)
    }
}
