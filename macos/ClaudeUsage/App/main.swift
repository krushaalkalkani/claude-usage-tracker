import AppKit

// Explicit entry point rather than `@main` on the App struct, so `--render-preview <dir>`
// can produce screenshots and exit before any scene, status item, or network call exists.
if PreviewRenderer.runIfRequested() {
    exit(0)
}

ClaudeUsageApp.main()
