import Foundation

enum SummaryError: LocalizedError { case missingAPIKey, invalidResponse, http(Int, String)
    var errorDescription: String? { switch self { case .missingAPIKey: "Add a Gemma API key in Settings."; case .invalidResponse: "The summary provider returned invalid structured JSON."; case let .http(code, text): "Summary provider error \(code): \(text)" } }
}

struct NoSummaryProvider: SummaryProvider { let identity = "No Summary"; func summarize(transcript: Transcript) async throws -> MeetingSummary? { nil } }

struct OllamaSummaryProvider: SummaryProvider {
    let endpoint: URL; let model: String; let session: URLSession
    init(endpoint: String, model: String, session: URLSession = .shared) throws { guard let endpoint = URL(string: endpoint) else { throw SummaryError.invalidResponse }; self.endpoint = endpoint; self.model = model; self.session = session }
    var identity: String { "Ollama" }
    func summarize(transcript: Transcript) async throws -> MeetingSummary? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate")); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false, "temperature": 0, "format": Self.schema(), "prompt": prompt(transcript.text)])
        let (data, response) = try await session.data(for: request); guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw SummaryError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "") }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]; guard let content = object?["response"] as? String else { throw SummaryError.invalidResponse }; return try SummaryJSON.parse(content)
    }
    static func schema() -> [String: Any] { ["type": "object", "required": ["summary", "decisions", "actionItems", "openQuestions", "technicalDetails"], "properties": ["summary": ["type": "string"], "decisions": ["type": "array", "items": ["type": "string"]], "actionItems": ["type": "array", "items": ["type": "object", "required": ["task"], "properties": ["task": ["type": "string"], "owner": ["type": "string"]]]], "openQuestions": ["type": "array", "items": ["type": "string"]], "technicalDetails": ["type": "array", "items": ["type": "string"]]]] }
}

struct GemmaSummaryProvider: SummaryProvider {
    let model: String; let apiKey: String; let session: URLSession
    var identity: String { "Gemma" }
    func summarize(transcript: Transcript) async throws -> MeetingSummary? {
        guard !apiKey.isEmpty else { throw SummaryError.missingAPIKey }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else { throw SummaryError.invalidResponse }
        let body: [String: Any] = ["contents": [["parts": [["text": prompt(transcript.text)]]]], "generationConfig": ["temperature": 0, "responseMimeType": "application/json", "responseJsonSchema": OllamaSummaryProvider.schema()]]
        var last: Error = SummaryError.invalidResponse
        for attempt in 0..<3 { do { var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body); let (data, response) = try await session.data(for: request); guard let http = response as? HTTPURLResponse else { throw SummaryError.invalidResponse }; if (200..<300).contains(http.statusCode) { let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]; guard let candidates = root?["candidates"] as? [[String: Any]], let content = candidates.first?["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]], let text = parts.first?["text"] as? String else { throw SummaryError.invalidResponse }; return try SummaryJSON.parse(text) }; let message = String(data: data, encoding: .utf8) ?? ""; let error = SummaryError.http(http.statusCode, message); guard http.statusCode == 429 || http.statusCode >= 500, attempt < 2 else { throw error }; last = error; let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? (attempt + 1); try await Task.sleep(for: .seconds(retry)) } catch { last = error; if attempt == 2 { throw error } } }
        throw last
    }
}

private func prompt(_ transcript: String) -> String { """
Create a factual meeting summary only from the transcript below. Return JSON matching the supplied schema. Do not invent information. Preserve names, dates, measurements, and technical terms exactly. Use empty arrays when no information is present.

TRANSCRIPT:
\(transcript)
""" }

enum SummaryJSON {
    static func parse(_ source: String) throws -> MeetingSummary {
        let stripped = source.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        let summary = try JSONDecoder().decode(MeetingSummary.self, from: Data(stripped.utf8))
        guard !summary.summary.isEmpty, summary.actionItems.allSatisfy({ !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw SummaryError.invalidResponse }
        return summary
    }
}
