#if DEBUG
import Foundation
import Network

/// Local-only (127.0.0.1) debug HTTP endpoint, DEBUG builds only. Lets a
/// development tool drive and poll the app for automated testing, without
/// needing screen capture or a human clicking the menu bar UI.
///
/// Not a real HTTP server: no chunked/multipart handling, one request per
/// connection, request must arrive in a single `receive` (fine for the
/// small local JSON requests this is built for).
///
///   GET  /state              -> current state JSON
///   POST /start               -> engine.start(), returns state
///   POST /stop                -> engine.stop(), returns state
///   POST /config  {"src":"en-US","tgt":"zh-TW","device":"...",
///                  "glossary":"term\nterm2 = 翻譯","highFidelity":false}
///                              -> applies given fields (all optional), returns state
@MainActor
final class DebugServer {
    static let shared = DebugServer()

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 17890

    private init() {}

    func start() {
        guard listener == nil else { return }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            print("[DebugServer] failed to create listener on port \(port): \(error)")
            return
        }
        listener = l

        l.newConnectionHandler = { conn in
            Task { @MainActor in DebugServer.shared.handle(conn) }
        }
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[DebugServer] listener failed: \(error)")
            }
        }
        l.start(queue: .main)
        print("[DebugServer] listening on http://127.0.0.1:\(port)")
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            Task { @MainActor in
                let body = DebugServer.shared.route(data ?? Data())
                let response = "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: application/json; charset=utf-8\r\n" +
                    "Content-Length: \(body.utf8.count)\r\n" +
                    "Connection: close\r\n\r\n" +
                    body
                // `.contentProcessed` can fire before all bytes are actually
                // flushed through the socket for larger payloads — cancelling
                // the connection immediately in that completion truncated the
                // response. `.finalMessage` + `isComplete: true` lets the
                // stack sequence a proper close after the data is fully sent.
                connection.send(content: response.data(using: .utf8),
                                 contentContext: .finalMessage,
                                 isComplete: true,
                                 completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: Routing

    private func route(_ raw: Data) -> String {
        guard let text = String(data: raw, encoding: .utf8) else { return currentStateJSON() }

        let headerEnd = text.range(of: "\r\n\r\n")
        let requestLine = text.components(separatedBy: "\r\n").first ?? ""
        let tokens = requestLine.split(separator: " ")
        let path = tokens.count > 1 ? String(tokens[1]) : "/"
        let body = headerEnd.map { String(text[$0.upperBound...]) } ?? ""

        switch path {
        case "/", "/state":
            return currentStateJSON()
        case "/start":
            TranslationEngine.shared.start()
            return currentStateJSON()
        case "/stop":
            TranslationEngine.shared.stop()
            return currentStateJSON()
        case "/config":
            applyConfig(body)
            return currentStateJSON()
        default:
            return "{\"error\":\"unknown path\"}"
        }
    }

    private func applyConfig(_ jsonBody: String) {
        guard let data = jsonBody.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let engine = TranslationEngine.shared
        if let src = obj["src"] as? String { engine.selectedSrcID = src }
        if let tgt = obj["tgt"] as? String { engine.selectedTgtID = tgt }
        if let device = obj["device"] as? String { engine.selectedDevice = device }
        if let glossary = obj["glossary"] as? String { engine.terminologyGlossaryText = glossary }
        if let hf = obj["highFidelity"] as? Bool { engine.highFidelityTranslation = hf }
    }

    // MARK: State snapshot

    private struct LineDTO: Codable {
        let id: Int
        let original: String
        let translated: String?
    }

    private struct DeviceDTO: Codable {
        let name: String
        let isDefault: Bool
    }

    private struct StateDTO: Codable {
        let isRunning: Bool
        let partial: String
        let lines: [LineDTO]
        let selectedSrcID: String
        let selectedTgtID: String
        let selectedDevice: String
        let systemAudioID: String
        let inputDevices: [DeviceDTO]
        let terminologyGlossaryText: String
        let startError: String?
        let startupStatus: String?
        let originalScrollMetrics: ScrollMetrics
        let translationScrollMetrics: ScrollMetrics
    }

    private func currentStateJSON() -> String {
        let engine = TranslationEngine.shared
        let state = StateDTO(
            isRunning: engine.isRunning,
            partial: engine.originalPartial,
            lines: engine.subtitleLines.map { LineDTO(id: $0.id, original: $0.original, translated: $0.translated) },
            selectedSrcID: engine.selectedSrcID,
            selectedTgtID: engine.selectedTgtID,
            selectedDevice: engine.selectedDevice,
            systemAudioID: TranslationEngine.systemAudioID,
            inputDevices: engine.inputDevices.map { DeviceDTO(name: $0.name, isDefault: $0.isDefault) },
            terminologyGlossaryText: engine.terminologyGlossaryText,
            startError: engine.startError,
            startupStatus: engine.startupStatus,
            originalScrollMetrics: engine.originalScrollMetrics,
            translationScrollMetrics: engine.translationScrollMetrics
        )
        guard let data = try? JSONEncoder().encode(state), let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
#endif
