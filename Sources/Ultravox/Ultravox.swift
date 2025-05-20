import AVFoundation
import Foundation
@preconcurrency import LiveKit
import Network
import WebKit

// MARK: - SDK Version

private let sdkVersion: String = "0.0.9"

// MARK: - Enums

/// The current status of an `UltravoxSession`.
public enum UltravoxSessionStatus {
    /// The voice session is not connected and not attempting to connect.
    ///
    /// This is the initial state of a voice session.
    case disconnected

    /// The client is disconnecting from the voice session.
    case disconnecting

    /// The client is attempting to connect to the voice session.
    case connecting

    /// The client is connected to the voice session and the server is warming up.
    case idle

    /// The client is connected and the server is listening for voice input.
    case listening

    /// The client is connected and the server is considering its response.
    ///
    /// The user can still interrupt.
    case thinking

    /// The client is connected and the server is playing response audio.
    ///
    /// The user can interrupt as needed.
    case speaking

    public func isLive() -> Bool {
        switch self {
        case .idle, .listening, .thinking, .speaking:
            true
        default:
            false
        }
    }
}

/// The participant responsible for an utterance.
public enum Role {
    case user
    case agent
}

/// How a message was communicated.
public enum Medium {
    case voice
    case text
}

// MARK: - Transcript

/// A transcription of a single utterance.
public struct Transcript {
    /// The possibly-incomplete text of an utterance.
    public let text: String

    /// Whether the text is complete or the utterance is ongoing.
    public let isFinal: Bool

    /// Who emitted the utterance.
    public let speaker: Role

    /// The medium through which the utterance was emitted.
    public let medium: Medium

    init(text: String, isFinal: Bool, speaker: Role, medium: Medium) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.medium = medium
    }
}

// MARK: - Client Tool Implementation types

/// The result type returned by a ClientToolImplementation.
public struct ClientToolResult {
    /// The result of the client tool.
    ///
    /// This is exactly the string that will be seen by the model. Often JSON.
    let result: String

    /// The type of response the tool is providing.
    ///
    /// Most tools simply provide information back to the model, in which case
    /// responseType need not be set. For other tools that are instead interpreted
    /// by the server to affect the call, responseType may be set to indicate how
    /// the call should be altered. In this case, `result` should be JSON with
    /// instructions for the server.
    let responseType: String?

    public init(result: String, responseType: String? = nil) {
        self.result = result
        self.responseType = responseType
    }
}

/// A function that fulfills a client-implemented tool.
///
/// The function should take a map containing the tool's parameters (parsed
/// from JSON) and return a `ClientToolResult` object.
public typealias ClientToolImplementation = (_ data: [String: Any]) throws -> ClientToolResult

// MARK: - UltravoxSession

/// Manages a single session with Ultravox.
///
/// In addition to providing methods to manage a call, `UltravoxSession` emits events to
/// allow UI elements to listen for specific state changes.
@MainActor
public final class UltravoxSession: NSObject {
    /// The current status of the session.
    public private(set) var status: UltravoxSessionStatus = .disconnected {
        didSet {
            if status != oldValue {
                NotificationCenter.default.post(name: .status, object: nil)
            }
        }
    }

    private var _transcripts: [Transcript?] = []
    /// The transcripts exchanged during the call.
    public var transcripts: [Transcript] {
        let immutableCopy = _transcripts.compactMap(\.self)
        return immutableCopy
    }

    /// The most recent transcript exchanged.
    public var lastTranscript: Transcript? {
        transcripts.last
    }

    /// The current mute status of the user's microphone.
    ///
    /// This doesn't inspect hardware state.
    public private(set) var micMuted: Bool = false {
        didSet {
            if micMuted != oldValue {
                Task {
                    do {
                        try await room?.localParticipant.setMicrophone(enabled: !micMuted)
                        NotificationCenter.default.post(name: .micMuted, object: nil)
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }

    /// The current mute status of the user's speaker (i.e. agent output audio).
    ///
    /// This doesn't inspect hardware state or system volume.
    public private(set) var speakerMuted: Bool = false {
        didSet {
            if speakerMuted != oldValue {
                Task {
                    do {
                        for (_, participant) in room?.remoteParticipants ?? [:] {
                            for publication in participant.audioTracks {
                                try await (publication as! RemoteTrackPublication).set(enabled: !speakerMuted)
                            }
                        }
                        NotificationCenter.default.post(name: .speakerMuted, object: nil)
                    }
                }
            }
        }
    }

    private var socket: WebSocketConnection?
    private var room: Room?
    private var registeredTools: [String: ClientToolImplementation] = [:]
    private var experimentalMessages: Set<String>

    public init(experimentalMessages: Set<String> = []) {
        self.experimentalMessages = experimentalMessages
    }

    /// Registers a client tool implementation using the given name.
    ///
    /// If the call is started with a client-implemented tool, this implementation
    /// will be invoked when the model calls the tool.
    public func registerToolImplementation(name: String, implementation: @escaping ClientToolImplementation) {
        registeredTools[name] = implementation
    }

    /// Convenience batch wrapper for `registerToolImplementation`.
    public func registerToolImplementations(_ implementations: [String: ClientToolImplementation]) {
        for (name, implementation) in implementations {
            registerToolImplementation(name: name, implementation: implementation)
        }
    }

    /// Connects to a call using the given `joinUrl`.
    public func joinCall(joinUrl: String, clientVersion: String? = nil) async {
        guard let url = URL(string: joinUrl) else { 
            print("Invalid join URL: \(joinUrl)")
            status = .disconnected // Ensure status is reset
            return
        }
        precondition(status == .disconnected, "Cannot join a call while already connected.")
        status = .connecting
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = urlComponents?.queryItems ?? []
        var uvClientVersion = "ios_\(sdkVersion)"
        if clientVersion != nil {
            uvClientVersion += ":\(clientVersion ?? "")"
        }
        queryItems.append(URLQueryItem(name: "clientVersion", value: uvClientVersion))
        queryItems.append(URLQueryItem(name: "apiVersion", value: "1"))
        if !experimentalMessages.isEmpty {
            queryItems.append(URLQueryItem(name: "experimentalMessages", value: experimentalMessages.joined(separator: ",")))
        }
        urlComponents?.queryItems = queryItems
        if let finalUrl = urlComponents?.url {
            socket = WebSocketConnection(url: finalUrl)
            
            do {
                // receiveOnce() now throws on error, or returns RoomInfoMessage? (though current impl should always return non-nil on success)
                guard let roomInfo = try await socket?.receiveOnce() else {
                    print("Failed to receive room info: receiveOnce returned nil or socket was nil.")
                    await disconnect()
                    return
                }
                room = Room(delegate: self)
                try await room?.connect(url: roomInfo.roomUrl, token: roomInfo.token)
                try await room?.localParticipant.setMicrophone(enabled: !micMuted)
                status = .idle
            } catch {
                print("Error during call setup (receiving room info or connecting to LiveKit): \(error)")
                await disconnect() // This will set status to .disconnected and clean up socket/room
            }
        } else {
            print("Could not construct final URL for WebSocket connection.")
            status = .disconnected // Ensure status is reset
        }
    }

    /// Leaves the current call (if any).
    public func leaveCall() async {
        await disconnect()
    }

    /// Sets the agent's output medium.
    ///
    /// If the agent is currently speaking, this will take effect at the end of
    /// the agent's utterance. Also see `speakerMuted`.
    public func setOutputMedium(_ medium: Medium) async {
        guard status.isLive() else {
            print("Cannot set speaker medium while not connected. Current status: \(status)")
            return
        }
        await sendData(data: ["type": "set_output_medium", "medium": medium == .voice ? "voice" : "text"])
    }

    /// Sends a message via text.
    public func sendText(_ text: String) async {
        guard status.isLive() else {
            print("Cannot send text while not connected. Current status: \(status)")
            return
        }
        await sendData(data: ["type": "input_text_message", "text": text])
    }

    /// Sends an arbitrary data message to the server.
    ///
    /// See https://docs.ultravox.ai/datamessages for message types.
    public func sendData(data: [String: Any]) async {
        guard data["type"] != nil else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else { return }
        if jsonData.count > 1024 {
            await socket?.send(data: jsonData)
        } else {
            do {
                try await room?.localParticipant.publish(data: jsonData, options: DataPublishOptions(reliable: true))
            } catch {
                print("Error publishing data: \(error)")
            }
        }
    }

    /// Toggles the mute status of the user's microphone.
    public func toggleMicMuted() {
        micMuted = !micMuted
    }

    /// Toggles the mute status of the user's speaker.
    public func toggleSpeakerMuted() {
        speakerMuted = !speakerMuted
    }

    private func handleData(message: [String: Any]) {
        NotificationCenter.default.post(name: .dataMessage, object: message)
        switch message["type"] as? String {
        case "state":
            if let state = message["state"] as? String {
                switch state {
                case "listening":
                    status = .listening
                case "thinking":
                    status = .thinking
                case "speaking":
                    status = .speaking
                default:
                    break
                }
            }
        case "transcript":
            if let ordinal = message["ordinal"] as? Int {
                let medium = message["medium"] as? String == "voice" ? Medium.voice : Medium.text
                let role = message["role"] as? String == "agent" ? Role.agent : Role.user
                let isFinal = message["final"] as? Bool ?? false
                addOrUpdateTranscript(ordinal: ordinal, medium: medium, role: role, isFinal: isFinal, text: message["text"] as? String, delta: message["delta"] as? String)
            }
        case "client_tool_invocation":
            if let toolName = message["toolName"] as? String,
               let invocationId = message["invocationId"] as? String,
               let parameters = message["parameters"] as? [String: Any]
            {
                Task {
                    await invokeClientTool(toolName: toolName, invocationId: invocationId, parameters: parameters)
                }
            }
        default:
            if !experimentalMessages.isEmpty {
                NotificationCenter.default.post(name: .experimentalMessage, object: message)
            }
        }
    }

    private func addOrUpdateTranscript(ordinal: Int, medium: Medium, role: Role, isFinal: Bool, text: String?, delta: String?) {
        while _transcripts.count < ordinal {
            _transcripts.append(nil)
        }
        if _transcripts.count == ordinal {
            _transcripts.append(Transcript(text: text ?? delta ?? "", isFinal: isFinal, speaker: role, medium: medium))
        } else {
            let priorText = _transcripts[ordinal]?.text ?? ""
            _transcripts[ordinal] = Transcript(text: text ?? (priorText + (delta ?? "")), isFinal: isFinal, speaker: role, medium: medium)
        }
        NotificationCenter.default.post(name: .transcripts, object: nil)
    }

    private func invokeClientTool(toolName: String, invocationId: String, parameters: [String: Any]) async {
        guard let implementation = registeredTools[toolName] else {
            await sendData(data: [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "errorType": "undefined",
                "errorMessage": "Client tool \(toolName) is not registered (iOS client)",
            ])
            return
        }
        do {
            let result = try implementation(parameters)
            var data: [String: Any] = [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "result": result.result,
            ]
            if let responseType = result.responseType {
                data["responseType"] = responseType
            }
            await sendData(data: data)
        } catch {
            await sendData(data: [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "errorType": "implementation-error",
                "errorMessage": "\(error)",
            ])
        }
    }

    private func disconnect() async {
        guard status != .disconnected else {
            return
        }
        status = .disconnecting
        await room?.disconnect()
        socket = nil
        status = .disconnected
    }
}

extension UltravoxSession: RoomDelegate {
    public nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        Task {
            guard let message = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
            await self.handleData(message: message)
        }
    }
}

public extension Notification.Name {
    static let status = Notification.Name("UltravoxSession.status")
    static let transcripts = Notification.Name("UltravoxSession.transcripts")
    static let dataMessage = Notification.Name("UltravoxSession.data_message")
    static let experimentalMessage = Notification.Name("UltravoxSession.experimental_message")
    static let micMuted = Notification.Name("UltravoxSession.mic_muted")
    static let speakerMuted = Notification.Name("UltravoxSession.speaker_muted")
}

private struct RoomInfoMessage: Sendable {
    let roomUrl: String
    let token: String
}

// MARK: - WebSocketConnection Actor

// Converted to an actor to manage mutable state for Sendable conformance.
private actor WebSocketConnection: NSObject {
    // NWConnection related properties
    private let connection: NWConnection
    private let serialQueue = DispatchQueue(label: "com.ultravox.websocket.serial") // For NWConnection operations
    
    // Continuations for bridging delegate/callback patterns with async/await
    private var messageContinuation: AsyncThrowingStream<RoomInfoMessage, Error>.Continuation?
    private var receivedRoomInfoContinuation: CheckedContinuation<RoomInfoMessage?, Error>?

    init(
        url: URL
    ) {
        let endpoint = NWEndpoint.url(url)
        let parameters: NWParameters
        if url.scheme == "wss" {
            parameters = NWParameters.tls
        } else {
            parameters = NWParameters.tcp
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        self.connection = NWConnection(to: endpoint, using: parameters)
        super.init()
        // Defer starting the connection until a receive method is called.
    }

    private func startConnection() {
        // This method is called when receiveOnce or generalMessageStream is invoked.
        // All subsequent operations on connection (handlers, receiveNextMessage) are scheduled on serialQueue.
        setupConnectionHandlers()
        self.connection.start(queue: serialQueue)
    }

    private func setupConnectionHandlers() {
        connection.stateUpdateHandler = { [weak self] newState in // weak self might be redundant for actor but safe
            // Dispatch to actor's serial executor to ensure state mutation is synchronized
            Task {
                guard let self = self else { return }
                await self.handleConnectionStateUpdate(newState)
            }
        }
    }
    
    private func handleConnectionStateUpdate(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            print("WebSocket connection ready.")
            receiveNextMessage() // Start receiving messages
        case .failed(let error):
            print("WebSocket connection failed: \(error)")
            receivedRoomInfoContinuation?.resume(throwing: error)
            receivedRoomInfoContinuation = nil
            messageContinuation?.finish(throwing: error)
            connection.cancel()
        case .cancelled:
            print("WebSocket connection cancelled.")
            let error = NWError.posix(.ECANCELED)
            receivedRoomInfoContinuation?.resume(throwing: error)
            receivedRoomInfoContinuation = nil
            messageContinuation?.finish(throwing: error)
        case .preparing:
            print("WebSocket connection preparing...")
        case .waiting(let error):
            print("WebSocket connection waiting: \(error)")
            receivedRoomInfoContinuation?.resume(throwing: error)
            receivedRoomInfoContinuation = nil
            messageContinuation?.finish(throwing: error)
        // Ensure all known cases are handled or use @unknown default
        // Explicitly listing known cases for clarity, even with @unknown default later
        case .setup: // NWConnection.State also has .setup
            print("WebSocket connection in setup state.")
        @unknown default:
            print("WebSocket connection unknown state: \(newState)")
            let error = NWError.posix(.EIO) // Generic I/O error
            receivedRoomInfoContinuation?.resume(throwing: error)
            receivedRoomInfoContinuation = nil
            messageContinuation?.finish(throwing: error)
        }
    }

    deinit {
        connection.cancel()
        messageContinuation?.finish()
        if let continuation = receivedRoomInfoContinuation {
            continuation.resume(throwing: NWError.posix(.ECANCELED))
            // receivedRoomInfoContinuation = nil // Not needed as it's deinit
        }
    }

    private func receiveNextMessage() {
        connection.receiveMessage { [weak self] (completeContent, contentContext, isComplete, error) in
            Task {
                guard let self = self else { return }
                await self.handleReceivedMessage(completeContent: completeContent, contentContext: contentContext, isComplete: isComplete, error: error)
            }
        }
    }
    
    private func handleReceivedMessage(completeContent: Data?, contentContext: NWConnection.ContentContext?, isComplete: Bool, error: Error?) {
        if let error = error {
            print("Error receiving message: \(error)")
            if let continuation = receivedRoomInfoContinuation {
                continuation.resume(throwing: error)
                receivedRoomInfoContinuation = nil
            } else {
                messageContinuation?.finish(throwing: error)
            }
            return
        }

        guard let content = completeContent, isComplete else {
            print("Received incomplete message data or context without error. Waiting for more.")
            receiveNextMessage() // Continue trying to receive
            return
        }
        
        if contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) is NWProtocolWebSocket.Metadata,
           let text = String(data: content, encoding: .utf8) {
            do {
                guard let jsonData = text.data(using: .utf8),
                      let messageDict = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
                      messageDict["type"] as? String == "room_info",
                      let roomUrl = messageDict["roomUrl"] as? String,
                      let token = messageDict["token"] as? String else {
                    print("Received a message, but it's not the RoomInfoMessage or it's malformed: \(text)")
                    receiveNextMessage() // Continue listening
                    return
                }
                let roomInfo = RoomInfoMessage(roomUrl: roomUrl, token: token)
                
                if let continuation = receivedRoomInfoContinuation {
                    continuation.resume(returning: roomInfo)
                    receivedRoomInfoContinuation = nil
                } else {
                    messageContinuation?.yield(roomInfo)
                }
                receiveNextMessage() // Continue listening for more messages

            } catch {
                print("Failed to deserialize RoomInfoMessage JSON: \(error)")
                 if let continuation = receivedRoomInfoContinuation {
                    continuation.resume(throwing: error)
                    receivedRoomInfoContinuation = nil
                } else {
                    messageContinuation?.finish(throwing: error)
                }
                receiveNextMessage() // Attempt to recover by listening
            }
        } else {
            print("Received non-text WebSocket message or unexpected content.")
            receiveNextMessage() // Continue listening
        }
    }

    // This method will provide the first RoomInfoMessage
    func receiveOnce() async throws -> RoomInfoMessage? {
        guard receivedRoomInfoContinuation == nil else {
            print("receiveOnce called while another is already in progress.")
            throw NWError.posix(.EBUSY)
        }
        
        if connection.state == .setup { 
             startConnection()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.receivedRoomInfoContinuation = continuation
        }
    }

    func send(data: Data) {
        guard let str = String(data: data, encoding: .utf8) else {
            print("Failed to convert data to UTF8 for sending via WebSocket")
            return
        }
        
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textContext", metadata: [metadata])

        // Send operation itself doesn't need to be on actor's serial queue unless it manipulates actor state directly before/after.
        // NWConnection's send has its own completion that will be handled.
        connection.send(content: str.data(using: .utf8), contentContext: context, isComplete: true, completion: .contentProcessed { error in
            // This completion handler is called on the NWConnection's queue (self.serialQueue)
            // If we need to update actor state here, we would Task { await self.updateState... }
            if let error = error {
                print("Failed to send data message via WebSocket: \(error)")
            }
        })
    }

    func generalMessageStream() -> AsyncThrowingStream<RoomInfoMessage, Error> {
        if connection.state == .setup {
            startConnection()
        }
        return AsyncThrowingStream { continuation in
            self.messageContinuation = continuation
        }
    }
}