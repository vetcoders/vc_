import AppKit
import Darwin
import Foundation

struct MonitorConfig {
    var socketPath: String?
    var headless = false
    var once = false
    var timeoutSeconds: TimeInterval = 10

    static func parse(_ args: [String]) throws -> MonitorConfig {
        var config = MonitorConfig()
        var index = 1

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--socket":
                index += 1
                guard index < args.count else { throw MonitorError.missingValue("--socket") }
                config.socketPath = args[index]
            case "--headless":
                config.headless = true
            case "--once":
                config.once = true
            case "--timeout":
                index += 1
                guard index < args.count else { throw MonitorError.missingValue("--timeout") }
                guard let timeout = TimeInterval(args[index]), timeout > 0 else {
                    throw MonitorError.invalidValue("--timeout")
                }
                config.timeoutSeconds = timeout
            case "--help", "-h":
                throw MonitorError.help
            default:
                throw MonitorError.unknownArgument(arg)
            }
            index += 1
        }

        if config.socketPath == nil {
            config.socketPath = ProcessInfo.processInfo.environment["VC_MUX_SOCKET"]
        }

        guard config.socketPath != nil else { throw MonitorError.missingSocket }
        return config
    }
}

enum MonitorError: Error, CustomStringConvertible {
    case help
    case missingSocket
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)
    case socketPathTooLong(String)
    case connectFailed(String, Int32)
    case disconnected
    case missingContentLength
    case malformedHeader
    case timeout

    var description: String {
        switch self {
        case .help:
            return usage
        case .missingSocket:
            return "missing --socket <path> or VC_MUX_SOCKET"
        case let .missingValue(flag):
            return "missing value for \(flag)"
        case let .invalidValue(flag):
            return "invalid value for \(flag)"
        case let .unknownArgument(arg):
            return "unknown argument '\(arg)'"
        case let .socketPathTooLong(path):
            return "socket path is too long: \(path)"
        case let .connectFailed(path, errnoValue):
            return "failed to connect to \(path): \(String(cString: strerror(errnoValue)))"
        case .disconnected:
            return "socket disconnected"
        case .missingContentLength:
            return "JSON-RPC frame is missing Content-Length"
        case .malformedHeader:
            return "malformed JSON-RPC header"
        case .timeout:
            return "timed out waiting for vc-mux activity"
        }
    }
}

let usage = """
Usage: vc-mux-monitor --socket <path> [--headless] [--once] [--timeout <seconds>]

Observes a vc-mux Unix socket as a passive fan-out client.
Use --headless --once for smoke tests; omit --headless for the macOS status item.
"""

struct JsonRpcNotification {
    let method: String
    let payload: [String: Any]
}

final class JsonRpcFrameReader {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func nextNotification() throws -> JsonRpcNotification? {
        while true {
            guard let headerRange = findHeaderRange() else { return nil }
            let header = buffer.subdata(in: 0 ..< headerRange.lowerBound)
            let bodyStart = headerRange.upperBound
            let contentLength = try parseContentLength(header)

            guard buffer.count >= bodyStart + contentLength else { return nil }

            let body = buffer.subdata(in: bodyStart ..< bodyStart + contentLength)
            buffer.removeSubrange(0 ..< bodyStart + contentLength)

            let decoded = try JSONSerialization.jsonObject(with: body)
            guard let object = decoded as? [String: Any],
                  object["id"] == nil,
                  let method = object["method"] as? String
            else {
                continue
            }

            return JsonRpcNotification(method: method, payload: object)
        }
    }

    private func findHeaderRange() -> Range<Int>? {
        if let range = buffer.range(of: Data([13, 10, 13, 10])) {
            return range.lowerBound ..< range.upperBound
        }
        if let range = buffer.range(of: Data([10, 10])) {
            return range.lowerBound ..< range.upperBound
        }
        return nil
    }

    private func parseContentLength(_ header: Data) throws -> Int {
        guard let text = String(data: header, encoding: .utf8) else {
            throw MonitorError.malformedHeader
        }

        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                guard let length = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw MonitorError.malformedHeader
                }
                return length
            }
        }

        throw MonitorError.missingContentLength
    }
}

final class UnixSocketObserver {
    let socketPath: String
    private var fileDescriptor: Int32 = -1
    private var isClosed = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        close()
    }

    func close() {
        if fileDescriptor >= 0 {
            Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        isClosed = true
    }

    func connect() throws {
        let pathBytes = Array(socketPath.utf8) + [0]
        var address = sockaddr_un()
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw MonitorError.socketPathTooLong(socketPath)
        }

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw MonitorError.connectFailed(socketPath, errno)
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawPath in
            rawPath.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, addressLength)
            }
        }

        guard result == 0 else {
            let errnoValue = errno
            close()
            throw MonitorError.connectFailed(socketPath, errnoValue)
        }
    }

    func readLoop(onNotification: (JsonRpcNotification) -> Bool) throws {
        var scratch = [UInt8](repeating: 0, count: 4096)
        let reader = JsonRpcFrameReader()

        while !isClosed {
            let count = Darwin.read(fileDescriptor, &scratch, scratch.count)
            if count == 0 { throw MonitorError.disconnected }
            if count < 0 {
                if errno == EINTR { continue }
                throw MonitorError.connectFailed(socketPath, errno)
            }

            reader.append(Data(scratch.prefix(Int(count))))
            while let notification = try reader.nextNotification() {
                if !onNotification(notification) {
                    return
                }
            }
        }
    }
}

final class StatusBarMonitor: NSObject, NSApplicationDelegate {
    private let config: MonitorConfig
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusMenu = NSMenu()
    private let stateItem = NSMenuItem(title: "Connecting", action: nil, keyEquivalent: "")
    private let socketItem: NSMenuItem
    private let activityItem = NSMenuItem(title: "Notifications: 0", action: nil, keyEquivalent: "")
    private let lastMethodItem = NSMenuItem(title: "Last method: none", action: nil, keyEquivalent: "")
    private var observer: UnixSocketObserver?
    private var notifications = 0
    private var reconnectWorkItem: DispatchWorkItem?

    init(config: MonitorConfig) {
        self.config = config
        socketItem = NSMenuItem(title: "Socket: \(config.socketPath ?? "")", action: nil, keyEquivalent: "")
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        updateState("Connecting", color: .systemOrange)
        connect()
    }

    private func configureMenu() {
        statusMenu.addItem(stateItem)
        statusMenu.addItem(socketItem)
        statusMenu.addItem(activityItem)
        statusMenu.addItem(lastMethodItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"))
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit vc-mux Monitor", action: #selector(quit), keyEquivalent: "q"))
        statusMenu.items.forEach { $0.target = self }
        statusItem.menu = statusMenu
        statusItem.button?.toolTip = "vc-mux observer"
    }

    @objc private func reconnect() {
        reconnectWorkItem?.cancel()
        observer?.close()
        updateState("Connecting", color: .systemOrange)
        connect()
    }

    @objc private func quit() {
        observer?.close()
        NSApp.terminate(nil)
    }

    private func connect() {
        guard let path = config.socketPath else { return }
        let socketObserver = UnixSocketObserver(socketPath: path)
        observer = socketObserver

        DispatchQueue.global(qos: .utility).async { [weak self, socketObserver] in
            do {
                try socketObserver.connect()
                DispatchQueue.main.async {
                    self?.updateState("Connected", color: .systemGreen)
                }
                try socketObserver.readLoop { notification in
                    DispatchQueue.main.async {
                        self?.markActivity(notification)
                    }
                    return true
                }
            } catch {
                DispatchQueue.main.async {
                    self?.updateState("Disconnected", color: .systemRed)
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateState("Connecting", color: .systemOrange)
            self?.connect()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func markActivity(_ notification: JsonRpcNotification) {
        notifications += 1
        updateState("Routing", color: .systemYellow)
        activityItem.title = "Notifications: \(notifications)"
        lastMethodItem.title = "Last method: \(notification.method)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            self?.updateState("Connected", color: .systemGreen)
        }
    }

    private func updateState(_ title: String, color: NSColor) {
        stateItem.title = "State: \(title)"
        statusItem.button?.image = Self.icon(color: color)
    }

    private static func icon(color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.move(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 12, y: 9))
        path.move(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 9, y: 12))
        path.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

func runHeadless(_ config: MonitorConfig) -> Int32 {
    guard let socketPath = config.socketPath else {
        fputs("\(MonitorError.missingSocket)\n", stderr)
        return 2
    }

    let observer = UnixSocketObserver(socketPath: socketPath)
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 1

    DispatchQueue.global(qos: .utility).async {
        var count = 0
        do {
            try observer.connect()
            printHeadless(["state": "connected", "socket": socketPath])
            try observer.readLoop { notification in
                count += 1
                printHeadless(["state": "active", "notifications": count, "method": notification.method])
                return !(config.once && count >= 1)
            }
            printHeadless(["state": "completed", "notifications": count])
            exitCode = 0
        } catch {
            fputs("\(error)\n", stderr)
            exitCode = 1
        }
        semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + config.timeoutSeconds) == .timedOut {
        observer.close()
        fputs("\(MonitorError.timeout)\n", stderr)
        return 1
    }

    return exitCode
}

func printHeadless(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return
    }
    print(text)
    fflush(stdout)
}

do {
    let config = try MonitorConfig.parse(CommandLine.arguments)
    if config.headless {
        exit(runHeadless(config))
    }

    let app = NSApplication.shared
    let controller = StatusBarMonitor(config: config)
    app.delegate = controller
    controller.start()
    app.run()
} catch MonitorError.help {
    print(usage)
    exit(0)
} catch {
    fputs("\(error)\n\n\(usage)\n", stderr)
    exit(2)
}
