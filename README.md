# Claude Usage Tracker

A minimal, real-time dashboard to monitor your Claude rate limits. Tracks 5-hour session and 7-day weekly usage with live gauges, burn rate estimation, and historical charts.

**Live App:** [claude-usage-tracker-xi.vercel.app](https://claude-usage-tracker-xi.vercel.app)

---

## What It Does

- **Circular Gauges** — See your current session (5hr) and weekly (7d) usage at a glance
- **Burn Rate** — Live velocity metric showing how fast you're consuming your quota
- **Historical Charts** — Tracks usage over time with area charts
- **Auto-Refresh** — Polls every 120 seconds with a countdown timer
- **macOS Menu Bar** — Optional SwiftBar plugin shows usage in your menu bar
- **100% Client-Side** — Your token stays in your browser. No backend, no third-party servers

## Quick Start

### Option 1: Use the Deployed App

1. Open [claude-usage-tracker-xi.vercel.app](https://claude-usage-tracker-xi.vercel.app)
2. Paste your OAuth token (see [Getting Your Token](#getting-your-token))
3. Done

### Option 2: Run Locally

```bash
git clone https://github.com/krushaalkalkani/claude-usage-tracker.git
cd claude-usage-tracker
npm install
npm run dev
```

Open `http://localhost:5173`

### Option 3: Deploy Your Own

```bash
npm i -g vercel
vercel --prod
```

---

## Getting Your Token

This app uses Anthropic's OAuth usage endpoint. You need an **OAuth token**, not a standard API key.

### From Claude Code CLI (Recommended)

1. Install Claude Code if you haven't: `npm i -g @anthropic-ai/claude-code`
2. Run `claude` and complete the OAuth login
3. Extract the token:

**Mac:**
```bash
security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
```

If that doesn't work, try:
```bash
claude setup-token
```
This gives a long-lived token (1 year), but it may not have the required scope for the usage API. In that case, use the browser method below.

### From Browser

1. Go to [claude.ai](https://claude.ai) and log in
2. Open DevTools (F12) > Application > Cookies
3. Copy the `sessionKey` value — this won't work directly with the usage API

**Note:** The most reliable token is the OAuth token from Claude Code's login session. If your token stops working, re-authenticate with `claude auth logout && claude auth login` and extract again.

---

## macOS Menu Bar Plugin (SwiftBar)

The repo includes a SwiftBar plugin that shows your usage percentage in the macOS menu bar.

### Setup

1. Install SwiftBar: `brew install --cask swiftbar`
2. Open SwiftBar and set the plugin directory to any folder
3. Symlink the plugin:

```bash
ln -s /path/to/claude-usage-tracker/swiftbar/claude-usage.2m.sh ~/path/to/SwiftBarPlugins/
```

4. Save your token:

```bash
echo "YOUR_OAUTH_TOKEN" > ~/.claude-usage-token
chmod 600 ~/.claude-usage-token
```

5. Add SwiftBar to **System Settings > General > Login Items** so it starts on boot

The plugin refreshes every 2 minutes and shows a compact icon with your current session percentage.

---

## Token Troubleshooting

| Problem | Fix |
|---------|-----|
| "Invalid bearer token" | Token expired. Get a fresh one from Claude Code |
| "Rate limited" | Wait 5-10 minutes. The app handles 429s silently |
| "OAuth token does not meet scope" | The `setup-token` token lacks the usage scope. Use the OAuth token from `claude auth login` instead |
| Plugin not showing | Check SwiftBar is running and `~/.claude-usage-token` has a valid token |
| App blank after restart | Your token is saved in browser localStorage. Just refresh |

---

## Tech Stack

- **React 19** + **Vite** — Fast dev server with API proxy
- **Recharts** — SVG data visualization
- **Vercel** — Production hosting with API rewrites
- **SwiftBar** — macOS menu bar integration
- **PIL/Pillow** — Menu bar icon generation

## Project Structure

```
claude-usage-tracker/
├── src/
│   ├── App.jsx              # Main dashboard
│   ├── components/
│   │   ├── Gauge.jsx        # Circular progress gauge
│   │   ├── DetailRow.jsx    # Rate limit detail rows
│   │   └── StatusDot.jsx    # Connection indicator
│   └── utils/
│       ├── styles.js        # Shared styles
│       └── time.js          # Time formatting
├── swiftbar/
│   └── claude-usage.2m.sh   # macOS menu bar plugin
├── vercel.json              # API proxy rewrites for production
└── vite.config.js           # Dev server proxy config
```

## Privacy

- Tokens are stored in your browser's localStorage (web app) and `~/.claude-usage-token` (plugin)
- API calls go directly from your browser/machine to `api.anthropic.com`
- No analytics, no tracking, no backend

## License

MIT

---

*Built by [Krushal Kalkani](https://github.com/krushaalkalkani). This tool uses an internal Anthropic API that may change without notice.*
