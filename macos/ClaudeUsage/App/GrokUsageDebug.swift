import Foundation
import ClaudeUsageCore

/// `--debug-grok`: probes the Grok endpoints with whatever session cookie is already in
/// Keychain and prints what came back, then exits. Never prints the cookie itself. For
/// diagnosing "Connect Grok succeeded but usage still won't load" without having to extract
/// the Keychain secret by hand.
///
/// It prints the gRPC status separately from the HTTP status on purpose: the billing call is
/// gRPC-Web, so a rejected session still arrives as `HTTP 200` and only `grpc-status: 16`
/// says what actually happened.
enum GrokUsageDebug {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--debug-grok") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let cookie = GrokSessionCookieStore().load() else {
                print("No Grok session cookie stored - run Connect Grok first.")
                return
            }
            print("Cookie found (\(cookie.count) chars, \(cookie.split(separator: ";").count) pairs).")

            await probeCredits(cookie: cookie)
            await probeJSON(GrokUsageService.subscriptionsURL, cookie: cookie)
            await probeJSON(URL(string: "https://grok.com/rest/auth/get-user")!, cookie: cookie)
        }
        semaphore.wait()
        return true
    }

    private static func probeCredits(cookie: String) async {
        print("\n--- \(GrokUsageService.creditsURL.absoluteString) (gRPC-Web) ---")
        var request = base(GrokUsageService.creditsURL, cookie: cookie)
        request.httpMethod = "POST"
        request.httpBody = GrokGRPCWebFrames.frame(Data())
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")

        do {
            let response = try await URLSessionGrokTransport().send(request)
            print("HTTP \(response.statusCode)")
            let frames = GrokGRPCWebFrames.parse(response.data)
            let headers = Dictionary(
                response.headers.map { ($0.key.lowercased(), $0.value) },
                uniquingKeysWith: { a, _ in a }
            )
            let status = frames.trailers["grpc-status"] ?? headers["grpc-status"] ?? "(none)"
            let message = frames.trailers["grpc-message"] ?? headers["grpc-message"] ?? ""
            print("grpc-status: \(status)  \(message.removingPercentEncoding ?? message)")
            print("message frame: \(frames.message.count) bytes")
            if let json = GrokCreditsMessage.decode(frames.message) {
                print("decoded: \(DebugSanitizer.encoded(json))")
            } else if !frames.message.isEmpty {
                print("decode failed - first bytes: \(Array(frames.message.prefix(32)))")
            }
        } catch {
            print("Transport error: \(error)")
        }
    }

    private static func probeJSON(_ url: URL, cookie: String) async {
        print("\n--- \(url.absoluteString) ---")
        var request = base(url, cookie: cookie)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let response = try await URLSessionGrokTransport().send(request)
            print("HTTP \(response.statusCode)")
            let preview = String(data: response.data.prefix(600), encoding: .utf8) ?? "<binary>"
            print("Body preview:\n\(preview)")
        } catch {
            print("Transport error: \(error)")
        }
    }

    private static func base(_ url: URL, cookie: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "ClaudeUsageTracker/2.1 (macOS; Grok settings)", forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        return request
    }
}
