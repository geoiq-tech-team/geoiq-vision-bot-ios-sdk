@_exported import LiveKit
import Foundation
import Combine
import AVFoundation

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
    case reconnecting
    case reconnected
}

open class VisionBotSDKMananger: NSObject, RoomDelegate, ParticipantDelegate {

    public let eventPublisher = PassthroughSubject<GeoVisionEvent, Never>()
    private(set) public var room: Room?
    @MainActor
    private var isFlippingCamera = false

    public override init() {
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(position: .front),
            defaultVideoPublishOptions: VideoPublishOptions(
                simulcast: true  // Enable simulcast for better adaptive streaming
            ),
            defaultAudioPublishOptions: AudioPublishOptions(),
            adaptiveStream: true,  // Automatically adjusts video quality based on subscriber viewport
            dynacast: true        // Pauses video layers when no subscribers are watching
        )
        self.room = Room(roomOptions: roomOptions)
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

        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 5,        // Number of reconnection attempts
            reconnectAttemptDelay: 3.0   // Delay between reconnect attempts in seconds
        )
        
        Task {
            do {
                try await room?.connect(url: url, token: token, connectOptions: connectOptions)
                
                if let room = room {
                    room.localParticipant.add(delegate: self)
                    // :dart: THIS IS THE FIX: Manually handle existing participants
                    for (_, participant) in room.remoteParticipants {
                        // Add delegate to receive events from this participant
                        participant.add(delegate: self)
                        // Manually trigger YOUR handler (since delegate won't be called)
                        eventPublisher.send(.participantJoined(participant))
                    }
                    
                    eventPublisher.send(.connected(roomName: room.name ?? "Unnamed", localParticipant: room.localParticipant))
                }
            } catch {
                eventPublisher.send(.error(message: "Connection failed: \(error.localizedDescription)", error: error))
            }
        }
    }

    public func disconnect() {
        Task {
            // Remove delegates before disconnecting
            room?.localParticipant.remove(delegate: self)
            for (_, participant) in room?.remoteParticipants ?? [:] {
                participant.remove(delegate: self)
            }
            
            await room?.disconnect()
            eventPublisher.send(.disconnected(reason: "Manual disconnect"))
            room = nil
        }
    }


    public func shutdown() {
        Task {
            await room?.disconnect()
            room?.delegates.remove(delegate: self)
            room = nil
        }
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
                try await room.localParticipant.setCamera(enabled: enable,captureOptions: options)
                eventPublisher.send(.localCameraStateChanged(enabled: enable))
            } catch {
                eventPublisher.send(.error(message: "Failed to toggle camera", error: error))
            }
        }
    }

    // public func flipCameraPosition() {
    //     // 1. Prevent rapid-fire toggling which crashes the camera session
    //     if isFlippingCamera {
    //         print("VisionBotSDK: Camera flip already in progress, ignoring request")
    //         return
    //     }

    //     // 2. Robust track lookup (finds the specific camera track, not just the first video track)
    //     guard let cameraTrack = room?.localParticipant.videoTracks.first(where: { 
    //         ($0.track as? LocalVideoTrack)?.capturer is CameraCapturer 
    //     })?.track as? LocalVideoTrack,
    //     let cameraCapturer = cameraTrack.capturer as? CameraCapturer else {
    //         eventPublisher.send(.error(message: "Camera capturer not available.", error: nil))
    //         return
    //     }

    //     isFlippingCamera = true
        
    //     Task {
    //         defer { isFlippingCamera = false }
    //         do {
    //             print("VisionBotSDK: Requesting camera switch...")
                
    //             // 3. Use the SDK's built-in toggle. 
    //             // This is safer than manually calculating position and calling .set()
    //             try await cameraCapturer.switchCameraPosition()
                
    //             print("VisionBotSDK: Camera switch command completed successfully")
    //         } catch {
    //             print("VisionBotSDK: Failed to flip camera with error: \(error)")

    //              // 4. Recovery: If flip fails, force reset to Front camera
    //             print("VisionBotSDK: Attempting to recover by resetting to Front camera...")
    //             do {
    //                 try await cameraCapturer.set(cameraPosition: .front)
    //                 print("VisionBotSDK: Recovery to Front camera successful")
    //             } catch let recoveryError {
    //                 print("VisionBotSDK: Recovery failed with error: \(recoveryError)")
    //             }

    //             eventPublisher.send(.error(message: "Failed to flip camera", error: error))
    //         }
    //     }
    // }

    public func flipCameraPosition() {
        Task { @MainActor in
            guard !isFlippingCamera else {
                print("VisionBotSDK: Camera flip already in progress, ignoring request")
                return
            }
            
            guard let cameraTrack = room?.localParticipant.videoTracks.first(where: { 
                ($0.track as? LocalVideoTrack)?.capturer is CameraCapturer 
            })?.track as? LocalVideoTrack,
            let cameraCapturer = cameraTrack.capturer as? CameraCapturer else {
                eventPublisher.send(.error(message: "Camera capturer not available.", error: nil))
                return
            }

            isFlippingCamera = true
            defer { isFlippingCamera = false }
            
            do {
                try await cameraCapturer.switchCameraPosition()
            } catch {
                // Recovery logic...
                print("VisionBotSDK: Attempting to recover by resetting to Front camera...")
                do {
                    try await cameraCapturer.set(cameraPosition: .front)
                    print("VisionBotSDK: Recovery to Front camera successful")
                } catch let recoveryError {
                    print("VisionBotSDK: Recovery failed with error: \(recoveryError)")
                }
                eventPublisher.send(.error(message: "Failed to flip camera", error: error))
            }
        }
    }





    
    // MARK: - RoomDelegate Methods

    public func room(_ room: Room, didUpdate connectionState: ConnectionState, oldState: ConnectionState) {
        switch connectionState {
            case .disconnected:
                eventPublisher.send(.disconnected(reason: "Connection lost"))
            case .reconnecting:
                eventPublisher.send(.reconnecting)
            case .connected:
                if oldState == .reconnecting {
                    eventPublisher.send(.reconnected)
                }
            default:
                break
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

    // public func room(_ room: Room, didReceiveTranscription transcription: Room.Transcription, fromParticipant participant: RemoteParticipant) {
    //     let senderId = participant.identity?.stringValue
    //     for segment in transcription.segments {
    //         eventPublisher.send(.transcriptionReceived(senderId: senderId, message: segment.text, isFinal: segment.isFinal))
    //     }
    // }

    public func room(_ room: Room, participant: Participant, trackPublication : TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        eventPublisher.send(.transcriptionReceived(participant, trackPublication, segments))
    }

    public func room(_ room: Room, localParticipant: LocalParticipant, didFailToPublishTrackWithError error: Error) {
        eventPublisher.send(.error(message: "Failed to publish track: \(error.localizedDescription)", error: error))
    }

    public func room(_ room: Room, participant: RemoteParticipant?, didUpdateNetworkQuality quality: ConnectionQuality) {
        // Network-wide quality monitoring
        if let participant = participant {
            eventPublisher.send(.connectionQualityChanged(quality: quality, participant: participant))
        }
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
    
    public func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant.identity?.stringValue
        // You can now optionally log or check the encryption type
        print("Received data with encryption type: \(encryptionType)")
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
        print("Connection quality changed: \(participant.identity?.stringValue ?? "unknown") - \(connectionQuality)")
        eventPublisher.send(
            .connectionQualityChanged(quality: connectionQuality, participant: participant)
        )
    }
    
}
