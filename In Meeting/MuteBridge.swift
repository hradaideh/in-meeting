import Foundation
import Network

/// Receives meeting-app mute state from a local browser extension (Meet / Teams web).
/// CoreAudio cannot see in-app mute; this is the bridge.
/// POST http://127.0.0.1:17384/mute  JSON: {"muted":true,"active":true,"source":"meet"}
final class MuteBridge {
    static let shared = MuteBridge()
    static let port: NWEndpoint.Port = 17384

    /// nil = no recent signal from an extension (treat mic-held as unmuted/hot).
    private(set) var isMuted: Bool?
    private(set) var source: String = ""
    private(set) var meetingActive: Bool = false
    var onChange: (() -> Void)?

    private var listener: NWListener?
    private var lastUpdate = Date.distantPast
    /// Drop stale mute hints if the extension stops posting (tab closed).
    private let staleAfter: TimeInterval = 8

    private init() {}

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: Self.port)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    fputs("mute-bridge listener failed: \(err)\n", stderr)
                }
            }
            listener.start(queue: .main)
            fputs("mute-bridge listening on 127.0.0.1:\(Self.port)\n", stderr)
        } catch {
            fputs("mute-bridge could not bind :\(Self.port): \(error)\n", stderr)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Call from the poll loop — clears stale extension state.
    func sweepStale() {
        guard meetingActive || isMuted != nil else { return }
        if Date().timeIntervalSince(lastUpdate) > staleAfter {
            meetingActive = false
            isMuted = nil
            source = ""
            onChange?()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            defer { connection.cancel() }
            guard let self, let data, !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.hasPrefix("OPTIONS") {
                let header = Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            self.parseHTTP(text)
            let body = Data(#"{"ok":true}"#.utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
            connection.send(content: header + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func parseHTTP(_ text: String) {
        guard let range = text.range(of: "\r\n\r\n") else { return }
        let body = String(text[range.upperBound...])
        guard let jsonData = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }
        lastUpdate = Date()
        if let active = obj["active"] as? Bool {
            meetingActive = active
            if !active {
                isMuted = nil
                source = ""
                onChange?()
                fputs("mute-bridge: meeting inactive\n", stderr)
                return
            }
        } else {
            meetingActive = true
        }
        if let muted = obj["muted"] as? Bool {
            isMuted = muted
        }
        if let src = obj["source"] as? String {
            source = src
        }
        fputs("mute-bridge: muted=\(String(describing: isMuted)) source=\(source)\n", stderr)
        onChange?()
    }
}
