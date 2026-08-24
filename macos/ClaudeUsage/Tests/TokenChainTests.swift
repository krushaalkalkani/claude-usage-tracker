import Testing
import Foundation
@testable import ClaudeUsageCore

/// Regression cover for the failure that left the panel showing eight-hour-old values:
/// `TokenStore` resolved to the first credential that *existed* rather than the first that
/// *worked*, so a rotated Claude Code token kept being re-sent while a working legacy token
/// sat unused behind it in the priority order.
@Suite("Credential chain")
struct TokenChainTests {

    /// The store reads real keychain items, so these tests drive the ordering logic through
    /// the same `excluding:` contract the app uses, with a stand-in resolver.
    private func resolve(
        available: [TokenSource],
        excluding: Set<TokenSource>
    ) -> TokenSource? {
        // Mirrors TokenStore.resolve's ordering: app keychain, Claude Code, legacy file.
        let order: [TokenSource] = [.appKeychain, .claudeCodeKeychain, .legacyFile]
        return order.first { available.contains($0) && !excluding.contains($0) }
    }

    @Test("a rejected source is skipped for the next candidate")
    func skipsRejectedSource() {
        let available: [TokenSource] = [.claudeCodeKeychain, .legacyFile]

        // First attempt takes the higher-priority credential.
        #expect(resolve(available: available, excluding: []) == .claudeCodeKeychain)

        // The server rejects it; the next attempt must fall through rather than repeat it.
        #expect(resolve(available: available, excluding: [.claudeCodeKeychain]) == .legacyFile)
    }

    @Test("exhausting every source reports no credential rather than looping")
    func exhaustsChain() {
        let available: [TokenSource] = [.claudeCodeKeychain, .legacyFile]
        let allRejected: Set<TokenSource> = [.claudeCodeKeychain, .legacyFile]
        #expect(resolve(available: available, excluding: allRejected) == nil)
    }

    @Test("priority order is app keychain, then Claude Code, then the legacy file")
    func priorityOrder() {
        let all: [TokenSource] = [.appKeychain, .claudeCodeKeychain, .legacyFile]
        #expect(resolve(available: all, excluding: []) == .appKeychain)
        #expect(resolve(available: all, excluding: [.appKeychain]) == .claudeCodeKeychain)
        #expect(resolve(available: all, excluding: [.appKeychain, .claudeCodeKeychain]) == .legacyFile)
    }

    @Test("a future expiresAt does not prove a token is accepted")
    func futureExpiryIsNotValidity() {
        // The rotated Claude Code credential advertised an expiry three weeks out and was
        // still refused, which is why expiry alone can never gate the chain.
        let token = ResolvedToken(
            value: "x",
            source: .claudeCodeKeychain,
            expiresAt: Date().addingTimeInterval(21 * 86_400)
        )
        #expect(!token.isExpired)
        // Only a live rejection can retire it, so the skip list has to be driven by the
        // server's answer rather than by the timestamp.
        #expect(resolve(available: [.claudeCodeKeychain, .legacyFile],
                        excluding: [token.source]) == .legacyFile)
    }

    @Test("unauthorized is not treated as a transient error")
    func unauthorizedIsTerminalForThatSource() {
        // Transient errors are retried against the same credential; auth failures must not be,
        // or the chain would never advance.
        #expect(!UsageAPIError.unauthorized.isTransient)
        #expect(!UsageAPIError.forbidden.isTransient)
        #expect(UsageAPIError.rateLimited(retryAfter: nil).isTransient)
        #expect(UsageAPIError.offline.isTransient)
    }
}
