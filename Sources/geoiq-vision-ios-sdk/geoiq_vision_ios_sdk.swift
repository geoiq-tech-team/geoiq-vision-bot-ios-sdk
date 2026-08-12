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
}

open class VisionBotSDKMananger: NSObject, RoomDelegate, ParticipantDelegate {

    public let eventPublisher = PassthroughSubject<GeoVisionEvent, Never>()
    private(set) public var room: Room?
    private var isFlippingCamera = false
    private var registeredStreamTopics: Set<String> = []

    /// RoomDelegate/ParticipantDelegate callbacks arrive on LiveKit's internal queue while
    /// Task {} blocks below run on the Swift concurrency thread pool - both can call into
    /// `eventPublisher` concurrently. PassthroughSubject.send(_:) isn't safe under concurrent
    /// multi-thread access, so every emission is funneled through this single serial queue.
    private let eventQueue = DispatchQueue(label: "com.geoiq.visionbot.eventQueue")

    private func emit(_ event: GeoVisionEvent) {
        eventQueue.async { [weak self] in
            self?.eventPublisher.send(event)
        }
    }

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
            emit(.error(message: "Already connected or connecting.", error: nil))
            return
        }
        
        emit(.connecting(url: url, tokenSnippet: String(token.suffix(10))))

        Task {
            do {
                // Register the text-stream handler BEFORE the room connects. Registering
                // afterward left a window where the agent (already present in the room)
                // could publish its first messages - e.g. language preference, recommended
                // products - before we were listening, and LiveKit silently drops text
                // streams that arrive with no handler registered for their topic.
                // Register BEFORE connect
                let topic = "lk_va_publish"
                if !registeredStreamTopics.contains(topic) {
                    try await room?.registerTextStreamHandler(for: topic, onNewStream: handleTextStream)
                    registeredStreamTopics.insert(topic)
                }

                try await room?.connect(url: url, token: token)

                if let room = room {
                    room.localParticipant.add(delegate: self)

                    // :dart: THIS IS THE FIX: Manually handle existing participants
                    for (_, participant) in room.remoteParticipants {
                        // Add delegate to receive events from this participant
                        participant.add(delegate: self)
                        // Manually trigger YOUR handler (since delegate won't be called)
                        emit(.participantJoined(participant))
                    }
                    
                    emit(.connected(roomName: room.name ?? "Unnamed", localParticipant: room.localParticipant))
                }
            } catch {
                emit(.error(message: "Connection failed: \(error.localizedDescription)", error: error))
            }
        }
    }

    public func disconnect() {
        Task {
            // Unregister all text stream handlers
            if let room = room {
                for topic in registeredStreamTopics {
                    await room.unregisterTextStreamHandler(for: topic)
                }
                registeredStreamTopics.removeAll()
            }


            await room?.disconnect()
            emit(.disconnected(reason: "Manual disconnect"))
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
                emit(.localMicStateChanged(enabled: !mute))
            } catch {
                emit(.error(message: "Failed to toggle mic", error: error))
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
                emit(.localCameraStateChanged(enabled: enable))
            } catch {
                emit(.error(message: "Failed to toggle camera", error: error))
            }
        }
    }

    public func flipCameraPosition() {
        // 1. Prevent rapid-fire toggling which crashes the camera session
        if isFlippingCamera {
            print("VisionBotSDK: Camera flip already in progress, ignoring request")
            return
        }

        // 2. Robust track lookup (finds the specific camera track, not just the first video track)
        guard let cameraTrack = room?.localParticipant.videoTracks.first(where: { 
            ($0.track as? LocalVideoTrack)?.capturer is CameraCapturer 
        })?.track as? LocalVideoTrack,
        let cameraCapturer = cameraTrack.capturer as? CameraCapturer else {
            emit(.error(message: "Camera capturer not available.", error: nil))
            return
        }

        isFlippingCamera = true
        
        Task {
            defer { isFlippingCamera = false }
            do {
                print("VisionBotSDK: Requesting camera switch...")
                
                // 3. Use the SDK's built-in toggle. 
                // This is safer than manually calculating position and calling .set()
                try await cameraCapturer.switchCameraPosition()
                
                print("VisionBotSDK: Camera switch command completed successfully")
            } catch {
                print("VisionBotSDK: Failed to flip camera with error: \(error)")

                 // 4. Recovery: If flip fails, force reset to Front camera
                print("VisionBotSDK: Attempting to recover by resetting to Front camera...")
                do {
                    try await cameraCapturer.set(cameraPosition: .front)
                    print("VisionBotSDK: Recovery to Front camera successful")
                } catch let recoveryError {
                    print("VisionBotSDK: Recovery failed with error: \(recoveryError)")
                }

                emit(.error(message: "Failed to flip camera", error: error))
            }
        }
    }
    
    // MARK: - RoomDelegate Methods

    public func room(_ room: Room, didUpdate connectionState: ConnectionState, oldState: ConnectionState) {
        if connectionState == .disconnected {
            emit(.disconnected(reason: "Connection lost"))
        }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        participant.add(delegate: self)
        emit(.participantJoined(participant))
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        emit(.participantLeft(participant))
    }

    public func room(_ room: Room, activeSpeakersChanged speakers: [Participant]) {
        emit(.activeSpeakersChanged(speakers))
    }

    public func room(_ room: Room, didReceive data: Data, participant: RemoteParticipant?, topic: String?) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant?.identity?.stringValue
        emit(.customMessageReceived(from: from, message: message, topic: topic))
    }

    // public func room(_ room: Room, didReceiveTranscription transcription: Room.Transcription, fromParticipant participant: RemoteParticipant) {
    //     let senderId = participant.identity?.stringValue
    //     for segment in transcription.segments {
    //         emit(.transcriptionReceived(senderId: senderId, message: segment.text, isFinal: segment.isFinal))
    //     }
    // }

    public func room(_ room: Room, participant: Participant, trackPublication : TrackPublication, didReceiveTranscriptionSegments segments: [TranscriptionSegment]) {
        emit(.transcriptionReceived(participant, trackPublication, segments))
    }
    

    // MARK: - ParticipantDelegate Methods

    public func participant(_ participant: RemoteParticipant, didSubscribeTrack track: Track) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        emit(.trackSubscribed(track, publication, participant))
    }

    public func participant(_ participant: RemoteParticipant, didUnsubscribeTrack track: Track) {
        guard let sid = track.sid else { return }
        guard let publication = participant.trackPublications[sid] else { return }
        emit(.trackUnsubscribed(track, publication, participant))
    }
    
    public func participant(_ participant: RemoteParticipant, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let message = String(data: data, encoding: .utf8) ?? "<invalid data>"
        let from = participant.identity?.stringValue
        // You can now optionally log or check the encryption type
        print("Received data with encryption type: \(encryptionType)")
        emit(.customMessageReceived(from: from, message: message, topic: topic))
    }

    public func participant(_ participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if participant is LocalParticipant {
            switch trackPublication.kind {
            case .audio:
                emit(.localMicStateChanged(enabled: !isMuted))
            case .video:
                emit(.localCameraStateChanged(enabled: !isMuted))
            default:
                break
            }
        }
    }

    public func participant(_ participant: Participant, didUpdateIsSpeaking isSpeaking: Bool) {
        if participant is LocalParticipant {
            emit(.localSpeakingChanged(isSpeaking: isSpeaking))
        }
    }

    public func participant(_ participant: Participant, didUpdateMetadata metadata: String?) {
        // let meta = metadata ?? ""
        // emit(.participantAttributesChanged(participant: participant, metadata: meta))
    }

    public func participant(_ participant: Participant, didUpdateAttributes attributes: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: attributes),
        let jsonString = String(data: data, encoding: .utf8) {
            emit(.participantAttributesChanged(participant: participant, metadata: jsonString))
        }
    }
    
    public func participant(_ participant: Participant, didUpdateConnectionQuality connectionQuality: ConnectionQuality) {
        print("Connection quality changed: \(participant.identity?.stringValue ?? "unknown") - \(connectionQuality)")
        emit(
            .connectionQualityChanged(quality: connectionQuality, participant: participant)
        )
    }


    // Private Methods

    private func handleTextStream(reader: TextStreamReader, participantIdentity: Participant.Identity) async {
        let info = reader.info
        
        do {
            // Get complete text after stream finishes
            let fullText = try await reader.readAll()
            //  Print the full text
            print("Text stream received from \(participantIdentity.stringValue): \(fullText)")
            emit(.customMessageReceived(
                from: participantIdentity.stringValue, 
                message: fullText, 
                topic: info.topic
            ))
            
        } catch {
            print("Text stream error: \(error)")
            emit(.error(
                message: "Text stream failed: \(error.localizedDescription)", 
                error: error
            ))
        }
    }
    
}
