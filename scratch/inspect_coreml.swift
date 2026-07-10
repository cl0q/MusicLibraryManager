import CoreML
import Foundation

let modelURL = URL(fileURLWithPath: "/Users/olli/schenanigans/MusicLibraryManager/YAMNet/YAMNet.mlproj/Models/YAMNet 1.mlmodel")
do {
    let model = try MLModel(contentsOf: modelURL)
    print("--- Model Description ---")
    print("Inputs:")
    for (name, desc) in model.modelDescription.inputDescriptionsByName {
        print("  \(name): \(desc)")
    }
    print("Outputs:")
    for (name, desc) in model.modelDescription.outputDescriptionsByName {
        print("  \(name): \(desc)")
    }
    if let metadata = model.modelDescription.metadata as? [String: Any] {
        print("Metadata:")
        for (key, val) in metadata {
            print("  \(key): \(val)")
        }
    }
} catch {
    print("Error loading model: \(error)")
}
