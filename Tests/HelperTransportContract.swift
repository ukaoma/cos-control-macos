import Foundation
import Darwin

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func openDescriptors() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

final class ProgressCapture: @unchecked Sendable {
    private let lock=NSLock()
    private var lines:[String]=[]
    func append(_ line:String){lock.lock();lines.append(line);lock.unlock()}
    func snapshot()->[String]{lock.lock();defer{lock.unlock()};return lines}
}

@main struct HelperTransportContract {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cos-helper-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("fixture.py")
        let source = """
        import json, sys, time, signal, os
        kind=sys.argv[1]
        if kind=='quiet':
            print(json.dumps({'ok':True,'message':'quiet','details':{}}), flush=True)
            sys.exit(0)
        if kind=='closed-streams':
            print(json.dumps({'ok':True,'message':'closed','details':{}}), flush=True)
            os.close(1); os.close(2)
            time.sleep(.75)
            sys.exit(0)
        if kind=='timeout':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(10)
        if kind=='stdin':
            data=sys.stdin.read()
            print(json.dumps({'ok':True,'message':str(len(data)),'details':{}}))
        else:
            size=int(sys.argv[2])
            sys.stderr.write(('progress ✓\\n'*10000));sys.stderr.flush()
            sys.stderr.buffer.write('tail ✓'.encode()[:-1]);sys.stderr.flush();time.sleep(.01)
            sys.stderr.buffer.write('tail ✓'.encode()[-1:]);sys.stderr.flush()
            print(json.dumps({'ok':True,'message':'x'*size,'details':{}}))
        """
        try source.write(to: child, atomically: true, encoding: .utf8)
        let client = HelperClient(executableOverride: URL(fileURLWithPath: "/usr/bin/python3"))
        for count in [1, 102435, 166176, 1024 * 1024] {
            let progress=ProgressCapture()
            let answer = try await client.run([child.path, "output", String(count)], timeout: 10, progress: {progress.append($0)})
            let lines=progress.snapshot()
            precondition(lines.count==10001 && lines.first=="progress ✓" && lines.last=="tail ✓", "progress ordering, split UTF-8 or final line lost")
            precondition(answer.message.count == count, "large output truncated")
        }
        let input = Data(repeating: 97, count: 1024 * 1024)
        let echoed = try await client.run([child.path, "stdin"], timeout: 10, stdinData: input)
        precondition(echoed.message == String(input.count), "stdin incomplete")
        let bounded = HelperClient(executableOverride: URL(fileURLWithPath: "/usr/bin/python3"), outputLimit: 1024)
        do {
            _ = try await bounded.run([child.path,"output","1025"], timeout: 5)
            fatalError("overflow did not fail")
        } catch HelperClientError.outputLimitExceeded {}
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await client.run([child.path,"timeout"], timeout: 0.1)
            fatalError("timeout did not fail")
        } catch HelperClientError.timedOut {}
        precondition(ProcessInfo.processInfo.systemUptime - start < 3, "termination was not bounded")
        let work = Task { try await client.run([child.path,"timeout"], timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        work.cancel()
        do { _ = try await work.value; fatalError("cancel did not fail") } catch is CancellationError {}
        // EOF is permanently readable. The former readabilityHandler leaked
        // on timeout, leaving one continuously scheduled monitor per failure.
        // Repeated failures must release descriptors AND leave this process idle.
        let descriptorsBefore = try openDescriptors()
        for _ in 0..<12 {
            do {
                _ = try await client.run([child.path,"timeout"], timeout: 0.03)
                fatalError("repeated timeout did not fail")
            } catch HelperClientError.timedOut {}
        }
        for _ in 0..<40 {
            _ = try await client.run([child.path,"quiet"], timeout: 3)
        }
        let closedStart = cpuSeconds()
        let closed = try await client.run([child.path,"closed-streams"], timeout: 3)
        precondition(closed.message == "closed")
        let closedCPU = cpuSeconds() - closedStart
        precondition(closedCPU < 0.15, "closed streams caused busy polling: \(closedCPU)s CPU")
        let idleStart = cpuSeconds()
        try await Task.sleep(for: .seconds(1))
        let idleCPU = cpuSeconds() - idleStart
        precondition(idleCPU < 0.15, "completed helpers left spinning monitors: \(idleCPU)s CPU")
        let descriptorsAfter = try openDescriptors()
        precondition(descriptorsAfter <= descriptorsBefore + 4,
                     "helper descriptors leaked: \(descriptorsBefore) -> \(descriptorsAfter)")
        print("helper resource checks: idle CPU \(idleCPU)s/1s; early-EOF CPU \(closedCPU)s; descriptors \(descriptorsBefore) -> \(descriptorsAfter)")
        print("helper transport: large stdout/stderr, stdin, overflow, timeout, cancellation and resource cleanup passed")
    }
}
