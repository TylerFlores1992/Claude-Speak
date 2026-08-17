import Foundation

/// Optional higher-quality TTS. Everything works without it — the app defaults
/// to `AVSpeechSynthesizer`, which is free and offline.
struct ElevenLabsClient {
    static let defaultBaseURL = URL(string: "https://api.elevenlabs.io")!
    /// Low-latency model — matters when you're waiting for a reply in your ear.
    static let defaultModelID = "eleven_turbo_v2_5"
    /// A stock ElevenLabs voice, used when the user hasn't chosen one.
    static let fallbackVoiceID = "21m00Tcm4TlvDq8ikWAM"

    enum ElevenLabsError: LocalizedError {
        case missingAPIKey
        case http(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No ElevenLabs API key. Add one in Settings or switch back to the system voice."
            case .http(let status, let body):
                return "ElevenLabs HTTP \(status): \(body.prefix(200))"
            }
        }
    }

    var baseURL: URL = ElevenLabsClient.defaultBaseURL
    var session: URLSession = .shared
    var apiKeyProvider: @Sendable () -> String? = { KeychainStore.get(.elevenLabsAPIKey) }

    /// Returns MP3 audio data for `text`.
    func synthesize(text: String, voiceID: String) async throws -> Data {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw ElevenLabsError.missingAPIKey
        }
        let voice = voiceID.isEmpty ? Self.fallbackVoiceID : voiceID

        var request = URLRequest(
            url: baseURL.appendingPathComponent("v1/text-to-speech/\(voice)")
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "text": .string(text),
            "model_id": .string(Self.defaultModelID),
        ]))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ElevenLabsError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}
