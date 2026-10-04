import Foundation

/// Fixed-size mono sample history shared between the capture thread and the analyzer.
final class SampleRing {
    private var buffer: [Float]
    private var writeIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        buffer = Array(repeating: 0, count: capacity)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<count {
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % buffer.count
        }
    }

    /// Copies the most recent `destination.count` samples, oldest first.
    func readLatest(into destination: inout [Float]) {
        lock.lock()
        defer { lock.unlock() }
        let n = min(destination.count, buffer.count)
        var index = (writeIndex - n + buffer.count) % buffer.count
        for i in 0..<n {
            destination[i] = buffer[index]
            index = (index + 1) % buffer.count
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for i in buffer.indices { buffer[i] = 0 }
    }
}
