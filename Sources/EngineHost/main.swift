import Foundation
import Dispatch
import Darwin

@main
enum EngineHost {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let executable = arguments.first else { exit(2) }
        let parent = getppid()
        guard parent != 1 else { exit(1) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(arguments.dropFirst())
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { exit(1) }

        let queue = DispatchQueue(label: "WPSDrive.EngineHost")
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let parentExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        let stop = {
            if child.isRunning { child.terminate() }
        }
        terminate.setEventHandler(handler: stop)
        interrupt.setEventHandler(handler: stop)
        parentExit.setEventHandler(handler: stop)
        terminate.resume()
        interrupt.resume()
        parentExit.resume()
        if getppid() != parent { stop() }
        withExtendedLifetime((terminate, interrupt, parentExit)) { child.waitUntilExit() }
        exit(child.terminationStatus)
    }
}
