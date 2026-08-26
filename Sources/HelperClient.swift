import Foundation

enum HelperClientError: LocalizedError {
    case helperMissing
    case invalidResponse(String)
    case commandFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .helperMissing: "COS Control helper is missing from the app bundle."
        case .invalidResponse(let value): "The helper returned an invalid response: \(value)"
        case .commandFailed(let value): value
        case .timedOut: "Session lookup took too long."
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

private final class HelperProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func launch(_ process: Process) throws {
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        do {
            // Launch while holding the same lock used by cancel(). Cancellation
            // can therefore occur before launch (and abort), or after launch
            // (and terminate), but never disappear in between those states.
            try process.run()
            lock.unlock()
        } catch {
            self.process = nil
            lock.unlock()
            throw error
        }
    }

    func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

private func waitForProcessExit(
    _ process: Process,
    timeout: TimeInterval,
    cancellation: HelperProcessCancellation
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
        try cancellation.checkCancellation()
    }
    if process.isRunning {
        process.terminate()
        throw HelperClientError.timedOut
    }
}

actor HelperClient {
    private func helperURL(preferStable: Bool = false) throws -> URL {
        let stable = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/COS Control/bin/cos-control-helper")
        if preferStable, FileManager.default.isExecutableFile(atPath: stable.path) {
            return stable
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("cos-control-helper"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        guard FileManager.default.isExecutableFile(atPath: stable.path) else { throw HelperClientError.helperMissing }
        return stable
    }

    func run(
        _ arguments: [String],
        timeout: TimeInterval? = nil,
        preferStable: Bool = false,
        stdinData: Data? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> HelperResponse {
        let executable = try helperURL(preferStable: preferStable)
        let cancellation = HelperProcessCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let process = Process()
                try cancellation.checkCancellation()
                defer { cancellation.clear() }
                let outputPipe = Pipe()
                let progressPipe = Pipe()
                let collector = ProgressLineCollector(callback: progress)
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = outputPipe
                process.standardError = progressPipe
                // Free text (a chat prompt) travels over stdin, never argv:
                // argv is world-readable through `ps` for every process on the
                // box. Wired only when a command opts in, so the other 40+
                // call sites keep inheriting the app's stdin untouched.
                let inputPipe: Pipe? = stdinData.map { data in
                    let pipe = Pipe()
                    process.standardInput = pipe
                    let handle = pipe.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    }
                    return pipe
                }
                _ = inputPipe
                progressPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.consume(handle.availableData)
                }
                try cancellation.launch(process)
                if let timeout {
                    try waitForProcessExit(process, timeout: timeout, cancellation: cancellation)
                }
                let data = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
                process.waitUntilExit()
                progressPipe.fileHandleForReading.readabilityHandler = nil
                collector.consume(progressPipe.fileHandleForReading.availableData)
                collector.finish()
                try cancellation.checkCancellation()
                guard let response = try? JSONDecoder().decode(HelperResponse.self, from: data) else {
                    throw HelperClientError.invalidResponse(String(decoding: data, as: UTF8.self))
                }
                guard process.terminationStatus == 0, response.ok else {
                    throw HelperClientError.commandFailed(response.message)
                }
                return response
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}
