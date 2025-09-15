@_exported import LiveKit
import Foundation
import Combine

public enum GeoVisionEvent {
    case connecting(url: String, tokenSnippet: String)
    case connected(roomName: String, localParticipant: LocalParticipant)
    case disconnected(reason: String?)
    case participantJoined(RemoteParticipant)
    case participantLeft(RemoteParticipant)
    case trackPublished(TrackPublication, LocalParticipant)
    case trackSubscribed(Track, TrackPublication, RemoteParticipant)
    case trackUnsubscribed(Track, TrackPublication, RemoteParticipant)
    case activeSpeakersChanged([Participant])
    case error(message: String, error: Error?)
    case customMessageReceived(from: String?, message: String, topic: String?)
    case localMicStateChanged(enabled: Bool)
    case localCameraStateChanged(enabled: Bool)
    case localSpeakingChanged(isSpeaking: Bool)
    case participantAttributesChanged(participant: Participant, metadata: String)
    case transcriptionReceived(Participant,TrackPublication, [TranscriptionSegment])
    case connectionQualityChanged(quality: ConnectionQuality, participant: Participant)
}

open class VisionBotSDKMananger: NSObject, RoomDelegate, ParticipantDelegate {

    public let eventPublisher = PassthroughSubject<GeoVisionEvent, Never>()
    private(set) public var room: Room?

    public override init() {
        self.room = Room()
        super.init()
        room?.delegates.add(delegate: self)
    }

    // MARK: - Public Accessors

    public var currentRoom: Room? {
        return room
    }

    public var localParticipant: LocalParticipant? {
        return room?.localParticipant
    }

    public var remoteParticipants: [String: RemoteParticipant] {
        return room?.remoteParticipants.reduce(into: [:]) { result, pair in
            result[pair.key.stringValue] = pair.value
        } ?? [:]
    }

    public var isCameraEnabled: Bool {
        return room?.localParticipant.isCameraEnabled() ?? false
    }

    public var isMicrophoneEnabled: Bool {
        return room?.localParticipant.isMicrophoneEnabled() ?? false
    }

    // MARK: - Public Methods

    public func connect(url: String, token: String) {
        if let existingRoom = room,
           existingRoom.connectionState == .connected || existingRoom.connectionState == .connecting {
            eventPublisher.send(.error(message: "Already connected or connecting.", error: nil))
            return
        }

        eventPublisher.send(.connecting(url: url, tokenSnippet: String(token.suffix(10))))

        Task {
            do {
                try await room?.connect(url: url, token: token)
                if let room = room {
                    room.localParticipant.add(delegate: self)
                    eventPublisher.send(.connected(roomName: room.name ?? "Unnamed", localParticipant: room.localParticipant))
                }
            } catch {
                eventPublisher.send(.error(message: "Connection failed: \(error.localizedDescription)", error: error))
            }
        }
    }

    public func disconnect() {
        Task {
            await room?.disconnect()
            eventPublisher.send(.disconnected(reason: "Manual disconnect"))
            room = nil
        }
    }

    public func shutdown() {
        disconnect()
        room = nil
    }

    public func muteMicrophone(_ mute: Bool) {
        guard let room = room else { return }
        Task {
            do {
                try await room.localParticipant.setMicrophone(enabled: !mute)
                eventPublisher.send(.localMicStateChanged(enabled: !mute))
            } catch {
                eventPublisher.send(.error(message: "Failed to toggle mic", error: error))
            }
        }
    }

    public func enableCamera(_ enable: Bool) {
        guard let room = room else { return }
        let options = CameraCaptureOptions(
            position: .front
        )
        Task {
            do {
                try await room.localParticipant.setCamera(enabled: enable, captureOptions: options)
                eventPublisher.send(.localCameraStateChanged(enabled: enable))
            } catch {
                eventPublisher.send(.error(message: "Failed to toggle camera", error: error))
            }
        }
    }

    public func flipCameraPosition() {
        guard let cameraTrack = room?.localParticipant.videoTracks.first?.track as? LocalVideoTrack,
              
        let cameraCapturer = cameraTrack.capturer as? CameraCapturer else {
            eventPublisher.send(.error(message: "Camera capturer not available.", error: nil))
            return
        }

        Task {
            do {
                try await cameraCapturer.switchCameraPosition()
            } catch {
                eventPublisher.send(.error(message: "Failed to flip camera", error: error))
            }
        }
    }

    // MARK: - RoomDelegate Methods

    public func room(_ room: Room, didUpdate connectionState: ConnectionState, oldState: ConnectionState) {
        if connectionState == .disconnected {
            eventPublisher.send(.disconnected(reason: "Connection lost"))
        }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        participant.add(delegate: self)
        eventPublisher.send(.participantJoined(participant))
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        eventPublisher.send(.participantLeft(participant))
    }

    public func room(_ room: Room, activeSpeakersChanged speakers: [Participant]) {
        eventPublisher.send(.activeSpeakersChanged(speakers))
    }

    public func room(_ room: Room, didReceive data: Data, participant: RemoteParticipant?, topic: String?) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant?.identity?.stringValue
        eventPublisher.send(.customMessageReceived(from: from, message: message, topic: topic))
    }

    public func room(_ room: Room, participant: Participant, trackPublication : TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        eventPublisher.send(.transcriptionReceived(participant, trackPublication, segments))
    }

    // MARK: - ParticipantDelegate Methods

    public func participant(_ participant: RemoteParticipant, didSubscribeTrack track: Track) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        eventPublisher.send(.trackSubscribed(track, publication, participant))
    }

    public func participant(_ participant: RemoteParticipant, didUnsubscribeTrack track: Track) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        eventPublisher.send(.trackUnsubscribed(track, publication, participant))
    }

    public func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant.identity?.stringValue
        eventPublisher.send(.customMessageReceived(from: from, message: message, topic: topic))
    }

    public func participant(_ participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if participant is LocalParticipant {
            switch trackPublication.kind {
            case .audio:
                eventPublisher.send(.localMicStateChanged(enabled: !isMuted))
            case .video:
                eventPublisher.send(.localCameraStateChanged(enabled: !isMuted))
            default:
                break
            }
        }
    }

    public func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        if participant is LocalParticipant {
            eventPublisher.send(.localSpeakingChanged(isSpeaking: isSpeaking))
        }
    }

    public func participant(_ participant: Participant, didUpdateMetadata metadata: String?) {
        // let meta = metadata ?? ""
        // eventPublisher.send(.participantAttributesChanged(participant: participant, metadata: meta))
    }

    public func participant(_ participant: Participant, didUpdateAttributes attributes: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: attributes),
        let jsonString = String(data: data, encoding: .utf8) {
            eventPublisher.send(.participantAttributesChanged(participant: participant, metadata: jsonString))
        }
    }

    public func participant(_ participant: Participant, didUpdateConnectionQuality connectionQuality: ConnectionQuality) {
        eventPublisher.send(
            .connectionQualityChanged(quality: connectionQuality, participant: participant)
        )
    }
}