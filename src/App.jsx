import { useState, useEffect, useCallback, useRef } from "react";
import { XAxis, YAxis, Tooltip, ResponsiveContainer, AreaChart, Area } from "recharts";
import { timeUntil, resetLabel } from "./utils/time";
import { S } from "./utils/styles";
import { Gauge } from "./components/Gauge";
import { StatusDot } from "./components/StatusDot";
import { DetailRow } from "./components/DetailRow";
import "./App.css";

const STORAGE_KEY = "claude-auto-tracker";
const POLL_INTERVAL = 60000; // 60 seconds

export default function App() {
  const [token, setToken] = useState("");
  const [savedToken, setSavedToken] = useState("");
  const [usage, setUsage] = useState(null);
  const [history, setHistory] = useState([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [fetching, setFetching] = useState(false);
  const [lastFetch, setLastFetch] = useState(null);
  const [view, setView] = useState("live");
  const [showSetup, setShowSetup] = useState(false);
  const [timeToNext, setTimeToNext] = useState(120);
  const [copied, setCopied] = useState(false);

  // Load saved data
  useEffect(() => {
    try {
      const r = localStorage.getItem(STORAGE_KEY);
      if (r) {
        const data = JSON.parse(r);
        if (data.token) setSavedToken(data.token);
        if (data.history) setHistory(data.history);
        if (data.usage) setUsage(data.usage);
        if (data.lastFetch) setLastFetch(new Date(data.lastFetch));
      }
      // Auto-detect OAuth token injected from Claude Code session via Vite env
      const envToken = import.meta.env.VITE_OAUTH_TOKEN;
      if (envToken) {
        const stored = localStorage.getItem(STORAGE_KEY);
        const storedToken = stored ? JSON.parse(stored).token : null;
        if (!storedToken || storedToken !== envToken) {
          setSavedToken(envToken);
          persist({ token: envToken });
        }
      }
    } catch {}
    setLoading(false);
  }, []);

  const persist = useCallback((updates) => {
    try {
      const r = localStorage.getItem(STORAGE_KEY);
      const existing = r ? JSON.parse(r) : {};
      const merged = { ...existing, ...updates };
      localStorage.setItem(STORAGE_KEY, JSON.stringify(merged));
    } catch {}
  }, []);

  const fetchUsage = useCallback(async (tok) => {
    const t = tok || savedToken;
    if (!t) return;
    setFetching(true);
    setError("");
    try {
      const resp = await fetch("/api/oauth/usage", {
        headers: {
          "Authorization": `Bearer ${t}`,
          "anthropic-beta": "oauth-2025-04-20",
          "Content-Type": "application/json",
        },
      });
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({}));
        throw new Error(err?.error?.message || `HTTP ${resp.status}`);
      }
      const data = await resp.json();
      setUsage(data);
      setLastFetch(new Date());

      // Add to history (keep last 200 entries, one per poll)
      const entry = {
        ts: new Date().toISOString(),
        s: data.five_hour?.utilization ?? null,
        w: data.seven_day?.utilization ?? null,
      };
      setHistory(prev => {
        const newHist = [entry, ...prev].slice(0, 200);
        persist({ usage: data, history: newHist, lastFetch: new Date().toISOString() });
        return newHist;
      });
    } catch (e) {
      setError(e.message || "Failed to fetch");
    }
    setFetching(false);
  }, [savedToken, persist]);

  // Auto-poll with countdown
  useEffect(() => {
    if (!savedToken) return;
    
    fetchUsage(savedToken);
    setTimeToNext(120);
    
    const interval = setInterval(() => {
      setTimeToNext(prev => {
        if (prev <= 1) {
          fetchUsage(savedToken);
          return 120;
        }
        return prev - 1;
      });
    }, 1000);
    
    return () => clearInterval(interval);
  }, [savedToken]); // eslint-disable-line

  const saveToken = () => {
    const t = token.trim();
    if (!t) return;
    setSavedToken(t);
    setToken("");
    setShowSetup(false);
    persist({ token: t });
    fetchUsage(t);
  };

  const disconnect = () => {
    setSavedToken("");
    setUsage(null);
    setHistory([]);
    setError("");
    persist({ token: "", usage: null, history: [], lastFetch: null });
  };

  const fiveHour = usage?.five_hour;
  const sevenDay = usage?.seven_day;
  const sonnet = usage?.seven_day_sonnet;
  const opus = usage?.seven_day_opus;
  const extra = usage?.extra_usage;

  // Chart data (last 30)
  const chartData = history.slice(0, 30).reverse().map(h => ({
    t: new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false }),
    session: h.s != null ? Math.round(h.s) : null,
    weekly: h.w != null ? Math.round(h.w) : null,
  }));

  // Unique Feature: Burn Rate Estimator
  const recentHist = history.slice(0, 6); // roughly last 5 minutes of polling
  let burnRate = 0;
  if (recentHist.length >= 2 && recentHist[0].s != null) {
    const oldest = recentHist[recentHist.length - 1];
    const newest = recentHist[0];
    if (oldest.s != null) {
      const diff = newest.s - oldest.s;
      const tDiffMin = (new Date(newest.ts) - new Date(oldest.ts)) / 60000;
      if (tDiffMin > 0 && diff > 0) burnRate = diff / tDiffMin;
    }
  }

  if (loading) return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100vh", background: "#000", color: "#888", fontFamily: "'JetBrains Mono', monospace", fontSize: 13 }}>Loading workspace...</div>
  );

  // Unified Setup Screen
  if (!savedToken) {
    return (
      <div style={{ ...S.wrap, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", padding: "40px 20px", minHeight: "100vh" }}>
        <div className="animate-fade-in" style={{ width: "100%", maxWidth: 380 }}>
          
          <div style={{ textAlign: "center", marginBottom: 32 }}>
            <div style={{ width: 48, height: 48, background: "#fff", color: "#000", fontSize: 28, fontWeight: 800, display: "flex", alignItems: "center", justifyContent: "center", borderRadius: 12, margin: "0 auto 16px", fontFamily: "-apple-system, sans-serif" }}>C</div>
            <h1 style={{ fontSize: 20, fontWeight: 600, color: "#ededed", margin: 0, letterSpacing: "-0.01em" }}>Usage Tracker</h1>
            <p style={{ fontSize: 13, color: "#888", marginTop: 6, lineHeight: 1.5 }}>
              Connect your Anthropic session to cleanly monitor 5-hour boundary rate limits.
            </p>
          </div>

          <div style={{ background: "#0a0a0a", border: "1px solid #222", borderRadius: 12, padding: 20, boxShadow: "0 8px 32px rgba(0,0,0,0.5)" }}>
            <label style={{ display: "block", fontSize: 11, fontWeight: 600, color: "#a1a1aa", marginBottom: 8, textTransform: "uppercase", letterSpacing: "0.05em" }}>Session Token</label>
            <textarea
              value={token}
              onChange={(e) => setToken(e.target.value)}
              placeholder="Paste token (sk-ant-...) "
              style={{ width: "100%", background: "#050505", border: "1px solid #27272a", borderRadius: 8, padding: "12px 14px", color: "#ededed", fontSize: 13, fontFamily: "'JetBrains Mono', monospace", outline: "none", resize: "none", transition: "border 0.2s", boxSizing: "border-box", marginBottom: 16 }}
              onFocus={e => e.target.style.borderColor = "#52525b"}
              onBlur={e => e.target.style.borderColor = "#27272a"}
              rows={3}
            />
            
            <button 
              onClick={saveToken} 
              style={{ width: "100%", background: token.trim() ? "#ededed" : "#27272a", color: token.trim() ? "#000" : "#52525b", border: "none", borderRadius: 8, padding: "10px 0", fontSize: 13, fontWeight: 600, cursor: token.trim() ? "pointer" : "not-allowed", transition: "all 0.2s" }}
            >
              Connect securely
            </button>
          </div>

          <div style={{ marginTop: 24, background: "transparent", border: "1px solid #1a1a1a", borderRadius: 12, overflow: "hidden" }}>
            <div style={{ padding: "12px 16px", background: "#111", borderBottom: "1px solid #1a1a1a", fontSize: 12, fontWeight: 600, color: "#a1a1aa" }}>
              How to securely get your token
            </div>
            <div style={{ padding: "16px", fontSize: 12, color: "#888", lineHeight: 1.6 }}>
              <p style={{ margin: "0 0 14px 0" }}>
                <strong style={{ color: "#ededed" }}>Browser:</strong> Login to <a href="https://claude.ai" target="_blank" style={{color:"#38bdf8", textDecoration:"none"}}>claude.ai</a> → Open DevTools (F12) → Application → Cookies → Copy <code>sessionKey</code>.
              </p>
              
              <p style={{ margin: "0 0 8px 0" }}>
                <strong style={{ color: "#ededed" }}>Claude Code (Mac):</strong> Run to extract:
              </p>
              <div 
                style={{ position: "relative", background: "#050505", border: "1px solid #222", borderRadius: 8, padding: "12px", paddingRight: 36, cursor: "pointer", transition: "border 0.2s, background 0.2s" }}
                onClick={() => {
                  navigator.clipboard.writeText(`security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"`);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 2000);
                }}
                onMouseOver={e => { e.currentTarget.style.borderColor = "#444"; e.currentTarget.style.background = "#0a0a0a"; }}
                onMouseOut={e => { e.currentTarget.style.borderColor = "#222"; e.currentTarget.style.background = "#050505"; }}
                title="Click to copy"
              >
                <div style={{ fontSize: 11, color: "#a1a1aa", fontFamily: "'JetBrains Mono', monospace", wordBreak: "break-all", lineHeight: 1.5 }}>
                  security find-generic-password -s "Claude Code-credentials" -w 2&gt;/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
                </div>
                
                <div style={{ position: "absolute", right: 12, top: 12, color: copied ? "#4ade80" : "#52525b", transition: "color 0.2s" }}>
                  {copied ? (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                  ) : (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                  )}
                </div>
              </div>
            </div>
          </div>
          <div style={{ textAlign: "center", marginTop: 20, fontSize: 11, color: "#555" }}>
            <span style={{ display:"inline-block", marginRight: 6 }}>🔒</span>
            100% Client-Side. Token rarely leaves your browser. No backend.
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={S.wrap}>
      {/* Header */}
      <div style={S.head}>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <div style={S.logoSm}>C</div>
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <h1 style={{ fontSize: 16, fontWeight: 700, margin: 0, color: "#e2e8f0" }}>Usage Tracker</h1>
              <StatusDot connected={!error && !!usage} />
            </div>
            <div style={{ fontSize: 11, color: "#888", margin: "4px 0 0", fontFamily: "'JetBrains Mono', monospace", display: "flex", alignItems: "center", gap: 8 }}>
              {fetching ? "Refreshing..." : lastFetch ? `Updated ${timeUntil(lastFetch.toISOString()) === "now" ? "just now" : timeUntil(lastFetch.toISOString()) + " ago"}` : "Connecting..."}
              <span style={{ color: "#333" }}>|</span>
              <span style={{ color: timeToNext < 10 ? "#ef4444" : "#888" }}>↻ in {timeToNext}s</span>
              <button 
                onClick={() => { fetchUsage(savedToken); setTimeToNext(120); }} 
                style={{ background: "none", border: "1px solid #333", borderRadius: 4, color: "#ededed", cursor: "pointer", fontSize: 10, padding: "2px 6px", marginLeft: 4, transition: "background 0.1s" }} 
                onMouseOver={e=>e.target.style.background="#222"} 
                onMouseOut={e=>e.target.style.background="none"}
              >
                Force Fetch
              </button>
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 3 }}>
          {["live", "chart", "⚙️"].map(t => (
            <button key={t} onClick={() => t === "⚙️" ? disconnect() : setView(t)}
              style={{ ...S.tab, ...(view === t ? S.tabA : {}), ...(t === "⚙️" ? { color: "#ef4444", borderColor: "#7f1d1d" } : {}) }}>
              {t === "live" ? "Live" : t === "chart" ? "Chart" : t}
            </button>
          ))}
        </div>
      </div>

      {error && (
        <div style={{ padding: "10px 12px", borderRadius: 10, border: "1px solid #7f1d1d", background: "#1c0a0a", fontSize: 11, color: "#fca5a5", marginBottom: 12 }}>
          ⚠️ {error}
          <br /><span style={{ color: "#64748b" }}>Token may be expired — click ⚙️ to reconnect</span>
        </div>
      )}

      {view === "live" && usage && (
        <>
          {/* Main Gauges */}
          <div style={{ display: "flex", justifyContent: "center", gap: 40, margin: "12px 0 8px" }}>
            <Gauge value={Math.round(fiveHour?.utilization ?? 0)} label="Current Session"
              sub={fiveHour?.resets_at ? `Resets in ${timeUntil(fiveHour.resets_at)}` : null} />
            <Gauge value={Math.round(sevenDay?.utilization ?? 0)} label="Weekly Limit"
              sub={sevenDay?.resets_at ? `Resets ${resetLabel(sevenDay.resets_at)}` : null} />
          </div>

          {/* Alerts */}
          {(fiveHour?.utilization ?? 0) >= 95 && (
            <div className="animate-fade-in" style={{ padding: "12px 16px", borderRadius: 8, border: "1px solid #ef444455", background: "#ef444411", color: "#fca5a5", fontSize: 13, fontWeight: 500, marginBottom: 16, textAlign: "center" }}>
              EXTREME CRITICAL: You are at {Math.round(fiveHour.utilization)}%. Cease generation immediately or risk hitting hard limits. Resets in {timeUntil(fiveHour.resets_at)}.
            </div>
          )}
          {(fiveHour?.utilization ?? 0) >= 80 && (fiveHour?.utilization ?? 0) < 95 && <div style={S.alertRed}>Session critical at {Math.round(fiveHour.utilization)}% — resets in {timeUntil(fiveHour.resets_at)}</div>}
          {(fiveHour?.utilization ?? 0) >= 50 && (fiveHour?.utilization ?? 0) < 80 && <div style={S.alertYellow}>Session at {Math.round(fiveHour.utilization)}% — pace yourself</div>}
          {(sevenDay?.utilization ?? 0) >= 70 && <div style={S.alertRed}>Weekly at {Math.round(sevenDay.utilization)}% — conserve until {resetLabel(sevenDay.resets_at)}</div>}

          {/* Feature: Burn Rate Estimator Tracker */}
          {burnRate > 0 && (
            <div className="animate-fade-in" style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "16px", borderRadius: 8, background: "#0a0a0a", border: "1px solid #222", marginBottom: 16 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <div>
                  <div style={{ fontSize: 13, fontWeight: 600, color: "#ededed" }}>Usage Velocity</div>
                  <div style={{ fontSize: 12, color: "#888", marginTop: 4 }}>You are actively burning limits</div>
                </div>
              </div>
              <div style={{ textAlign: "right" }}>
                <div style={{ fontSize: 15, fontWeight: 600, color: burnRate > 1.5 ? "#ef4444" : "#ededed", fontFamily: "'JetBrains Mono', monospace" }}>+{burnRate.toFixed(2)}% / min</div>
              </div>
            </div>
          )}

          {/* Detail Cards */}
          <div style={S.card}>
            <h3 style={S.secT}>Rate Limit Details</h3>
            <div style={S.detailGrid}>
              <DetailRow label="5-Hour Session" value={fiveHour?.utilization} resetAt={fiveHour?.resets_at} color="#3b82f6" />
              <DetailRow label="7-Day All Models" value={sevenDay?.utilization} resetAt={sevenDay?.resets_at} color="#8b5cf6" />
              {sonnet && <DetailRow label="7-Day Sonnet" value={sonnet?.utilization} resetAt={sonnet?.resets_at} color="#06b6d4" />}
              {opus && <DetailRow label="7-Day Opus" value={opus?.utilization} resetAt={opus?.resets_at} color="#f59e0b" />}
            </div>
          </div>

          {extra?.is_enabled && (
            <div style={S.card}>
              <h3 style={S.secT}>Extra Usage</h3>
              <p style={{ fontSize: 12, color: "#94a3b8", margin: 0 }}>
                Used: ${extra.used_credits?.toFixed(2) ?? "0.00"} / Limit: ${extra.monthly_limit?.toFixed(2) ?? "—"}
              </p>
            </div>
          )}

          {/* Mini Chart */}
          {chartData.length > 1 && (
            <div style={S.card}>
              <h3 style={S.secT}>Last {chartData.length} Polls</h3>
              <div style={{ width: "100%", height: 120 }}>
                <ResponsiveContainer>
                  <AreaChart data={chartData} margin={{ top: 4, right: 4, bottom: 0, left: -24 }}>
                    <defs>
                      <linearGradient id="gs" x1="0" y1="0" x2="0" y2="1">
                        <stop offset="0%" stopColor="#3b82f6" stopOpacity={0.25} /><stop offset="100%" stopColor="#3b82f6" stopOpacity={0} />
                      </linearGradient>
                    </defs>
                    <XAxis dataKey="t" axisLine={false} tickLine={false} tick={{ fill: "#334155", fontSize: 9 }} />
                    <YAxis domain={[0, 100]} axisLine={false} tickLine={false} tick={{ fill: "#334155", fontSize: 9 }} />
                    <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #253047", borderRadius: 8, color: "#e2e8f0", fontSize: 11 }} />
                    <Area type="monotone" dataKey="session" stroke="#3b82f6" strokeWidth={2} fill="url(#gs)" dot={{ r: 2, fill: "#3b82f6" }} name="Session %" />
                    <Area type="monotone" dataKey="weekly" stroke="#8b5cf6" strokeWidth={1.5} fill="none" dot={{ r: 1.5, fill: "#8b5cf6" }} name="Weekly %" strokeDasharray="4 3" />
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </div>
          )}
        </>
      )}

      {view === "chart" && (
        <>
          {chartData.length > 1 ? (
            <>
              <div style={S.card}>
                <h3 style={S.secT}>Session % Over Time</h3>
                <div style={{ width: "100%", height: 200 }}>
                  <ResponsiveContainer>
                    <AreaChart data={chartData} margin={{ top: 8, right: 4, bottom: 0, left: -20 }}>
                      <defs>
                        <linearGradient id="gsFull" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="0%" stopColor="#3b82f6" stopOpacity={0.3} /><stop offset="100%" stopColor="#3b82f6" stopOpacity={0} />
                        </linearGradient>
                      </defs>
                      <XAxis dataKey="t" axisLine={false} tickLine={false} tick={{ fill: "#475569", fontSize: 10 }} />
                      <YAxis domain={[0, 100]} axisLine={false} tickLine={false} tick={{ fill: "#475569", fontSize: 10 }} />
                      <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #253047", borderRadius: 8, color: "#e2e8f0", fontSize: 12 }} />
                      <Area type="monotone" dataKey="session" stroke="#3b82f6" strokeWidth={2} fill="url(#gsFull)" dot={{ r: 3, fill: "#3b82f6" }} name="Session %" />
                      <Area type="monotone" dataKey="weekly" stroke="#8b5cf6" strokeWidth={2} fill="none" dot={{ r: 2.5, fill: "#8b5cf6" }} name="Weekly %" strokeDasharray="5 3" />
                    </AreaChart>
                  </ResponsiveContainer>
                </div>
                <div style={{ display: "flex", gap: 16, justifyContent: "center", marginTop: 8 }}>
                  <span style={S.leg}><span style={{ width: 8, height: 8, borderRadius: 99, background: "#3b82f6", display: "inline-block" }} /> Session (5hr)</span>
                  <span style={S.leg}><span style={{ width: 12, height: 2, background: "#8b5cf6", display: "inline-block" }} /> Weekly (7d)</span>
                </div>
              </div>

              <div style={S.card}>
                <h3 style={S.secT}>Poll Log ({history.length} entries)</h3>
                <div style={{ maxHeight: 250, overflow: "auto" }}>
                  {history.slice(0, 50).map((h, i) => (
                    <div key={i} style={{ display: "flex", alignItems: "center", gap: 8, padding: "5px 0", borderBottom: "1px solid #141f30", fontSize: 11 }}>
                      <span style={{ color: "#475569", minWidth: 58 }}>{new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: true })}</span>
                      <span style={{ color: "#3b82f6", fontWeight: 700, minWidth: 40 }}>S:{h.s != null ? Math.round(h.s) : "—"}%</span>
                      <span style={{ color: "#8b5cf6", fontWeight: 700, minWidth: 40 }}>W:{h.w != null ? Math.round(h.w) : "—"}%</span>
                    </div>
                  ))}
                </div>
              </div>
            </>
          ) : (
            <div style={{ ...S.card, textAlign: "center", padding: 40, color: "#475569", fontSize: 13 }}>
              Collecting data... charts will appear after a few polls.
            </div>
          )}
        </>
      )}

      <div style={{ textAlign: "center", fontSize: 9, color: "#222", padding: "12px 0" }}>
        Auto-refreshes every 120s · Data persists across sessions
      </div>
    </div>
  );
}
