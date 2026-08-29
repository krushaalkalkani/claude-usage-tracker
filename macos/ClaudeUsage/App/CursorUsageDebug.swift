import Foundation
import ClaudeUsageCore

/// `--debug-cursor`: probes `get-plan-info` with whatever session cookie is already in
/// Keychain and prints the raw status code and a body preview, then exits. Never prints the
/// cookie itself. For diagnosing "Connect Cursor succeeded but usage still won't load" without
/// having to extract the Keychain secret by hand.
enum CursorUsageDebug {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--debug-cursor") else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            guard let cookie = CursorSessionCookieStore().load() else {
                print("No Cursor session cookie stored - run Connect Cursor first.")
                return
            }
            print("Cookie found (\(cookie.count) chars, \(cookie.split(separator: ";").count) pairs).")

            let urls = [
                CursorUsageService.planInfoURL,
                CursorUsageService.currentPeriodUsageURL,
                CursorUsageService.sandUsageStatusURL,
                URL(string: "https://cursor.com/api/dashboard/get-credit-grants-balance")!,
            ]
            for url in urls {
                print("\n--- \(url.absoluteString) ---")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = Data("{}".utf8)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue(
                    "ClaudeUsageTracker/2.1 (macOS; Cursor dashboard)", forHTTPHeaderField: "User-Agent"
                )
                request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
                request.setValue("https://cursor.com/dashboard/spending", forHTTPHeaderField: "Referer")

                do {
                    let response = try await URLSessionCursorTransport().send(request)
                    print("HTTP \(response.statusCode)")
                    let preview = String(data: response.data.prefix(600), encoding: .utf8) ?? "<binary>"
                    print("Body preview:\n\(preview)")
                } catch {
                    print("Transport error: \(error)")
                }
            }
        }
        semaphore.wait()
        return true
    }
}
