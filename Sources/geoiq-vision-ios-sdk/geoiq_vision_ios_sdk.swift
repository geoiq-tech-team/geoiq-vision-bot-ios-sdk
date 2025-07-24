import LiveKit
import Foundation
import Combine

public enum GeoVisionEvent {
    case connecting(url: String, tokenSnippet: String)
    case connected(roomName: String, localParticipant: VisionBotLocalParticipant)
    case disconnected(reason: String?)
    case participantJoined(VisionBotRemoteParticipant)
    case participantLeft(VisionBotRemoteParticipant)
    case trackPublished(VisionBotTrackPublication, VisionBotLocalParticipant)
    case trackSubscribed(VisionBotTrack, VisionBotTrackPublication, VisionBotRemoteParticipant)
    case trackUnsubscribed(VisionBotTrack, VisionBotTrackPublication, VisionBotRemoteParticipant)
    case activeSpeakersChanged([VisionBotParticipant])
    case error(message: String, error: Error?)
    case customMessageReceived(from: String?, message: String, topic: String?)
    case localMicStateChanged(enabled: Bool)
    case localCameraStateChanged(enabled: Bool)
    case localSpeakingChanged(isSpeaking: Bool)
    case participantAttributesChanged(participant: VisionBotParticipant, metadata: String)
    case transcriptionReceived(VisionBotParticipant,VisionBotTrackPublication, [VisionBotTranscriptionSegment])
    case connectionQualityChanged(quality: VisionBotConnectionQuality, participant: VisionBotParticipant)
}

public typealias VisionBotRoom = Room
public typealias VisionBotLocalParticipant = LocalParticipant
public typealias VisionBotRemoteParticipant = RemoteParticipant
public typealias VisionBotVideoTrack = VideoTrack
public typealias VisionBotTranscriptionSegment = TranscriptionSegment
public typealias VisionBotDataPublishOptions = DataPublishOptions
public typealias VisionBotVideoView = VideoView
public typealias VisionBotParticipant = Participant
public typealias VisionBotTrackPublication = TrackPublication
public typealias VisionBotTrack = Track
public typealias VisionBotConnectionQuality = ConnectionQuality
public typealias VisionBotConnectionState = ConnectionState
public typealias VisionBotRoomDelegate = RoomDelegate
public typealias VisionBotParticipantDelegate = ParticipantDelegate

open class VisionBotSDKMananger: NSObject, VisionBotRoomDelegate, VisionBotParticipantDelegate {

    public let eventPublisher = PassthroughSubject<GeoVisionEvent, Never>()
    private(set) public var room: VisionBotRoom?

    public override init() {
        self.room = VisionBotRoom()
        super.init()
        room?.delegates.add(delegate: self)
    }

    // MARK: - Public Accessors

    public var currentRoom: VisionBotRoom? {
        return room
    }

    public var localParticipant: VisionBotLocalParticipant? {
        return room?.localParticipant
    }

    public var remoteParticipants: [String: VisionBotRemoteParticipant] {
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

    // MARK: - RoomDelegate Methods

    public func room(_ room: VisionBotRoom, didUpdate connectionState: VisionBotConnectionState, oldState: VisionBotConnectionState) {
        if connectionState == .disconnected {
            eventPublisher.send(.disconnected(reason: "Connection lost"))
        }
    }

    public func room(_ room: VisionBotRoom, participantDidConnect participant: VisionBotRemoteParticipant) {
        participant.add(delegate: self)
        eventPublisher.send(.participantJoined(participant))
    }

    public func room(_ room: VisionBotRoom, participantDidDisconnect participant: VisionBotRemoteParticipant) {
        eventPublisher.send(.participantLeft(participant))
    }

    public func room(_ room: VisionBotRoom, activeSpeakersChanged speakers: [VisionBotParticipant]) {
        eventPublisher.send(.activeSpeakersChanged(speakers))
    }

    public func room(_ room: VisionBotRoom, didReceive data: Data, participant: VisionBotRemoteParticipant?, topic: String?) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant?.identity?.stringValue
        eventPublisher.send(.customMessageReceived(from: from, message: message, topic: topic))
    }

    public func room(_ room: VisionBotRoom, participant: VisionBotParticipant, trackPublication : VisionBotTrackPublication, didReceiveTranscriptionSegments segments: [VisionBotTranscriptionSegment]) {
        eventPublisher.send(.transcriptionReceived(participant, trackPublication, segments))
    }

    // MARK: - ParticipantDelegate Methods

    public func participant(_ participant: VisionBotRemoteParticipant, didSubscribeTrack track: VisionBotTrack) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        eventPublisher.send(.trackSubscribed(track, publication, participant))
    }

    public func participant(_ participant: VisionBotRemoteParticipant, didUnsubscribeTrack track: VisionBotTrack) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        eventPublisher.send(.trackUnsubscribed(track, publication, participant))
    }

    public func participant(_ participant: VisionBotRemoteParticipant, didReceiveData data: Data, forTopic topic: String) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant.identity?.stringValue
        eventPublisher.send(.customMessageReceived(from: from, message: message, topic: topic))
    }

    public func participant(_ participant: VisionBotParticipant, trackPublication: VisionBotTrackPublication, didUpdateIsMuted isMuted: Bool) {
        if participant is VisionBotLocalParticipant {
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

    public func participant(_ participant: VisionBotParticipant, didUpdateIsSpeaking isSpeaking: Bool) {
        if participant is VisionBotLocalParticipant {
            eventPublisher.send(.localSpeakingChanged(isSpeaking: isSpeaking))
        }
    }

    public func participant(_ participant: VisionBotParticipant, didUpdateMetadata metadata: String?) {
        let meta = metadata ?? ""
        eventPublisher.send(.participantAttributesChanged(participant: participant, metadata: meta))
    }

    public func participant(_ participant: VisionBotParticipant, didUpdateConnectionQuality connectionQuality: VisionBotConnectionQuality) {
        eventPublisher.send(
            .connectionQualityChanged(quality: connectionQuality, participant: participant)
        )
    }
}
