
# GeoIQ iOS Vision Bot SDK

The **GeoIQ iOS Video SDK** provides a lightweight and customizable way to integrate real-time video and audio communication into your iOS applications. It supports Swift and SwiftUI, and leverages Combine for reactive event handling.

---

## ✨ Features

- Join video rooms using WebSocket URL and JWT token
- Control microphone and camera state
- Receive real-time events for participants, tracks, and active speakers
- Send and receive custom data messages
- SwiftUI-compatible video rendering components
- Reactive programming with Combine

---

## 📦 Installation

To install using **Swift Package Manager**, add the following to your Xcode project:

```
https://github.com/geoiq-tech-team/geoiq-vision-bot-ios-sdk/
```

Then import it in your code:

```swift
import geoiq_ios_sdk
```

---

## 🚀 Quick Start

### 1. Create SDK Instance

```swift
let sdkManager = VisionBotSDKMananger()
```

### 2. Subscribe to Events

```swift
sdkManager.eventPublisher
    .sink { event in
        print("Event received: \(event)")
    }
    .store(in: &cancellables)
```

### 3. Connect to a Room

```swift
sdkManager.connect(url: "wss://your-server.com", token: "your_jwt_token")
```

### 4. Control Media

```swift
sdkManager.muteMicrophone(true)
sdkManager.enableCamera(true)
```

### 5. Disconnect

```swift
sdkManager.disconnect()
```

---

## 🧪 Sample App (SwiftUI)

Here's a basic example using SwiftUI:

```swift
struct ContentView: View {
    @StateObject var viewModel = VideoTestViewModel()

    var body: some View {
        VStack {
            if let track = viewModel.localVideoTrack {
                VideoView(videoTrack: track)
                    .frame(width: 160, height: 120)
            }

            Text("🔌 \(viewModel.connectionStatus)")
            Text("🎙 Mic: \(viewModel.micStatus)")
            Text("📷 Camera: \(viewModel.cameraStatus)")

            Button("Connect", action: viewModel.connect)
            Button("Disconnect", action: viewModel.disconnect)
            Button(viewModel.isMicMuted ? "Unmute Mic" : "Mute Mic", action: viewModel.toggleMic)
            Button(viewModel.isCameraEnabled ? "Disable Camera" : "Enable Camera", action: viewModel.toggleCamera)
        }
        .onAppear(perform: viewModel.setup)
    }
}
```

---

## 🔔 Event Types

The SDK emits events via `eventPublisher` using Combine. Here are some examples:

| Event | Description |
|-------|-------------|
| `.connecting(url, tokenSnippet)` | Starting connection to server |
| `.connected(roomName, localParticipant)` | Connection established |
| `.disconnected(reason)` | Disconnected from room |
| `.participantJoined(participant)` | Remote participant joined |
| `.participantLeft(participant)` | Remote participant left |
| `.trackSubscribed(track, publication, participant)` | A track was subscribed |
| `.trackUnsubscribed(track, publication, participant)` | A track was unsubscribed |
| `.localMicStateChanged(isMuted)` | Microphone state changed |
| `.localCameraStateChanged(isEnabled)` | Camera state changed |
| `.localSpeakingChanged(isSpeaking)` | Local speaking status changed |
| `.activeSpeakersChanged([participants])` | Currently active speakers updated |
| `.customMessageReceived(from, message, topic)` | Received a custom message |
| `.error(message, error)` | An error occurred |

---

## 🧩 Custom Video Views

Use the built-in SwiftUI video rendering view:

```swift
VideoView(videoTrack: track)
    .frame(width: 160, height: 120)
```

---

## 🛡 Permissions

Add the following keys to your `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app requires access to the camera.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app requires access to the microphone.</string>
```

---

## 🧼 Cleanup

Always disconnect and shutdown the SDK when leaving a room:

```swift
sdkManager.disconnect()
sdkManager.shutdown()
```

---
