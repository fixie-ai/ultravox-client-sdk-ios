import AVFoundation
import Foundation
import LiveKit
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

    func isLive() -> Bool {
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
    let text: String

    /// Whether the text is complete or the utterance is ongoing.
    let isFinal: Bool

    /// Who emitted the utterance.
    let speaker: Role

    /// The medium through which the utterance was emitted.
    let medium: Medium

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
/// from JSON) and return a `ClientToolResult` object. It may or may not be
/// asynchronous.
public typealias ClientToolImplementation = (_ data: [String: Any]) -> ClientToolResult

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
                room?.localParticipant.setMicrophoneEnabled(!micMuted)
                NotificationCenter.default.post(name: .micMuted, object: nil)
            }
        }
    }

    /// The current mute status of the user's speaker (i.e. agent output audio).
    ///
    /// This doesn't inspect hardware state or system volume.
    public private(set) var speakerMuted: Bool = false {
        didSet {
            if speakerMuted != oldValue {
                for participant in room?.remoteParticipants ?? [] {
                    for publication in participant.validTrackPublications {
                        if publication.kind == .audio {
                            publication.enabled = !speakerMuted
                        }
                    }
                }
                NotificationCenter.default.post(name: .speakerMuted, object: nil)
            }
        }
    }

    private var webSocketTask: URLSessionWebSocketTask?
    private var room: Room?
    private var registeredTools: [String: ClientToolImplementation] = [:]
    private var experimentalMessages: Set<String>

    init(experimentalMessages: Set<String> = []) {
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
    public func registerToolImplementations(implementations: [String: ClientToolImplementation]) {
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
            webSocketTask = URLSession.shared.webSocketTask(with: URLRequest(url: finalUrl), delegate: self)
            webSocketTask?.resume()
            webSocketTask?.receive { result in
                switch result {
                case let .failure(error):
                    print("Error receiving message: \(error)")
                case let .success(message):
                    switch message {
                    case let .string(text):
                        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
                        switch message["type"] as? String {
                        case "room_info":
                            guard let roomInfo = message["room_info"] as? [String: Any] else { return }
                            guard let roomUrl = roomInfo["roomUrl"] as? String else { return }
                            guard let token = roomInfo["token"] as? String else { return }
                            room = Room(delegate: self)
                            await room.connect(url: roomUrl, token: token)
                            await room.localParticipant.setMicrophoneEnabled(!micMuted)
                            self.status = .idle
                        default:
                            break
                        }
                    case let .data(data):
                        break
                    @unknown default:
                        break
                    }
                }
            }
        }
    }

    /// Leaves the current call (if any).
    public func leaveCall() {
        disconnect()
    }

    /// Sets the agent's output medium.
    ///
    /// If the agent is currently speaking, this will take effect at the end of
    /// the agent's utterance. Also see `speakerMuted`.
    public func setOutputMedium(_ medium: Medium) {
        guard status.isLive() else {
            print("Cannot set speaker medium while not connected. Current status: \(status)")
            return
        }
        sendData(data: ["type": "set_output_medium", "medium": medium == .voice ? "voice" : "text"])
    }

    /// Sends a message via text.
    public func sendText(_ text: String) {
        guard status.isLive() else {
            print("Cannot send text while not connected. Current status: \(status)")
            return
        }
        sendData(data: ["type": "input_text_message", "text": text])
    }

    /// Toggles the mute status of the user's microphone.
    public func toggleMicMuted() {
        micMuted = !micMuted
    }

    /// Toggles the mute status of the user's speaker.
    public func toggleSpeakerMuted() {
        speakerMuted = !speakerMuted
    }

    private func addOrUpdateTranscript(_ transcript: Transcript) {
        if let last = _transcripts.last, !last.isFinal, last.speaker == transcript.speaker {
            _transcripts.removeLast()
        }
        _transcripts.append(transcript)
        NotificationCenter.default.post(name: .transcripts, object: nil)
    }

    private func invokeClientTool(toolName: String, invocationId: String, parameters: [String: Any]) {
        guard let implementation = registeredTools[toolName] else {
            sendData(data: [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "errorType": "undefined",
                "errorMessage": "Client tool \(toolName) is not registered (iOS client)",
            ])
            return
        }
        do {
            let result = implementation(parameters)
            var data: [String: Any] = [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "result": result.result,
            ]
            if let responseType = result.responseType {
                data["responseType"] = responseType
            }
            sendData(data: data)
        } catch {
            sendData(data: [
                "type": "client_tool_result",
                "invocationId": invocationId,
                "errorType": "implementation-error",
                "errorMessage": "\(error)",
            ])
        }
    }

    private func sendData(data: [String: Any]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else { return }
        await room?.localParticipant.publish(data: jsonData, options: DataPublishOptions(reliable: true))
    }

    private func disconnect() {
        guard status != .disconnected else {
            return
        }
        status = .disconnecting
        await room?.disconnect()
        await webSocketTask?.close()
        status = .disconnected
    }
}

extension UltravoxSession: URLSessionWebSocketDelegate {
    public nonisolated func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {}

    public nonisolated func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        Task {
            await disconnect()
        }
    }
}

extension UltravoxSession: RoomDelegate {
    public nonisolated func room(_: Room, participant _: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        guard let message = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }
        switch message["type"] as? String {
        case "state":
            Task {
                if let state = message["state"] as? String {
                    switch state {
                    case "listening":
                        status = .listening()
                    case "thinking":
                        status = .thinking()
                    case "speaking":
                        status = .speaking()
                    default:
                        break
                    }
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
                Task {
                    await addOrUpdateTranscript(transcript)
                }
            }
        case "voice_synced_transcript", "agent_text_transcript":
            let medium = message["type"] as? String == "voice_synced_transcript" ? Medium.voice : Medium.text
            if let text = message["text"] as? String,
               let isFinal = message["final"] as? Bool
            {
                let transcript = Transcript(text: text, isFinal: isFinal, speaker: .agent, medium: medium)
                Task {
                    await addOrUpdateTranscript(transcript)
                }
            } else if let delta = message["delta"] as? String,
                      let isFinal = message["final"] as? Bool,
                      let last = transcriptsNotifier.transcripts.last,
                      last.speaker == .agent
            {
                let updatedText = last.text + delta
                let transcript = Transcript(text: updatedText, isFinal: isFinal, speaker: .agent, medium: medium)
                Task {
                    await addOrUpdateTranscript(transcript)
                }
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
}

public extension Notification.Name {
    static let status = Notification.Name("UltravoxSession.status")
    static let transcripts = Notification.Name("UltravoxSession.transcripts")
    static let experimentalMessage = Notification.Name("UltravoxSession.experimental_message")
    static let micMuted = Notification.Name("UltravoxSession.mic_muted")
    static let speakerMuted = Notification.Name("UltravoxSession.speaker_muted")
}
