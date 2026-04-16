import { useState, useEffect, useCallback, useRef } from "react";
import { XAxis, YAxis, Tooltip, ResponsiveContainer, AreaChart, Area, CartesianGrid } from "recharts";
import { timeUntil, resetLabel } from "./utils/time";
import { S } from "./utils/styles";
import { Gauge } from "./components/Gauge";
import { StatusDot } from "./components/StatusDot";
import { DetailRow } from "./components/DetailRow";
import "./App.css";

const STORAGE_KEY = "claude-auto-tracker";
const POLL_INTERVAL_SEC = 120;

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
  const [timeToNext, setTimeToNext] = useState(POLL_INTERVAL_SEC);
  const [copied, setCopied] = useState(false);

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

  const abortRef = useRef(null);

  const fetchUsage = useCallback(async (tok) => {
    const t = tok || savedToken;
    if (!t) return;

    if (abortRef.current) abortRef.current.abort();
    const controller = new AbortController();
    abortRef.current = controller;

    setFetching(true);
    setError("");
    try {
      const resp = await fetch("/api/oauth/usage", {
        headers: {
          "Authorization": `Bearer ${t}`,
          "anthropic-beta": "oauth-2025-04-20",
          "Content-Type": "application/json",
        },
        signal: controller.signal,
      });
      if (resp.status === 429) {
        setFetching(false);
        return;
      }
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({}));
        throw new Error(err?.error?.message || `HTTP ${resp.status}`);
      }
      const data = await resp.json();
      setUsage(data);
      setLastFetch(new Date());

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
      if (e.name === "AbortError") return;
      setError(e.message || "Failed to fetch");
    }
    setFetching(false);
  }, [savedToken, persist]);

  useEffect(() => {
    if (!savedToken) return;

    fetchUsage(savedToken);
    setTimeToNext(POLL_INTERVAL_SEC);

    const interval = setInterval(() => {
      setTimeToNext(prev => {
        if (prev <= 1) {
          fetchUsage(savedToken);
          return POLL_INTERVAL_SEC;
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
  const haiku = usage?.seven_day_haiku;
  const extra = usage?.extra_usage;

  const extraOver = extra?.is_enabled && extra?.used_credits != null && extra?.monthly_limit != null
    && extra.used_credits > extra.monthly_limit
    ? extra.used_credits - extra.monthly_limit
    : 0;

  const chartData = history.slice(0, 30).reverse().map(h => ({
    t: new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false }),
    session: h.s != null ? Math.round(h.s) : null,
    weekly: h.w != null ? Math.round(h.w) : null,
  }));

  const recentHist = history.slice(0, 6);
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

  const currentSession = fiveHour?.utilization ?? 0;
  const etaMinutes = burnRate > 0 && currentSession < 100
    ? Math.round((100 - currentSession) / burnRate)
    : null;

  const downloadHistoryCsv = () => {
    const rows = [["timestamp", "session_pct", "weekly_pct"]];
    for (const h of history) {
      rows.push([h.ts, h.s != null ? h.s.toFixed(2) : "", h.w != null ? h.w.toFixed(2) : ""]);
    }
    const csv = rows.map(r => r.join(",")).join("\n");
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `claude-usage-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (loading) {
    return (
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "100vh", color: "#a1a1aa", fontFamily: "'JetBrains Mono', monospace", fontSize: 13 }}>
        Loading workspace…
      </div>
    );
  }

  if (!savedToken) {
    return (
      <div style={{ ...S.wrap, alignItems: "center", justifyContent: "center", padding: "60px 20px" }}>
        <div className="animate-fade-in" style={{ width: "100%", maxWidth: 400 }}>

          <div style={{ textAlign: "center", marginBottom: 28 }}>
            <div style={{ ...S.logo, margin: "0 auto 18px", width: 56, height: 56, fontSize: 26, borderRadius: 16 }}>C</div>
            <h1 style={{ fontSize: 24, fontWeight: 600, margin: 0, letterSpacing: "-0.02em", color: "#f5f5f7" }}>Usage Tracker</h1>
            <p style={{ fontSize: 13, color: "#a1a1aa", marginTop: 8, lineHeight: 1.55 }}>
              Connect your Anthropic session to monitor rate limits in real time.
            </p>
          </div>

          <div className="glass" style={{ padding: 22 }}>
            <label style={{ display: "block", fontSize: 10, fontWeight: 600, color: "#a1a1aa", marginBottom: 10, textTransform: "uppercase", letterSpacing: "0.1em" }}>
              Session Token
            </label>
            <textarea
              value={token}
              onChange={(e) => setToken(e.target.value)}
              placeholder="Paste token (sk-ant-…)"
              style={{
                width: "100%",
                background: "rgba(0, 0, 0, 0.25)",
                border: "1px solid rgba(255, 255, 255, 0.08)",
                borderRadius: 12,
                padding: "12px 14px",
                color: "#f5f5f7",
                fontSize: 12,
                fontFamily: "'JetBrains Mono', monospace",
                outline: "none",
                resize: "none",
                transition: "border 0.2s, background 0.2s",
                boxSizing: "border-box",
                marginBottom: 14,
              }}
              onFocus={e => { e.target.style.borderColor = "rgba(125, 211, 252, 0.4)"; e.target.style.background = "rgba(0,0,0,0.35)"; }}
              onBlur={e => { e.target.style.borderColor = "rgba(255, 255, 255, 0.08)"; e.target.style.background = "rgba(0,0,0,0.25)"; }}
              rows={3}
            />
            <button
              onClick={saveToken}
              style={{
                width: "100%",
                background: token.trim()
                  ? "linear-gradient(135deg, #f5f5f7, #e4e4e7)"
                  : "rgba(255, 255, 255, 0.04)",
                color: token.trim() ? "#0a0a0f" : "#52525b",
                border: "1px solid rgba(255, 255, 255, 0.12)",
                borderRadius: 12,
                padding: "11px 0",
                fontSize: 13,
                fontWeight: 600,
                cursor: token.trim() ? "pointer" : "not-allowed",
                transition: "all 0.2s",
                boxShadow: token.trim() ? "0 8px 24px rgba(255, 255, 255, 0.06)" : "none",
              }}
            >
              Connect
            </button>
          </div>

          <div className="glass" style={{ marginTop: 18, padding: 0, overflow: "hidden" }}>
            <div style={{ padding: "14px 18px", borderBottom: "1px solid rgba(255, 255, 255, 0.06)", fontSize: 11, fontWeight: 600, color: "#d4d4d8", textTransform: "uppercase", letterSpacing: "0.08em" }}>
              How to get your token
            </div>
            <div style={{ padding: 18, fontSize: 12, color: "#a1a1aa", lineHeight: 1.6 }}>
              <p style={{ margin: "0 0 14px 0" }}>
                <strong style={{ color: "#f5f5f7" }}>Browser:</strong> Login to <a href="https://claude.ai" target="_blank" rel="noreferrer" style={{ color: "#7dd3fc", textDecoration: "none" }}>claude.ai</a> → DevTools (F12) → Application → Cookies → copy <code>sessionKey</code>.
              </p>
              <p style={{ margin: "0 0 10px 0" }}>
                <strong style={{ color: "#f5f5f7" }}>Claude Code (Mac):</strong>
              </p>
              <div
                style={{
                  position: "relative",
                  background: "rgba(0, 0, 0, 0.3)",
                  border: "1px solid rgba(255, 255, 255, 0.06)",
                  borderRadius: 10,
                  padding: "12px",
                  paddingRight: 36,
                  cursor: "pointer",
                  transition: "border 0.2s, background 0.2s",
                }}
                onClick={() => {
                  navigator.clipboard.writeText(`security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"`);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 2000);
                }}
                onMouseOver={e => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.14)"; }}
                onMouseOut={e => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.06)"; }}
                title="Click to copy"
              >
                <div style={{ fontSize: 11, color: "#d4d4d8", fontFamily: "'JetBrains Mono', monospace", wordBreak: "break-all", lineHeight: 1.5 }}>
                  security find-generic-password -s "Claude Code-credentials" -w 2&gt;/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"
                </div>
                <div style={{ position: "absolute", right: 12, top: 12, color: copied ? "#6ee7b7" : "#71717a", transition: "color 0.2s" }}>
                  {copied ? (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                  ) : (
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                  )}
                </div>
              </div>
            </div>
          </div>

          <div style={{ textAlign: "center", marginTop: 20, fontSize: 11, color: "#71717a" }}>
            100% client-side · Token stays in your browser
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={S.wrap}>
      {/* Header */}
      <div style={S.head} className="animate-fade-in">
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div style={S.logoSm}>C</div>
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <h1 style={{ fontSize: 16, fontWeight: 600, margin: 0, color: "#f5f5f7", letterSpacing: "-0.01em" }}>Usage Tracker</h1>
              <StatusDot connected={!error && !!usage} />
            </div>
            <div style={{ fontSize: 10.5, color: "#a1a1aa", margin: "4px 0 0", fontFamily: "'JetBrains Mono', monospace", display: "flex", alignItems: "center", gap: 8 }}>
              {fetching ? "Refreshing…" : lastFetch ? `Updated ${timeUntil(lastFetch.toISOString()) === "now" ? "just now" : timeUntil(lastFetch.toISOString()) + " ago"}` : "Connecting…"}
              <span style={{ color: "rgba(255,255,255,0.15)" }}>│</span>
              <span style={{ color: timeToNext < 10 ? "#fb7185" : "#a1a1aa" }}>↻ {timeToNext}s</span>
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          <button
            onClick={() => { fetchUsage(savedToken); setTimeToNext(POLL_INTERVAL_SEC); }}
            style={{ ...S.tab, fontSize: 11 }}
            onMouseOver={e => { e.currentTarget.style.background = "rgba(255,255,255,0.05)"; }}
            onMouseOut={e => { e.currentTarget.style.background = "transparent"; }}
            title="Force refresh"
          >
            ↻ Fetch
          </button>
          {["live", "chart"].map(t => (
            <button key={t} onClick={() => setView(t)}
              style={{ ...S.tab, ...(view === t ? S.tabA : {}) }}>
              {t === "live" ? "Live" : "Chart"}
            </button>
          ))}
          <button
            onClick={disconnect}
            style={{ ...S.tab, color: "#fb7185", borderColor: "rgba(251, 113, 133, 0.25)" }}
            onMouseOver={e => { e.currentTarget.style.background = "rgba(251, 113, 133, 0.08)"; }}
            onMouseOut={e => { e.currentTarget.style.background = "transparent"; }}
            title="Disconnect"
          >
            ⏻
          </button>
        </div>
      </div>

      {error && (
        <div style={S.alertRed} className="animate-fade-in">
          ⚠ {error}
          <br />
          <span style={{ color: "#a1a1aa", fontSize: 11 }}>Token may be expired — click ⏻ to reconnect</span>
        </div>
      )}

      {view === "live" && usage && (
        <>
          {/* Hero Gauges */}
          <div style={S.heroCard} className="animate-fade-in">
            <div style={{
              position: "absolute",
              top: -60,
              right: -60,
              width: 220,
              height: 220,
              borderRadius: "50%",
              background: "radial-gradient(circle, rgba(125, 211, 252, 0.15), transparent 70%)",
              pointerEvents: "none",
            }} />
            <div style={{
              position: "absolute",
              bottom: -80,
              left: -40,
              width: 260,
              height: 260,
              borderRadius: "50%",
              background: "radial-gradient(circle, rgba(196, 181, 253, 0.12), transparent 70%)",
              pointerEvents: "none",
            }} />
            <div style={{ display: "flex", justifyContent: "center", gap: 48, flexWrap: "wrap", position: "relative" }}>
              <Gauge value={Math.round(fiveHour?.utilization ?? 0)} label="Current Session"
                sub={fiveHour?.resets_at ? `Resets in ${timeUntil(fiveHour.resets_at)}` : null} />
              <Gauge value={Math.round(sevenDay?.utilization ?? 0)} label="Weekly Limit"
                sub={sevenDay?.resets_at ? `Resets ${resetLabel(sevenDay.resets_at)}` : null} />
            </div>
          </div>

          {/* Alerts */}
          {(fiveHour?.utilization ?? 0) >= 95 && (
            <div className="animate-fade-in" style={{ ...S.alertRed, textAlign: "center" }}>
              <strong>CRITICAL</strong> — at {Math.round(fiveHour.utilization)}%. Resets in {timeUntil(fiveHour.resets_at)}.
            </div>
          )}
          {(fiveHour?.utilization ?? 0) >= 80 && (fiveHour?.utilization ?? 0) < 95 && (
            <div style={S.alertRed} className="animate-fade-in">Session critical at {Math.round(fiveHour.utilization)}% — resets in {timeUntil(fiveHour.resets_at)}</div>
          )}
          {(fiveHour?.utilization ?? 0) >= 50 && (fiveHour?.utilization ?? 0) < 80 && (
            <div style={S.alertYellow} className="animate-fade-in">Session at {Math.round(fiveHour.utilization)}% — pace yourself</div>
          )}
          {(sevenDay?.utilization ?? 0) >= 70 && (
            <div style={S.alertRed} className="animate-fade-in">Weekly at {Math.round(sevenDay.utilization)}% — conserve until {resetLabel(sevenDay.resets_at)}</div>
          )}

          {/* Velocity */}
          {burnRate > 0 && (
            <div className="animate-fade-in" style={{ ...S.card, display: "flex", justifyContent: "space-between", alignItems: "center", padding: "18px 22px" }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: "#f5f5f7", display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="glow-dot" style={{ color: burnRate > 1.5 ? "#fb7185" : "#7dd3fc" }} />
                  Usage Velocity
                </div>
                <div style={{ fontSize: 12, color: "#a1a1aa", marginTop: 6 }}>
                  {etaMinutes != null
                    ? `Session hits 100% in ~${etaMinutes}m at this rate`
                    : "Actively consuming quota"}
                </div>
              </div>
              <div style={{ textAlign: "right" }}>
                <div style={{
                  fontSize: 17,
                  fontWeight: 600,
                  color: burnRate > 1.5 ? "#fb7185" : "#f5f5f7",
                  fontFamily: "'JetBrains Mono', monospace",
                  letterSpacing: "-0.01em",
                }}>
                  +{burnRate.toFixed(2)}%
                </div>
                <div style={{ fontSize: 10, color: "#71717a", marginTop: 2, fontFamily: "'JetBrains Mono', monospace" }}>per min</div>
              </div>
            </div>
          )}

          {/* Rate Limit Details */}
          <div style={S.card} className="animate-fade-in">
            <h3 style={S.secT}>Rate Limit Details</h3>
            <div style={S.detailGrid}>
              <DetailRow label="5-Hour Session" value={fiveHour?.utilization} resetAt={fiveHour?.resets_at} color="#7dd3fc" />
              <DetailRow label="7-Day All Models" value={sevenDay?.utilization} resetAt={sevenDay?.resets_at} color="#c4b5fd" />
              {sonnet && <DetailRow label="7-Day Sonnet" value={sonnet?.utilization} resetAt={sonnet?.resets_at} color="#67e8f9" />}
              {opus && <DetailRow label="7-Day Opus" value={opus?.utilization} resetAt={opus?.resets_at} color="#fcd34d" />}
              {haiku && <DetailRow label="7-Day Haiku" value={haiku?.utilization} resetAt={haiku?.resets_at} color="#6ee7b7" />}
            </div>
          </div>

          {extra?.is_enabled && (
            <div style={S.card} className="animate-fade-in">
              <h3 style={S.secT}>Extra Usage</h3>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 12 }}>
                <div>
                  <div style={{ fontSize: 22, fontWeight: 500, color: "#f5f5f7", fontFamily: "'Inter', sans-serif", letterSpacing: "-0.02em" }}>
                    ${extra.used_credits?.toFixed(2) ?? "0.00"}
                  </div>
                  <div style={{ fontSize: 11, color: "#a1a1aa", marginTop: 4 }}>
                    of ${extra.monthly_limit?.toFixed(2) ?? "—"} monthly cap
                  </div>
                </div>
                {extraOver > 0 ? (
                  <div style={{
                    padding: "6px 12px",
                    borderRadius: 999,
                    background: "rgba(251, 113, 133, 0.12)",
                    border: "1px solid rgba(251, 113, 133, 0.3)",
                    color: "#fecdd3",
                    fontSize: 11,
                    fontWeight: 600,
                  }}>
                    Over by ${extraOver.toFixed(2)}
                  </div>
                ) : (
                  <div style={{
                    padding: "6px 12px",
                    borderRadius: 999,
                    background: "rgba(110, 231, 183, 0.08)",
                    border: "1px solid rgba(110, 231, 183, 0.22)",
                    color: "#a7f3d0",
                    fontSize: 11,
                    fontWeight: 600,
                  }}>
                    Within cap
                  </div>
                )}
              </div>
              {extra.monthly_limit > 0 && (
                <div style={{ marginTop: 14, height: 6, borderRadius: 999, background: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
                  <div style={{
                    height: "100%",
                    width: `${Math.min(100, (extra.used_credits / extra.monthly_limit) * 100)}%`,
                    background: extraOver > 0
                      ? "linear-gradient(90deg, #fb7185, #f472b6)"
                      : "linear-gradient(90deg, #7dd3fc, #c4b5fd)",
                    transition: "width 0.9s cubic-bezier(0.16, 1, 0.3, 1)",
                    boxShadow: extraOver > 0 ? "0 0 12px rgba(251, 113, 133, 0.5)" : "0 0 12px rgba(125, 211, 252, 0.4)",
                  }} />
                </div>
              )}
            </div>
          )}

          {chartData.length > 1 && (
            <div style={S.card} className="animate-fade-in">
              <h3 style={S.secT}>Last {chartData.length} Polls</h3>
              <div style={{ width: "100%", height: 140 }}>
                <ResponsiveContainer>
                  <AreaChart data={chartData} margin={{ top: 4, right: 4, bottom: 0, left: -22 }}>
                    <defs>
                      <linearGradient id="gsMini" x1="0" y1="0" x2="0" y2="1">
                        <stop offset="0%" stopColor="#7dd3fc" stopOpacity={0.35} />
                        <stop offset="100%" stopColor="#7dd3fc" stopOpacity={0} />
                      </linearGradient>
                    </defs>
                    <XAxis dataKey="t" axisLine={false} tickLine={false} tick={{ fill: "rgba(255,255,255,0.25)", fontSize: 9 }} />
                    <YAxis domain={[0, 100]} axisLine={false} tickLine={false} tick={{ fill: "rgba(255,255,255,0.25)", fontSize: 9 }} />
                    <Tooltip
                      contentStyle={{
                        background: "rgba(10, 12, 20, 0.85)",
                        backdropFilter: "blur(16px)",
                        border: "1px solid rgba(255,255,255,0.12)",
                        borderRadius: 10,
                        color: "#f5f5f7",
                        fontSize: 11,
                        boxShadow: "0 8px 24px rgba(0,0,0,0.5)",
                      }}
                    />
                    <Area type="monotone" dataKey="session" stroke="#7dd3fc" strokeWidth={2} fill="url(#gsMini)" dot={{ r: 2, fill: "#7dd3fc" }} name="Session %" />
                    <Area type="monotone" dataKey="weekly" stroke="#c4b5fd" strokeWidth={1.5} fill="none" dot={{ r: 1.5, fill: "#c4b5fd" }} name="Weekly %" strokeDasharray="4 3" />
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
              <div style={S.card} className="animate-fade-in">
                <h3 style={S.secT}>Session % Over Time</h3>
                <div style={{ width: "100%", height: 220 }}>
                  <ResponsiveContainer>
                    <AreaChart data={chartData} margin={{ top: 8, right: 4, bottom: 0, left: -18 }}>
                      <defs>
                        <linearGradient id="gsFull" x1="0" y1="0" x2="0" y2="1">
                          <stop offset="0%" stopColor="#7dd3fc" stopOpacity={0.38} />
                          <stop offset="100%" stopColor="#7dd3fc" stopOpacity={0} />
                        </linearGradient>
                      </defs>
                      <CartesianGrid stroke="rgba(255,255,255,0.04)" vertical={false} />
                      <XAxis dataKey="t" axisLine={false} tickLine={false} tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 10 }} />
                      <YAxis domain={[0, 100]} axisLine={false} tickLine={false} tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 10 }} />
                      <Tooltip
                        contentStyle={{
                          background: "rgba(10, 12, 20, 0.85)",
                          backdropFilter: "blur(16px)",
                          border: "1px solid rgba(255,255,255,0.12)",
                          borderRadius: 10,
                          color: "#f5f5f7",
                          fontSize: 12,
                          boxShadow: "0 8px 24px rgba(0,0,0,0.5)",
                        }}
                      />
                      <Area type="monotone" dataKey="session" stroke="#7dd3fc" strokeWidth={2.2} fill="url(#gsFull)" dot={{ r: 3, fill: "#7dd3fc" }} name="Session %" />
                      <Area type="monotone" dataKey="weekly" stroke="#c4b5fd" strokeWidth={2} fill="none" dot={{ r: 2.5, fill: "#c4b5fd" }} name="Weekly %" strokeDasharray="5 3" />
                    </AreaChart>
                  </ResponsiveContainer>
                </div>
                <div style={{ display: "flex", gap: 18, justifyContent: "center", marginTop: 12 }}>
                  <span style={S.leg}><span style={{ width: 8, height: 8, borderRadius: 99, background: "#7dd3fc", display: "inline-block", boxShadow: "0 0 8px #7dd3fc" }} /> Session (5hr)</span>
                  <span style={S.leg}><span style={{ width: 12, height: 2, background: "#c4b5fd", display: "inline-block", boxShadow: "0 0 6px #c4b5fd" }} /> Weekly (7d)</span>
                </div>
              </div>

              <div style={S.card} className="animate-fade-in">
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
                  <h3 style={{ ...S.secT, margin: 0 }}>Poll Log ({history.length})</h3>
                  <button
                    onClick={downloadHistoryCsv}
                    style={{
                      background: "rgba(255,255,255,0.04)",
                      border: "1px solid rgba(255,255,255,0.1)",
                      borderRadius: 8,
                      color: "#d4d4d8",
                      cursor: "pointer",
                      fontSize: 11,
                      padding: "5px 12px",
                      fontFamily: "inherit",
                      fontWeight: 500,
                      transition: "background 0.2s, border-color 0.2s",
                    }}
                    onMouseOver={e => { e.currentTarget.style.background = "rgba(255,255,255,0.08)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.18)"; }}
                    onMouseOut={e => { e.currentTarget.style.background = "rgba(255,255,255,0.04)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.1)"; }}
                  >
                    Export CSV
                  </button>
                </div>
                <div style={{ maxHeight: 280, overflow: "auto", paddingRight: 4 }}>
                  {history.slice(0, 50).map((h, i) => (
                    <div key={i} style={{
                      display: "flex",
                      alignItems: "center",
                      gap: 12,
                      padding: "8px 0",
                      borderBottom: "1px solid rgba(255,255,255,0.04)",
                      fontSize: 11,
                      fontFamily: "'JetBrains Mono', monospace",
                    }}>
                      <span style={{ color: "#71717a", minWidth: 62 }}>
                        {new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: true })}
                      </span>
                      <span style={{ color: "#7dd3fc", fontWeight: 600, minWidth: 46 }}>S {h.s != null ? Math.round(h.s) : "—"}%</span>
                      <span style={{ color: "#c4b5fd", fontWeight: 600, minWidth: 46 }}>W {h.w != null ? Math.round(h.w) : "—"}%</span>
                    </div>
                  ))}
                </div>
              </div>
            </>
          ) : (
            <div style={{ ...S.card, textAlign: "center", padding: 48, color: "#a1a1aa", fontSize: 13 }}>
              Collecting data… charts will appear after a few polls.
            </div>
          )}
        </>
      )}

      <div style={{ textAlign: "center", fontSize: 10, color: "#52525b", padding: "16px 0 8px", fontFamily: "'JetBrains Mono', monospace" }}>
        Auto-refreshes every {POLL_INTERVAL_SEC}s · Data persists across sessions
      </div>
    </div>
  );
}
