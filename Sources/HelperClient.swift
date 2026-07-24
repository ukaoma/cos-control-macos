import Foundation

enum HelperClientError: LocalizedError {
    case helperMissing
    case invalidResponse(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: "COS Control helper is missing from the app bundle."
        case .invalidResponse(let value): "The helper returned an invalid response: \(value)"
        case .commandFailed(let value): value
        }
    }
}

private final class ProgressLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let callback: @Sendable (String) -> Void

    init(callback: @escaping @Sendable (String) -> Void) {
        self.callback = callback
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending.append(data)
        let bytes = [UInt8](pending)
        var start = 0
        var lines: [String] = []
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            let line = Data(bytes[start..<index])
            if let value = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                lines.append(value)
            }
            start = index + 1
        }
        pending = start < bytes.count ? Data(bytes[start...]) : Data()
        lock.unlock()
        lines.forEach(callback)
    }

    func finish() {
        lock.lock()
        let value = String(data: pending, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll()
        lock.unlock()
        if let value, !value.isEmpty { callback(value) }
    }
}

actor HelperClient {
    private func helperURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("cos-control-helper"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let stable = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/COS Control/bin/cos-control-helper")
        guard FileManager.default.isExecutableFile(atPath: stable.path) else { throw HelperClientError.helperMissing }
        return stable
    }

    func run(
        _ arguments: [String],
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HelperResponse {
        let executable = try helperURL()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let progressPipe = Pipe()
            let collector = ProgressLineCollector(callback: progress)
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = progressPipe
            progressPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.consume(handle.availableData)
            }
            try process.run()
            let data = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            progressPipe.fileHandleForReading.readabilityHandler = nil
            collector.consume(progressPipe.fileHandleForReading.availableData)
            collector.finish()
            guard let response = try? JSONDecoder().decode(HelperResponse.self, from: data) else {
                throw HelperClientError.invalidResponse(String(decoding: data, as: UTF8.self))
            }
            guard process.terminationStatus == 0, response.ok else {
                throw HelperClientError.commandFailed(response.message)
            }
            return response
        }.value
    }
}
