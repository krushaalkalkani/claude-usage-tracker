import SwiftUI
import WebKit
import ClaudeUsageCore

/// Owns the one-time Cursor login flow: an embedded `WKWebView` pointed at
/// `cursor.com/dashboard`, and extraction of the resulting session cookie into
/// `CursorSessionCookieStore` (via `AppModel.saveCursorSession`).
///
/// This lives in the app target, not `ClaudeUsageCore/Services`, because `ClaudeUsageCore` is
/// deliberately UI-free — it is the "pure, UI-free logic" library the whole test suite runs
/// against — and `WKWebView` is a UI framework. `CursorUsageService`, the parsing/networking
/// service, never imports WebKit or AppKit; it only ever reads whatever cookie this sheet
/// already stored.
///
/// This app never reads any other browser's cookie jar. The only legitimate source of the
/// Cursor session cookie is the sign-in the user completes in this embedded view.
struct CursorLoginSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var status = "Sign in to Cursor below, then tap Continue."
    @State private var isChecking = false
    // Owned here (not by the representable) so `extractAndSave` can read its cookie store
    // directly without coordinator plumbing.
    @State private var webView = WKWebView()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Cursor")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
            }
            .padding(12)

            CursorWebView(webView: webView) {
                extractAndSave()
            }
            .frame(width: 520, height: 560)

            HStack(alignment: .firstTextBaseline) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Continue") { extractAndSave() }
                    .disabled(isChecking)
            }
            .padding(12)
        }
        .frame(width: 520)
    }

    /// Reads whatever `cursor.com` cookies the embedded view's website data store currently
    /// holds and, if any exist, saves them and closes the sheet. Called both automatically
    /// (once navigation lands back on the dashboard rather than a login page) and manually via
    /// the Continue button, since a single-page-app redirect after login does not reliably
    /// fire a fresh `didFinish` navigation.
    private func extractAndSave() {
        guard !isChecking else { return }
        isChecking = true
        status = "Checking session…"

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter { $0.domain.contains("cursor.com") }
            Task { @MainActor in
                guard !relevant.isEmpty else {
                    status = "No Cursor session found yet. Finish signing in, then tap Continue."
                    isChecking = false
                    return
                }
                let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let saved = model.saveCursorSession(header)
                isChecking = false
                if saved {
                    status = "Connected."
                    dismiss()
                } else {
                    status = "Could not save to Keychain."
                }
            }
        }
    }
}

/// Thin `NSViewRepresentable` wrapper around a caller-owned `WKWebView`.
private struct CursorWebView: NSViewRepresentable {
    let webView: WKWebView
    let onAuthenticatedNavigation: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://cursor.com/dashboard")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticatedNavigation: onAuthenticatedNavigation)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onAuthenticatedNavigation: () -> Void

        init(onAuthenticatedNavigation: @escaping () -> Void) {
            self.onAuthenticatedNavigation = onAuthenticatedNavigation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, let host = url.host, host.contains("cursor.com") else {
                return
            }
            let path = url.path.lowercased()
            guard !path.contains("login"), !path.contains("sign-in"), !path.contains("signin")
            else { return }
            onAuthenticatedNavigation()
        }
    }
}
