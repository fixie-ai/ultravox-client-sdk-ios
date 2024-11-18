import AVFoundation
import Foundation
@preconcurrency import LiveKit
import WebKit

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

    init(result: String, responseType: String? = nil) {
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

    private var _transcripts: [Transcript] = []
    /// The transcripts exchanged during the call.
    public var transcripts: [Transcript] {
        let immutableCopy = _transcripts
        return immutableCopy
    }

    /// The most recent transcript exchanged.
    public var lastTranscript: Transcript? {
        _transcripts.last
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
    public func joinCall(joinUrl: String) async {
        guard let url = URL(string: joinUrl) else { return }
        precondition(status == .disconnected, "Cannot join a call while already connected.")
        status = .connecting
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if !experimentalMessages.isEmpty {
            urlComponents?.queryItems = [URLQueryItem(name: "experimentalMessages", value: experimentalMessages.joined(separator: ","))]
        }
        if let finalUrl = urlComponents?.url {
            let webSocketTask = URLSession.shared.webSocketTask(with: URLRequest(url: finalUrl))
            socket = WebSocketConnection(webSocketTask: webSocketTask)
            guard let roomInfo = await socket?.receiveOnce() else { return }
            room = Room(delegate: self)
            do {
                try await room?.connect(url: roomInfo.roomUrl, token: roomInfo.token)
                try await room?.localParticipant.setMicrophone(enabled: !micMuted)
                status = .idle
            } catch {
                room = nil
                print("Error connecting to room: \(error)")
            }
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

    /// Toggles the mute status of the user's microphone.
    public func toggleMicMuted() {
        micMuted = !micMuted
    }

    /// Toggles the mute status of the user's speaker.
    public func toggleSpeakerMuted() {
        speakerMuted = !speakerMuted
    }

    private func handleData(message: [String: Any]) {
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
            if let transcriptData = message["transcript"] as? [String: Any],
               let text = transcriptData["text"] as? String,
               let isFinal = transcriptData["final"] as? Bool,
               let mediumStr = transcriptData["medium"] as? String
            {
                let medium = mediumStr == "voice" ? Medium.voice : Medium.text
                let transcript = Transcript(text: text, isFinal: isFinal, speaker: .user, medium: medium)
                addOrUpdateTranscript(transcript)
            }
        case "voice_synced_transcript", "agent_text_transcript":
            let medium = message["type"] as? String == "voice_synced_transcript" ? Medium.voice : Medium.text
            if let text = message["text"] as? String,
               let isFinal = message["final"] as? Bool
            {
                let transcript = Transcript(text: text, isFinal: isFinal, speaker: .agent, medium: medium)
                addOrUpdateTranscript(transcript)
            } else if let delta = message["delta"] as? String,
                      let isFinal = message["final"] as? Bool,
                      let last = lastTranscript,
                      last.speaker == .agent
            {
                let updatedText = last.text + delta
                let transcript = Transcript(text: updatedText, isFinal: isFinal, speaker: .agent, medium: medium)
                addOrUpdateTranscript(transcript)
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

    private func addOrUpdateTranscript(_ transcript: Transcript) {
        if let last = _transcripts.last, !last.isFinal, last.speaker == transcript.speaker {
            _transcripts.removeLast()
        }
        _transcripts.append(transcript)
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

    private func sendData(data: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else { return }
        do {
            try await room?.localParticipant.publish(data: jsonData, options: DataPublishOptions(reliable: true))
        } catch {
            print("Error publishing data: \(error)")
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
    static let experimentalMessage = Notification.Name("UltravoxSession.experimental_message")
    static let micMuted = Notification.Name("UltravoxSession.mic_muted")
    static let speakerMuted = Notification.Name("UltravoxSession.speaker_muted")
}

private struct RoomInfoMessage: Sendable {
    let roomUrl: String
    let token: String
}

private final class WebSocketConnection: NSObject, Sendable {
    private let webSocketTask: URLSessionWebSocketTask

    init(
        webSocketTask: URLSessionWebSocketTask
    ) {
        self.webSocketTask = webSocketTask
        super.init()
        webSocketTask.resume()
    }

    deinit {
        // Make sure to cancel the WebSocketTask (if not already canceled or completed)
        webSocketTask.cancel(with: .goingAway, reason: nil)
    }

    private func receiveSingleMessage() async throws -> RoomInfoMessage? {
        switch try await webSocketTask.receive() {
        case let .data(messageData):
            print("Unexpected data message")
            return nil

        case let .string(text):
            guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return nil }
            guard message["type"] as? String == "room_info" else { return nil }
            guard let roomUrl = message["roomUrl"] as? String else { return nil }
            guard let token = message["token"] as? String else { return nil }
            return RoomInfoMessage(roomUrl: roomUrl, token: token)

        @unknown default:
            print("Unexpected message type")
            return nil
        }
    }

    func receiveOnce() async -> RoomInfoMessage? {
        do {
            while true {
                let message = try await receiveSingleMessage()
                if message != nil {
                    return message
                }
            }
        } catch {
            print("Failed to receive RoomInfo from WebSocket: \(error)")
            return nil
        }
    }
}
