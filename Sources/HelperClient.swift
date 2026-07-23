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

    func run(_ arguments: [String]) async throws -> HelperResponse {
        let executable = try helperURL()
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
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

