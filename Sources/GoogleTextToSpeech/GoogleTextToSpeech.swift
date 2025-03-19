import Foundation
import AVFoundation

/// Represents which accent to use for pronunciation
public enum AccentType: String, Equatable, Sendable {
    case american = "US"
    case british = "UK"
}

/// Voice gender type for text-to-speech
public enum VoiceType: String {
    case male = "male"
    case female = "female"
}

// MARK: - Protocol

@MainActor
public protocol AudioServiceType {
    /// Plays audio for a word with specified accent and waits until playback completes
    /// - Parameters:
    ///   - word: The word to pronounce
    ///   - accent: The accent to use for pronunciation
    /// - Returns: True if playback completed naturally, false if it was stopped manually
    func playWordAudio(_ word: String, accent: AccentType) async throws -> Bool
    
    /// Stops any currently playing audio
    func stopAudio()
}

// MARK: - Live Implementation

@available(macOS 10.15, *)
@MainActor
public class LiveAudioService: NSObject, AudioServiceType, @preconcurrency AVAudioPlayerDelegate {

    private var audioPlayer: AVAudioPlayer?
    private let googleCloudApiKey: String
    private let ttsApiUrl = "https://texttospeech.googleapis.com/v1/text:synthesize"
    
    // Continuation to resume execution when audio finishes
    private var playbackContinuation: CheckedContinuation<Bool, Never>?
    
    private let voiceMapping: [AccentType: [VoiceType: String]] = [
        .american: [
            .male: "en-US-Neural2-D",
            .female: "en-US-Neural2-A"
        ],
        .british: [
            .male: "en-GB-Neural2-B",
            .female: "en-GB-Neural2-C"
        ]
    ]
    
    public init(googleCloudApiKey: String) {
        self.googleCloudApiKey = googleCloudApiKey
    }
    
    public func playWordAudio(_ word: String, accent: AccentType) async throws -> Bool {
        // Initialize audio session
        try initAudioSession()
        
        // Stop any currently playing audio and resolve any pending continuation
        stopAudio()
        
        // Default to female voice
        let voiceType: VoiceType = .female
        
        // Request audio from Google Cloud TTS API
        let audioContent = try await fetchGoogleCloudTTS(text: word, accent: accent, voiceType: voiceType)
        
        // Decode base64 audio content
        guard let audioData = Data(base64Encoded: audioContent) else {
            throw NSError(domain: "AudioService", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to decode audio data"])
        }
        
        // Create audio player
        self.audioPlayer = try AVAudioPlayer(data: audioData)
        self.audioPlayer?.delegate = self
        
        // Prepare and play the audio
        self.audioPlayer?.prepareToPlay()
        self.audioPlayer?.play()
        
        // Return and await playback completion
        return await withCheckedContinuation { continuation in
            self.playbackContinuation = continuation
        }
    }
    
    // Initialize audio session
    private func initAudioSession() throws {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .default)
        try audioSession.setActive(true)
        #endif
    }
    
    // Stop any currently playing audio
    public func stopAudio() {
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        
        // If we have a pending continuation, resolve it with 'false' to indicate manual stop
        if let continuation = playbackContinuation {
            continuation.resume(returning: false)
            playbackContinuation = nil
        }
        
        audioPlayer = nil
    }
    
    // AVAudioPlayerDelegate method called when audio finishes playing
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Resume execution with 'true' to indicate natural completion
        playbackContinuation?.resume(returning: true)
        playbackContinuation = nil
        audioPlayer = nil
    }
    
    // Fetch audio from Google Cloud TTS API
    private func fetchGoogleCloudTTS(text: String, accent: AccentType, voiceType: VoiceType) async throws -> String {
        // Map AccentType to language code
        let languageCode = accent == .american ? "en-US" : "en-GB"
        
        // Select the appropriate voice based on accent and gender
        guard let voiceName = voiceMapping[accent]?[voiceType] else {
            throw NSError(domain: "AudioService", code: 1000, userInfo: [NSLocalizedDescriptionKey: "Invalid accent or voice type"])
        }
        
        // Prepare request body
        let requestBody: [String: Any] = [
            "input": ["text": text],
            "voice": [
                "languageCode": languageCode,
                "name": voiceName
            ],
            "audioConfig": [
                "audioEncoding": "MP3"
            ]
        ]
        
        // Convert request body to JSON data
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Create URL with API key
        guard let url = URL(string: "\(ttsApiUrl)?key=\(googleCloudApiKey)") else {
            throw NSError(domain: "AudioService", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        // Set up HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Send request and wait for response
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check if response is valid
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "AudioService", code: 1003, userInfo: [NSLocalizedDescriptionKey: "Invalid response from Google Cloud TTS API"])
        }
        
        // Parse JSON response
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let audioContent = json["audioContent"] as? String {
            return audioContent
        } else {
            throw NSError(domain: "AudioService", code: 1004, userInfo: [NSLocalizedDescriptionKey: "Failed to parse audio content from response"])
        }
    }
}
