import Foundation
import Darwin

enum HelperClientError: LocalizedError {
    case helperMissing
    case invalidResponse(String)
    case commandFailed(String)
    case timedOut
    case outputLimitExceeded
    case progressLimitExceeded
    case streamDidNotClose

    var errorDescription: String? {
        switch self {
        case .helperMissing: "COS Control helper is missing from the app bundle."
        case .invalidResponse(let value): "The helper returned an invalid response: \(value)"
        case .commandFailed(let value): value
        case .timedOut: "The COS operation took too long."
        case .outputLimitExceeded: "The helper response exceeded the supported size. Narrow the request and retry."
        case .progressLimitExceeded: "The helper progress output exceeded the supported size."
        case .streamDidNotClose: "The helper finished without closing its output streams."
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

    func consume(_ data: Data) throws {
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
        let withinLimit = pending.count <= HelperClient.maximumProgressLineBytes
        lock.unlock()
        guard withinLimit else {
            throw HelperClientError.progressLimitExceeded
        }
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

// Nonblocking reads let one loop supervise stdout, progress, stdin and process
// lifetime. Neither output pipe can fill while the parent waits for exit.
private func stopHelper(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let end = ProcessInfo.processInfo.systemUptime + 0.5
    while process.isRunning && ProcessInfo.processInfo.systemUptime < end {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    let reapEnd = ProcessInfo.processInfo.systemUptime + 1
    while process.isRunning && ProcessInfo.processInfo.systemUptime < reapEnd {
        Thread.sleep(forTimeInterval: 0.01)
    }
}

actor HelperClient {
    nonisolated static let maximumOutputBytes = 64 * 1024 * 1024
    nonisolated static let maximumProgressBytes = 8 * 1024 * 1024
    nonisolated static let maximumProgressLineBytes = 256 * 1024
    private let executableOverride: URL?
    private let outputLimit: Int

    init(executableOverride: URL? = nil, outputLimit: Int = HelperClient.maximumOutputBytes) {
        self.executableOverride = executableOverride
        self.outputLimit = outputLimit
    }

    private func helperURL(preferStable: Bool = false) throws -> URL {
        if let executableOverride { return executableOverride }
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
        let outputLimit = self.outputLimit
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
                let inputPipe = stdinData == nil ? nil : Pipe()
                if let inputPipe { process.standardInput = inputPipe }
                let outputHandle = outputPipe.fileHandleForReading
                let progressHandle = progressPipe.fileHandleForReading
                let inputHandle = inputPipe?.fileHandleForWriting
                defer {
                    stopHelper(process)
                    try? outputHandle.close()
                    try? progressHandle.close()
                    try? inputHandle?.close()
                    collector.finish()
                }
                try cancellation.launch(process)
                // Close our copies of the child's ends so EOF is observable.
                try? outputPipe.fileHandleForWriting.close()
                try? progressPipe.fileHandleForWriting.close()
                try? inputPipe?.fileHandleForReading.close()
                for handle in [outputHandle, progressHandle, inputHandle].compactMap({ $0 }) {
                    let fd = handle.fileDescriptor
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                }
                if let inputHandle { _ = fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1) }
                let started = ProcessInfo.processInfo.systemUptime
                var exitedAt: TimeInterval?
                var outputEOF = false
                var progressEOF = false
                var inputClosed = inputHandle == nil
                var inputOffset = 0
                var progressBytes = 0
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    try cancellation.checkCancellation()
                    let now = ProcessInfo.processInfo.systemUptime
                    if let timeout, now - started >= timeout { throw HelperClientError.timedOut }
                    if !process.isRunning {
                        if exitedAt == nil { exitedAt = now }
                        if outputEOF && progressEOF { break }
                        if now - (exitedAt ?? now) > 1 { throw HelperClientError.streamDidNotClose }
                    }
                    var descriptors = [
                        pollfd(fd: outputEOF ? -1 : outputHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: progressEOF ? -1 : progressHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: inputClosed ? -1 : (inputHandle?.fileDescriptor ?? -1), events: Int16(POLLOUT), revents: 0)
                    ]
                    let ready = poll(&descriptors, nfds_t(descriptors.count), 25)
                    if ready < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    for i in 0..<2 where descriptors[i].revents != 0 {
                        let n = Darwin.read(descriptors[i].fd, &buffer, buffer.count)
                        if n > 0 {
                            let chunk = Data(buffer.prefix(n))
                            if i == 0 {
                                guard data.count <= outputLimit - n else { throw HelperClientError.outputLimitExceeded }
                                data.append(chunk)
                            } else {
                                progressBytes += n
                                guard progressBytes <= Self.maximumProgressBytes else { throw HelperClientError.progressLimitExceeded }
                                try collector.consume(chunk)
                            }
                        } else if n == 0 {
                            if i == 0 { outputEOF = true } else { progressEOF = true }
                        } else if errno != EAGAIN && errno != EINTR {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                    }
                    if !inputClosed, let inputHandle, let stdinData {
                        if descriptors[2].revents != 0 && inputOffset < stdinData.count {
                            let n = stdinData.withUnsafeBytes { bytes in
                                Darwin.write(inputHandle.fileDescriptor, bytes.baseAddress!.advanced(by: inputOffset), min(65536, stdinData.count - inputOffset))
                            }
                            if n > 0 { inputOffset += n }
                            else if n < 0 && errno != EAGAIN && errno != EINTR {
                                try? inputHandle.close()
                                inputClosed = true
                            }
                        }
                        if inputOffset == stdinData.count || !process.isRunning {
                            try? inputHandle.close()
                            inputClosed = true
                        }
                    }
                }
                try cancellation.checkCancellation()
                guard let response = try? JSONDecoder().decode(HelperResponse.self, from: data) else {
                    throw HelperClientError.invalidResponse(String(decoding: data.prefix(2048), as: UTF8.self))
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
