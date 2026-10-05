import AppKit
import Foundation

/// The `shortcuts` command line, pure so the tests can check it.
nonisolated enum ShortcutsCommand {
    static let executable = "/usr/bin/shortcuts"

    static func arguments(name: String, inputPath: String, outputPath: String) -> [String] {
        ["run", name, "--input-path", inputPath, "--output-path", outputPath]
    }
}

/// Runs a Shortcut with the selection as its input file, with a 60 s limit.
/// A Shortcut can do anything, which is why the card confirms the name.
final class ShortcutsRunner {
    static let timeout: Duration = .seconds(60)

    func run(name: String, input: String, timeout: Duration = ShortcutsRunner.timeout) async -> ActionOutcome {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyozaclikr-shortcut-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("Couldn't prepare the Shortcut's input: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.txt")
        let outputURL = directory.appendingPathComponent("output.txt")
        do {
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("Couldn't write the Shortcut's input: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShortcutsCommand.executable)
        process.arguments = ShortcutsCommand.arguments(name: name, inputPath: inputURL.path, outputPath: outputURL.path)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let watchdog = Task<Bool, Never> {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return false }
            process.terminate()
            return true
        }
        var launchError: Error?
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                launchError = error
                continuation.resume(returning: -1)
            }
        }
        watchdog.cancel()
        let timedOut = await watchdog.value
        if let launchError {
            return .failed("Couldn't run Shortcuts: \(launchError.localizedDescription)")
        }
        if timedOut {
            return .failed("Shortcut “\(name)” took more than \(Int(timeout.components.seconds)) s and was stopped.")
        }
        guard status == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit status \(status)"
            return .failed("Shortcut “\(name)” failed: \(line)")
        }
        if let output = try? String(contentsOf: outputURL, encoding: .utf8), !output.isEmpty {
            Replace.copy(output)
            return .done("Ran \(name); its output is copied")
        }
        return .done("Ran \(name)")
    }
}
