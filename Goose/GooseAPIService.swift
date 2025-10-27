import Combine
import Foundation

class GooseAPIService: ObservableObject {
    static let shared = GooseAPIService()

    @Published var isConnected = false
    @Published var connectionError: String?

    // The configured URL
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "goose_base_url") ?? "http://127.0.0.1:62996"
    }

    private var secretKey: String {
        UserDefaults.standard.string(forKey: "goose_secret_key") ?? "test"
    }

    // Trial mode detection
    var isTrialMode: Bool {
        return baseURL.contains("demo-goosed.fly.dev")
    }

    private init() {}

    // MARK: - Proper SSE Streaming Implementation
    func startChatStreamWithSSE(
        messages: [Message],
        sessionId: String? = nil,
        onEvent: @escaping (SSEEvent) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async -> URLSessionDataTask? {

        guard let url = URL(string: "\(baseURL)/reply") else {
            onError(APIError.invalidURL)
            return nil
        }

        // Log the sessionId we're about to use
        let actualSessionId = sessionId ?? ""
        print("🔍 Creating ChatRequest with sessionId: '\(actualSessionId)' (was: \(sessionId ?? "nil"))")
        
        let request = ChatRequest(
            messages: messages,
            sessionId: actualSessionId,  // Provide empty string if nil since server requires it
            recipeName: nil,
            recipeVersion: nil
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        do {
            let requestData = try JSONEncoder().encode(request)
            urlRequest.httpBody = requestData

            // Debug logging
            print("🚀 Starting SSE stream to: \(url)")
            print("🚀 Session ID: \(sessionId ?? "nil")")
            print("🚀 Number of messages: \(messages.count)")
            print("🚀 Headers: \(urlRequest.allHTTPHeaderFields ?? [:])")
            if let bodyString = String(data: requestData, encoding: .utf8) {
                print("🚀 Request body:")
                if let jsonData = bodyString.data(using: .utf8),
                    let prettyJson = try? JSONSerialization.jsonObject(with: jsonData),
                    let prettyData = try? JSONSerialization.data(
                        withJSONObject: prettyJson, options: .prettyPrinted),
                    let prettyString = String(data: prettyData, encoding: .utf8)
                {
                    print(prettyString)
                } else {
                    print(bodyString)
                }
            }
        } catch {
            onError(error)
            return nil
        }

        // Create a custom URLSessionDataDelegate to handle streaming
        // Errors are handled by ChatView which switches to polling mode
        let delegate = SSEDelegate(
            onEvent: onEvent,
            onComplete: onComplete,
            onError: onError
        )

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)

        // Store the delegate reference to prevent deallocation
        objc_setAssociatedObject(task, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        task.resume()
        return task
    }

    // MARK: - Connection Test
    func testConnection() async -> Bool {
        let fullURL = "\(baseURL)/status"
        print("🔍 Testing connection to: '\(fullURL)'")
        print("   Base URL: '\(baseURL)'")
        print("   Secret key length: \(secretKey.count)")

        guard let url = URL(string: fullURL) else {
            print("❌ Failed to create URL from: '\(fullURL)'")
            await MainActor.run {
                self.connectionError = "Invalid URL: \(fullURL)"
                self.isConnected = false
            }
            return false
        }

        var request = URLRequest(url: url)
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let connected = httpResponse.statusCode == 200
                await MainActor.run {
                    self.isConnected = connected
                    if connected {
                        self.connectionError = nil
                    } else {
                        // Get error details for connection test
                        let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                        print(
                            "🚨 Connection Test Failed - HTTP \(httpResponse.statusCode): \(errorBody)"
                        )
                        self.connectionError = "HTTP \(httpResponse.statusCode): \(errorBody)"
                    }
                }
                return connected
            } else {
                await MainActor.run {
                    self.isConnected = false
                    self.connectionError = "Invalid response"
                }
                return false
            }
        } catch {
            await MainActor.run {
                self.isConnected = false
                self.connectionError = error.localizedDescription
            }
            return false
        }
    }

    // MARK: - Session Creation
    func startAgent(workingDir: String? = nil) async throws -> (
        sessionId: String, messages: [Message]
    ) {
        do {
            guard let url = URL(string: "\(self.baseURL)/agent/start") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(self.secretKey, forHTTPHeaderField: "X-Secret-Key")

            // For remote goosed: use "." (current directory where goosed is running)
            // This matches CLI behavior which uses std::env::current_dir()
            let effectiveWorkingDir = workingDir ?? "."
            print("🏠 Starting agent with working directory: \(effectiveWorkingDir)")
            
            let body: [String: Any] = ["working_dir": effectiveWorkingDir]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            if httpResponse.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                throw APIError.httpError(httpResponse.statusCode, errorBody)
            }

            let agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            return (agentResponse.id, agentResponse.conversation ?? [])
        }
    }

    // MARK: - Session Resume
    func resumeAgent(sessionId: String, loadModelAndExtensions: Bool = false) async throws -> (sessionId: String, messages: [Message]) {
        do {
            guard let url = URL(string: "\(self.baseURL)/agent/resume") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(self.secretKey, forHTTPHeaderField: "X-Secret-Key")

            let body: [String: Any] = [
                "session_id": sessionId,
                "load_model_and_extensions": loadModelAndExtensions
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Debug logging
            print("📤 Resuming session: '\(sessionId)' (load_model_and_extensions: \(loadModelAndExtensions))")
            print("📤 URL: \(url)")
            if let bodyString = String(data: request.httpBody!, encoding: .utf8) {
                print("📤 Request body: \(bodyString)")
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            // Log the response for debugging
            print("📥 Resume response status: \(httpResponse.statusCode)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("📥 Resume response body (first 500 chars): \(String(responseString.prefix(500)))")
            }

            if httpResponse.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                print("🚨 Resume failed with status \(httpResponse.statusCode): \(errorBody)")
                throw APIError.httpError(httpResponse.statusCode, errorBody)
            }

            let agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            let messages = agentResponse.conversation ?? []
            
            print("📊 ═══════════════════════════════════════════════════════")
            print("📊 RESUME SUMMARY for session: \(sessionId)")
            print("📊 ═══════════════════════════════════════════════════════")
            print("📊 Returned message count: \(messages.count)")
            if messages.isEmpty {
                print("📊 ⚠️⚠️⚠️ WARNING: ZERO messages returned! ⚠️⚠️⚠️")
            } else {
                print("📊 First message:")
                print("📊   - ID: \(messages.first!.id)")
                print("📊   - Role: \(messages.first!.role)")
                print("📊   - Content items: \(messages.first!.content.count)")
                print("📊 Last message:")
                print("📊   - ID: \(messages.last!.id)")
                print("📊   - Role: \(messages.last!.role)")
                print("📊   - Content items: \(messages.last!.content.count)")
                print("📊 All message IDs:")
                for (idx, msg) in messages.enumerated() {
                    let preview = msg.content.first.map { content -> String in
                        switch content {
                        case .text(let tc): return String(tc.text.prefix(50))
                        case .toolRequest(let tr): return "TOOL_REQ[\(tr.toolCall.name)]"
                        case .toolResponse(let tr): return "TOOL_RESP[\(tr.toolResult.status)]"
                        case .summarizationRequested: return "SUMMARIZATION"
                        case .toolConfirmationRequest: return "TOOL_CONFIRM"
                        case .conversationCompacted: return "COMPACTED"
                        }
                    } ?? "EMPTY"
                    print("📊   [\(idx)] \(msg.id.prefix(8))... \(msg.role) - \(preview)")
                }
            }
            print("📊 ═══════════════════════════════════════════════════════")
            
            return (agentResponse.id, messages)
        }
    }



    // MARK: - Agent Configuration
    func updateFromSession(sessionId: String) async throws {
        guard let url = URL(string: "\(self.baseURL)/agent/update_from_session") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.secretKey, forHTTPHeaderField: "X-Secret-Key")

        let body: [String: Any] = ["session_id": sessionId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
            throw APIError.httpError(httpResponse.statusCode, errorBody)
        }

        print("✅ Updated agent from session (applied server-side prompts)")
    }

    // MARK: - Config Management
    private static let configCacheTTL: TimeInterval = 3600  // 1 hour
    
    private func cacheNamespace() -> String {
        // Namespace cache by baseURL and secret key to avoid cross-environment bleed
        let ns = "\(baseURL)|\(secretKey)"
        return String(ns.hashValue)
    }
    
    func clearConfigCache() {
        // Clear all config cache entries for current namespace
        let ns = cacheNamespace()
        let prefix = "configCache:\(ns):"
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        print("💾 Cleared config cache for namespace \(ns)")
    }
    
    func readConfigValue(key: String, isSecret: Bool = false) async -> String? {
        let startTime = Date()
        print("⏱️ [PERF] readConfigValue(\(key)) started")
        
        // Check cache for non-secret config values
        let ns = cacheNamespace()
        let storeKey = "configCache:\(ns):\(key)"
        let expKey = storeKey + ":exp"
        let now = Date().timeIntervalSince1970
        if !isSecret {
            let expiresAt = UserDefaults.standard.double(forKey: expKey)
            if expiresAt > now, let cachedValue = UserDefaults.standard.string(forKey: storeKey) {
                let elapsed = Date().timeIntervalSince(startTime)
                print("⏱️ [PERF] readConfigValue(\(key)) from cache in \(String(format: "%.2f", elapsed))s")
                print("💾 Config '\(key)' = '\(cachedValue)' (from cache)")
                return cachedValue
            }
        }
        
        guard let url = URL(string: "\(baseURL)/config/read") else {
            print("⚠️ Invalid URL for config read")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")

        let body: [String: Any] = [
            "key": key,
            "is_secret": isSecret,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ [PERF] readConfigValue(\(key)) completed in \(String(format: "%.2f", elapsed))s")

            guard let httpResponse = response as? HTTPURLResponse else {
                print("⚠️ Invalid response reading config")
                return nil
            }

            if httpResponse.statusCode == 200 {
                // The response is just a string value, not a JSON object
                let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                // Remove quotes if present (JSON string encoding)
                let cleanValue = value?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                print("✅ Config '\(key)' = '\(cleanValue ?? "nil")'")
                
                // Cache non-secret values with fixed 1-hour TTL
                if !isSecret, let cleanValue = cleanValue {
                    let expiresAt = now + Self.configCacheTTL
                    UserDefaults.standard.set(cleanValue, forKey: storeKey)
                    UserDefaults.standard.set(expiresAt, forKey: expKey)
                    print("💾 Cached '\(key)' for namespace \(ns)")
                }
                
                return cleanValue
            } else {
                print("⚠️ Failed to read config '\(key)': HTTP \(httpResponse.statusCode)")
                return nil
            }
        } catch {
            print("⚠️ Error reading config '\(key)': \(error)")

            return nil
        }
    }

    // MARK: - Provider Management
    func updateProvider(sessionId: String, provider: String, model: String?) async throws {
        do {
            guard let url = URL(string: "\(self.baseURL)/agent/update_provider") else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(self.secretKey, forHTTPHeaderField: "X-Secret-Key")

            var body: [String: Any] = [
                "session_id": sessionId,
                "provider": provider,
            ]

            // Add model if provided
            if let model = model {
                body["model"] = model
            }

            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Debug logging
            if let bodyData = request.httpBody,
                let bodyString = String(data: bodyData, encoding: .utf8)
            {
                print("📤 Updating provider to \(provider), model: \(model ?? "default")")
                print(bodyString)
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            if httpResponse.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                throw APIError.httpError(httpResponse.statusCode, errorBody)
            }

            print("✅ Provider updated to \(provider) with model \(model ?? "default")")
            
            // Clear config cache when agent changes
            clearConfigCache()
        }
    }

    // MARK: - Extension Management
    func loadEnabledExtensions(sessionId: String) async throws {
        do {
            // Get extensions from config, just like desktop does
            guard let url = URL(string: "\(self.baseURL)/config/extensions") else {
                print("⚠️ Invalid URL for getting extensions config")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(self.secretKey, forHTTPHeaderField: "X-Secret-Key")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("⚠️ Invalid response getting extensions config")
                return
            }

            if httpResponse.statusCode != 200 {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                print("⚠️ Failed to get extensions config: \(errorBody)")
                return
            }

            // Parse the extensions config
            guard
                let extensionsConfig = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                let extensions = extensionsConfig["extensions"] as? [[String: Any]]
            else {
                print("⚠️ Failed to parse extensions config")
                return
            }

            // Load enabled extensions in parallel
            await withTaskGroup(of: Void.self) { group in
                for extensionConfig in extensions {
                    if let enabled = extensionConfig["enabled"] as? Bool, enabled {
                        group.addTask {
                            await self.loadExtension(sessionId: sessionId, extensionConfig: extensionConfig)
                        }
                    }
                }
            }
        }
    }

    private func loadExtension(sessionId: String, extensionConfig: [String: Any]) async {
        guard let url = URL(string: "\(baseURL)/extensions/add") else {
            print("⚠️ Invalid URL for extension loading")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")

        var body = extensionConfig
        body["session_id"] = sessionId

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("⚠️ Invalid response loading extension")
                return
            }

            if httpResponse.statusCode == 200 {
                if let name = extensionConfig["name"] as? String {
                    print("✅ Extension '\(name)' loaded")
                }
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                if let name = extensionConfig["name"] as? String {
                    print("⚠️ Failed to load extension '\(name)': \(errorBody)")
                }
            }
        } catch {
            print("⚠️ Error loading extension: \(error)")
        }
    }

    // MARK: - Sessions Management
    func fetchInsights() async -> SessionInsights? {
        let startTime = Date()
        print("⏱️ [PERF] fetchInsights() started")
        
        // In trial mode, return mock insights
        if isTrialMode {
            return SessionInsights(totalSessions: 5, totalTokens: 450_000_000)
        }

        guard let url = URL(string: "\(baseURL)/sessions/insights") else {
            print("🚨 Invalid insights URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ [PERF] fetchInsights() completed in \(String(format: "%.2f", elapsed))s")

            guard let httpResponse = response as? HTTPURLResponse else {
                print("🚨 Invalid response when fetching insights")
                return nil
            }

            if httpResponse.statusCode == 200 {
                let insights = try JSONDecoder().decode(SessionInsights.self, from: data)
                print("✅ Fetched insights: \(insights.totalSessions) sessions, \(insights.totalTokens) tokens")
                return insights
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                print("🚨 Failed to fetch insights: \(httpResponse.statusCode) - \(errorBody)")
                return nil
            }
        } catch {
            print("🚨 Error fetching insights: \(error)")
            return nil
        }
    }
    
    func fetchSessions() async -> [ChatSession] {
        let startTime = Date()
        print("⏱️ [PERF] fetchSessions() started")
        
        // In trial mode, return mock sessions
        if isTrialMode {
            return TrialMode.shared.getMockSessions()
        }

        guard let url = URL(string: "\(baseURL)/sessions") else {
            print("🚨 Invalid sessions URL")
            return []
        }

        var request = URLRequest(url: url)
        request.setValue(secretKey, forHTTPHeaderField: "X-Secret-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            print("⏱️ [PERF] fetchSessions() completed in \(String(format: "%.2f", elapsed))s")

            guard let httpResponse = response as? HTTPURLResponse else {
                print("🚨 Invalid response when fetching sessions")
                return []
            }

            if httpResponse.statusCode == 200 {
                let sessionsResponse = try JSONDecoder().decode(SessionsResponse.self, from: data)
                print("✅ Fetched \(sessionsResponse.sessions.count) sessions")
                return sessionsResponse.sessions
            } else {
                let errorBody = String(data: data, encoding: .utf8) ?? "No error details"
                print("🚨 Sessions fetch failed - HTTP \(httpResponse.statusCode): \(errorBody)")
                return []
            }
        } catch {
            print("🚨 Error fetching sessions: \(error)")

            return []
        }
    }
}

// MARK: - Response Models
struct AgentResponse: Codable {
    let id: String
    let conversation: [Message]?  // conversation is directly an array of messages
}

struct SessionsResponse: Codable {
    let sessions: [ChatSession]
}

struct SessionInsights: Codable {
    let totalSessions: Int
    let totalTokens: Int64
}

// MARK: - SSE Delegate
class SSEDelegate: NSObject, URLSessionDataDelegate {
    private let onEvent: (SSEEvent) -> Void
    private let onComplete: () -> Void
    private let onError: (Error) -> Void
    private var buffer = ""
    private let maxBufferSize = 10000  // Prevent buffer overflow
    private var errorStatusCode: Int? = nil  // Track error status codes

    init(
        onEvent: @escaping (SSEEvent) -> Void, onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onEvent = onEvent
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            DispatchQueue.main.async {
                self.onError(APIError.invalidResponse)
            }
            completionHandler(.cancel)
            return
        }

        print("🚀 SSE Response Status: \(httpResponse.statusCode)")
        print("🚀 SSE Response Headers: \(httpResponse.allHeaderFields)")

        guard httpResponse.statusCode == 200 else {
            // Store error status for later
            errorStatusCode = httpResponse.statusCode
            // Let it continue so we can capture the error body
            completionHandler(.allow)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let string = String(data: data, encoding: .utf8) else {
            print("🚨 SSE: Failed to decode data as UTF-8")
            return
        }

        // Add to buffer
        buffer += string

        // Process complete lines
        let lines = buffer.components(separatedBy: .newlines)

        // Keep the last incomplete line in buffer
        if !buffer.hasSuffix("\n") && !buffer.hasSuffix("\r\n") {
            buffer = lines.last ?? ""
            let completeLines = Array(lines.dropLast())
            processSSELines(completeLines)
        } else {
            buffer = ""
            processSSELines(lines)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error = error {
            DispatchQueue.main.async {
                self.onError(error)
            }
        } else if let statusCode = errorStatusCode {
            // We had an HTTP error - report it with the collected buffer as the error body
            print("🚨 HTTP Error \(statusCode) with body: \(buffer)")
            DispatchQueue.main.async {
                self.onError(APIError.httpError(statusCode, self.buffer))
            }
        } else {
            DispatchQueue.main.async {
                self.onComplete()
            }
        }
    }

    private func processSSELines(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix("data: ") {
                let eventData = String(line.dropFirst(6))
                if !eventData.isEmpty {
                    do {
                        let jsonData = eventData.data(using: .utf8)!
                        let event = try JSONDecoder().decode(SSEEvent.self, from: jsonData)

                        // Minimal logging - only log important events
                        if case .finish = event {
                            print("✅ SSE Stream completed")
                        } else if case .error = event {
                            print("🚨 SSE Error event received")
                        }

                        DispatchQueue.main.async {
                            self.onEvent(event)
                        }

                        // Check if this is a finish event
                        if case .finish = event {
                            DispatchQueue.main.async {
                                self.onComplete()
                            }
                            return
                        }
                    } catch {
                        print("🚨 Failed to decode SSE event: \(error)")
                        DispatchQueue.main.async {
                            self.onError(error)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - API Errors
enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case noData
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response"
        case .httpError(let code, let body):
            return "HTTP Error \(code): \(body)"
        case .noData:
            return "No data received"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }
}
