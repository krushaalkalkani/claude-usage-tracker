import SwiftUI
import AppKit
import WebKit
import ClaudeUsageCore

/// Owns the one-time Grok login flow: an embedded `WKWebView` pointed at grok.com, and
/// extraction of the resulting session cookie into `GrokSessionCookieStore` (via
/// `AppModel.saveGrokSession`).
///
/// The reasoning is identical to `CursorLoginSheet`, and deliberately not shared with it: see
/// that type's doc comment for why this lives in the app target rather than in the UI-free
/// `ClaudeUsageCore`, and why it is presented as a plain, manually-owned `NSWindow` instead of
/// a SwiftUI `.sheet` or `Window` scene.
///
/// This app never reads any other browser's cookie jar. The only legitimate source of the
/// Grok session cookie is the sign-in the user completes in this embedded view.
struct GrokLoginSheet: View {
    @Bindable var model: AppModel
    var onDismiss: () -> Void = {}

    @State private var status = "Sign in to Grok below, then tap Continue."
    @State private var isChecking = false
    @State private var webView = WKWebView()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Grok")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.plain)
            }
            .padding(12)

            GrokWebView(webView: webView) {
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

    /// Reads whatever `grok.com` cookies the embedded view's website data store currently
    /// holds and, if any exist, saves them and closes the sheet. Called both automatically
    /// (once navigation lands somewhere that is not a sign-in page) and manually via the
    /// Continue button, since a single-page-app redirect after login does not reliably fire a
    /// fresh `didFinish` navigation.
    private func extractAndSave() {
        guard !isChecking else { return }
        isChecking = true
        status = "Checking session…"

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let relevant = cookies.filter { $0.domain.contains("grok.com") }
            Task { @MainActor in
                guard !relevant.isEmpty else {
                    status = "No Grok session found yet. Finish signing in, then tap Continue."
                    isChecking = false
                    return
                }
                let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                let saved = model.saveGrokSession(header)
                isChecking = false
                if saved {
                    status = "Connected."
                    onDismiss()
                } else {
                    status = "Could not save to Keychain."
                }
            }
        }
    }
}

/// Thin `NSViewRepresentable` wrapper around a caller-owned `WKWebView`.
private struct GrokWebView: NSViewRepresentable {
    let webView: WKWebView
    let onAuthenticatedNavigation: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://grok.com/")!))
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
            guard let url = webView.url, let host = url.host, host.contains("grok.com") else {
                // Grok signs in through X and Google, so the flow legitimately leaves the
                // origin mid-way. Only a landing back on grok.com is worth checking.
                return
            }
            let path = url.path.lowercased()
            guard !path.contains("login"), !path.contains("sign-in"), !path.contains("signin"),
                  !path.contains("auth")
            else { return }
            onAuthenticatedNavigation()
        }
    }
}

/// Shows `GrokLoginSheet` in a plain `NSWindow` this app creates and owns directly, outside
/// SwiftUI's scene graph — see `CursorLoginSheet` for why neither `.sheet` nor a `Window`
/// scene works here. One window at a time: a second call while one is already open just
/// brings it forward.
@MainActor
final class GrokLoginPresenter {
    static let shared = GrokLoginPresenter()

    private var window: NSWindow?
    private var delegate: WindowCloseDelegate?

    private init() {}

    func show(model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: GrokLoginSheet(model: model, onDismiss: { [weak self] in self?.close() })
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Connect Grok"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        let delegate = WindowCloseDelegate { [weak self] in self?.window = nil }
        window.delegate = delegate
        self.delegate = delegate
        self.window = window

        window.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }

    private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}
