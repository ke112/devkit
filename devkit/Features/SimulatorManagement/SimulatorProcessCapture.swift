import Foundation

enum SimulatorProcessCapture {
    nonisolated static func run(_ process: Process, outputPipe: Pipe) throws -> Data {
        try process.run()

        // Drain output while the child is running. Waiting first deadlocks when
        // simctl's output exceeds the pipe capacity (for example, devicetypes).
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}
