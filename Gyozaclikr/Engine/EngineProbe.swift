import CoreGraphics
import Foundation
import FoundationModels

/// Measures what the engines can do on this Mac, once per launch, for the
/// Engines pane and the router: availability, context size, the model
/// variant, whether an image is accepted, and Ollama's models. Measured,
/// not assumed (docs/PLAN.md §2 Diagnostics).
enum EngineProbe {
    private static var cached: EngineDiagnostics?

    /// Seconds the image probe may take before it counts as unsupported.
    static let imageProbeTimeout: Double = 10

    static func measure(force: Bool = false) async -> EngineDiagnostics {
        if !force, let cached { return cached }
        var diagnostics = EngineDiagnostics()

        let apple = AppleIntelligenceStatus.current
        diagnostics.apple = apple.engineStatus
        // Read the model's facts only when it is there: Apple says the
        // context size "cannot be determined" without the model.
        if apple == .ready {
            if #available(macOS 26.4, *) {
                diagnostics.contextSize = SystemLanguageModel.default.contextSize
            }
            diagnostics.supportedLanguages = SystemLanguageModel.default.supportedLanguages
                .map(\.minimalIdentifier)
                .sorted()
            #if SDK_MACOS27
            if #available(macOS 27, *) {
                diagnostics.variant = SystemLanguageModel.default.variant.displayName
            }
            #endif
        }
        diagnostics.imageInput = await probeImageInput(appleReady: apple == .ready)

        let ollama = OllamaEngine()
        let models = try? await ollama.tags()
        if let models {
            diagnostics.ollama = .ready
            diagnostics.ollamaModels = models
            diagnostics.ollamaVisionModel = await ollama.model(vision: true)
        } else {
            diagnostics.ollama = .unavailable(OllamaEngine.notRunning(ollama.host))
        }

        diagnostics.measuredAt = Date()
        cached = diagnostics
        return diagnostics
    }

    /// Whether the model takes an `Attachment` here: a 16 × 16 red square
    /// in, one word out, within the timeout.
    static func probeImageInput(appleReady: Bool) async -> ImageSupport {
        #if SDK_MACOS27
        guard #available(macOS 27, *) else { return .unsupported("Apple's model takes images on macOS 27.") }
        guard appleReady else { return .untested }
        guard let image = ImageScaling.solidColour(width: 16, height: 16, red: 1, green: 0, blue: 0) else {
            return .unsupported("Could not make the probe image.")
        }
        do {
            _ = try await withTimeout(seconds: imageProbeTimeout) {
                try await AppleEngine.probeImageInput(image: image)
            }
            return .supported
        } catch let failure as EngineFailure {
            return .unsupported(failure.message)
        } catch {
            return .unsupported(error.localizedDescription)
        }
        #else
        return .notInThisBuild
        #endif
    }
}

/// Thrown when an operation outlives its budget.
nonisolated struct TimeoutError: Error, LocalizedError {
    let seconds: Double
    var errorDescription: String? { "No answer within \(Int(seconds)) s." }
}

/// Races `operation` against the clock; the loser is cancelled.
nonisolated func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else { throw TimeoutError(seconds: seconds) }
        group.cancelAll()
        return result
    }
}
