import Foundation
import Testing
@testable import devkit

struct SimulatorProcessCaptureTests {
    @Test func capturesOutputLargerThanPipeCapacity() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = ["if=/dev/zero", "bs=1024", "count=256"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Bound a regression to the old wait-before-read behavior.
        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }

        let data = try SimulatorProcessCapture.run(process, outputPipe: pipe)

        #expect(process.terminationStatus == 0)
        #expect(data == Data(repeating: 0, count: 256 * 1024))
    }
}
