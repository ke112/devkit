import Foundation

enum StreamingProcessError: LocalizedError {
    case couldNotLaunch(String)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let message):
            message
        }
    }
}

struct StreamingProcessResult {
    let terminationStatus: Int32
    let output: String
}

private final class StreamingProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = ""

    nonisolated func append(_ chunk: String) {
        lock.lock()
        value.append(chunk)
        lock.unlock()
    }

    nonisolated var content: String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class StreamingProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var cancelled = false

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    nonisolated func register(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled
        if !shouldTerminate {
            self.process = process
        }
        lock.unlock()

        if shouldTerminate {
            process.terminate()
        }
    }

    nonisolated func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    nonisolated func clear() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

enum StreamingProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        cancellation: StreamingProcessCancellation? = nil,
        environment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let output = StreamingProcessOutput()

            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) {
                    _, newValue in newValue
                }
            }
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                output.append(chunk)
                onOutput(chunk)
            }
            process.terminationHandler = { terminatedProcess in
                cancellation?.clear()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingData.isEmpty {
                    let chunk = String(decoding: remainingData, as: UTF8.self)
                    output.append(chunk)
                    onOutput(chunk)
                }

                continuation.resume(
                    returning: StreamingProcessResult(
                        terminationStatus: terminatedProcess.terminationStatus,
                        output: output.content
                    )
                )
            }

            do {
                cancellation?.register(process)
                try process.run()
                if cancellation?.isCancelled == true {
                    process.terminate()
                }
            } catch {
                cancellation?.clear()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    throwing: StreamingProcessError.couldNotLaunch(error.localizedDescription)
                )
            }
        }
    }
}
