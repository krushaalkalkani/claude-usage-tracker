import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { XAxis, YAxis, Tooltip, ResponsiveContainer, AreaChart, Area, CartesianGrid } from "recharts";
import { timeUntil, resetLabel } from "./utils/time";
import { S } from "./utils/styles";
import { Gauge } from "./components/Gauge";
import { StatusDot } from "./components/StatusDot";
import { DetailRow } from "./components/DetailRow";
import {
  parseUsage,
  sessionLimit,
  weeklyLimit,
  modelLimits,
  surfaceLimits,
  bottleneck,
  formatMoney,
  disabledExplanation,
  burnRate,
  projection,
} from "./lib/usageModel";
import "./App.css";

const STORAGE_KEY = "claude-auto-tracker";
const POLL_INTERVAL_SEC = 120;
const MAX_HISTORY = 400;

/** Colors used for the per-limit detail rows, cycled for whatever the API reports. */
const LIMIT_COLORS = ["#7dd3fc", "#c4b5fd", "#67e8f9", "#fcd34d", "#6ee7b7", "#f9a8d4"];

/**
 * v1 stored history as `{ts, s, w}`. v2 stores `{ts, limits: {id: percent}, spend}` so that
 * model-scoped limits are recorded too, and so the ids line up with the macOS app.
 */
function migrateHistory(entries) {
  if (!Array.isArray(entries)) return [];
  return entries
    .map((e) => {
      if (e && e.limits) return e;
      if (!e || !e.ts) return null;
      const limits = {};
      if (typeof e.s === "number") limits.session = e.s;
      if (typeof e.w === "number") limits.weekly_all = e.w;
      return { ts: e.ts, limits, spend: null };
    })
    .filter(Boolean);
}

/** Reads persisted state once, at module scope, so no mount effect is needed. */
function loadStored() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const data = JSON.parse(raw);
    return {
      token: typeof data.token === "string" ? data.token : "",
      history: migrateHistory(data.history),
      // Re-parse the cached payload so a client upgrade never renders a stale shape.
      snapshot: data.rawUsage ? parseUsage(data.rawUsage) : null,
      lastFetch: data.lastFetch ? new Date(data.lastFetch) : null,
    };
  } catch {
    // Corrupt storage starts fresh rather than blocking the app.
    return {};
  }
}

export default function App() {
  // Lazy initializers instead of a mount effect: no cascading render, no loading flash.
  const [stored] = useState(loadStored);
  const [token, setToken] = useState("");
  const [savedToken, setSavedToken] = useState(stored.token ?? "");
  const [snapshot, setSnapshot] = useState(stored.snapshot ?? null);
  const [history, setHistory] = useState(stored.history ?? []);
  const [error, setError] = useState("");
  const [fetching, setFetching] = useState(false);
  const [lastFetch, setLastFetch] = useState(stored.lastFetch ?? null);
  const [view, setView] = useState("live");
  const [copied, setCopied] = useState(false);
  const [now, setNow] = useState(() => new Date());

  // One 10-second clock drives every relative timestamp. v1 re-rendered the whole tree once
  // a second purely to animate a countdown — 120 renders per fetch.
  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 10000);
    return () => clearInterval(id);
  }, []);

  const persist = useCallback((updates) => {
    try {
      const r = localStorage.getItem(STORAGE_KEY);
      const existing = r ? JSON.parse(r) : {};
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...existing, ...updates }));
    } catch {
      /* quota errors must not break the session */
    }
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
          Authorization: `Bearer ${t}`,
          "anthropic-beta": "oauth-2025-04-20",
          "Content-Type": "application/json",
        },
        signal: controller.signal,
      });
      if (resp.status === 429) {
        // Keep showing the last good data rather than blanking the dashboard.
        setError("Rate limited — retrying on the next poll");
        setFetching(false);
        return;
      }
      if (!resp.ok) {
        const err = await resp.json().catch(() => ({}));
        throw new Error(err?.error?.message || `HTTP ${resp.status}`);
      }
      const raw = await resp.json();
      const parsed = parseUsage(raw);
      const stamp = new Date();
      setSnapshot(parsed);
      setLastFetch(stamp);

      const entry = {
        ts: stamp.toISOString(),
        limits: Object.fromEntries(parsed.limits.map((l) => [l.id, l.percent])),
        spend: parsed.spend?.percent ?? null,
      };
      setHistory((prev) => {
        const next = [entry, ...prev].slice(0, MAX_HISTORY);
        persist({ rawUsage: raw, history: next, lastFetch: stamp.toISOString() });
        return next;
      });
    } catch (e) {
      if (e.name === "AbortError") return;
      setError(e.message || "Failed to fetch");
    }
    setFetching(false);
  }, [savedToken, persist]);

  useEffect(() => {
    if (!savedToken) return undefined;
    // The first fetch is scheduled rather than called inline, so the effect never triggers a
    // synchronous state update during commit.
    const initial = setTimeout(() => fetchUsage(savedToken), 0);
    const interval = setInterval(() => fetchUsage(savedToken), POLL_INTERVAL_SEC * 1000);
    return () => {
      clearTimeout(initial);
      clearInterval(interval);
      abortRef.current?.abort();
    };
  }, [savedToken]); // eslint-disable-line react-hooks/exhaustive-deps

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
    setSnapshot(null);
    setHistory([]);
    setError("");
    persist({ token: "", rawUsage: null, history: [], lastFetch: null });
  };

  // Chronological history for the analytics helpers, which expect oldest-first.
  const chronological = useMemo(() => [...history].reverse(), [history]);

  const session = useMemo(() => (snapshot ? sessionLimit(snapshot) : null), [snapshot]);
  const weekly = useMemo(() => (snapshot ? weeklyLimit(snapshot) : null), [snapshot]);
  const scoped = useMemo(
    () => (snapshot ? [...modelLimits(snapshot), ...surfaceLimits(snapshot)] : []),
    [snapshot],
  );
  const tightest = snapshot ? bottleneck(snapshot) : null;
  const spend = snapshot?.spend ?? null;

  // Derived from the last fetch and the 10-second clock, so the countdown costs no extra
  // renders of its own.
  const secondsToNext = lastFetch
    ? Math.max(0, POLL_INTERVAL_SEC - Math.floor((now - lastFetch) / 1000))
    : POLL_INTERVAL_SEC;

  const sessionRate = session ? burnRate(chronological, session.id) : null;
  const sessionProjection = session ? projection(session, chronological, now) : null;

  const chartData = useMemo(() => {
    const ids = snapshot?.limits.map((l) => l.id) ?? [];
    const sessionId = session?.id;
    const weeklyId = weekly?.id;
    const modelId = scoped[0]?.id;
    return chronological.slice(-40).map((h) => ({
      t: new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false }),
      session: sessionId && ids.length ? round(h.limits[sessionId]) : round(h.limits.session),
      weekly: weeklyId ? round(h.limits[weeklyId]) : round(h.limits.weekly_all),
      model: modelId ? round(h.limits[modelId]) : null,
    }));
  }, [chronological, snapshot, session, weekly, scoped]);

  const downloadHistoryCsv = () => {
    const ids = Array.from(
      new Set(history.flatMap((h) => Object.keys(h.limits || {}))),
    ).sort();
    const rows = [["timestamp", ...ids, "spend_pct"]];
    for (const h of history) {
      rows.push([
        h.ts,
        ...ids.map((id) => (typeof h.limits?.[id] === "number" ? h.limits[id].toFixed(2) : "")),
        typeof h.spend === "number" ? h.spend.toFixed(2) : "",
      ]);
    }
    const csv = rows.map((r) => r.join(",")).join("\n");
    const blob = new Blob([csv], { type: "text/csv" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `claude-usage-${new Date().toISOString().slice(0, 10)}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  if (!savedToken) {
    return <ConnectScreen token={token} setToken={setToken} saveToken={saveToken} copied={copied} setCopied={setCopied} />;
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
              <StatusDot connected={!error && !!snapshot} />
            </div>
            <div style={{ fontSize: 10.5, color: "#a1a1aa", margin: "4px 0 0", fontFamily: "'JetBrains Mono', monospace", display: "flex", alignItems: "center", gap: 8 }}>
              {fetching ? "Refreshing…" : lastFetch ? `Updated ${relativeAge(lastFetch)}` : "Connecting…"}
              <span style={{ color: "rgba(255,255,255,0.15)" }}>│</span>
              <span style={{ color: secondsToNext < 15 ? "#fb7185" : "#a1a1aa" }}>↻ {secondsToNext}s</span>
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 4, alignItems: "center" }}>
          <button
            onClick={() => fetchUsage(savedToken)}
            style={{ ...S.tab, fontSize: 11 }}
            onMouseOver={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.05)"; }}
            onMouseOut={(e) => { e.currentTarget.style.background = "transparent"; }}
            title="Force refresh"
          >
            ↻ Fetch
          </button>
          {["live", "chart"].map((t) => (
            <button key={t} onClick={() => setView(t)} style={{ ...S.tab, ...(view === t ? S.tabA : {}) }}>
              {t === "live" ? "Live" : "Chart"}
            </button>
          ))}
          <button
            onClick={disconnect}
            style={{ ...S.tab, color: "#fb7185", borderColor: "rgba(251, 113, 133, 0.25)" }}
            onMouseOver={(e) => { e.currentTarget.style.background = "rgba(251, 113, 133, 0.08)"; }}
            onMouseOut={(e) => { e.currentTarget.style.background = "transparent"; }}
            title="Disconnect"
          >
            ⏻
          </button>
        </div>
      </div>

      {error && (
        <div style={S.alertRed} className="animate-fade-in">
          ⚠ {error}
          {snapshot && <><br /><span style={{ color: "#a1a1aa", fontSize: 11 }}>Showing the last values received{lastFetch ? ` · ${relativeAge(lastFetch)}` : ""}</span></>}
          {!snapshot && <><br /><span style={{ color: "#a1a1aa", fontSize: 11 }}>Token may be expired — click ⏻ to reconnect</span></>}
        </div>
      )}

      {view === "live" && snapshot && (
        <>
          {/* Hero gauges — always the session and the account-wide weekly window. */}
          <div style={S.heroCard} className="animate-fade-in">
            <div style={{ position: "absolute", top: -60, right: -60, width: 220, height: 220, borderRadius: "50%", background: "radial-gradient(circle, rgba(125, 211, 252, 0.15), transparent 70%)", pointerEvents: "none" }} />
            <div style={{ position: "absolute", bottom: -80, left: -40, width: 260, height: 260, borderRadius: "50%", background: "radial-gradient(circle, rgba(196, 181, 253, 0.12), transparent 70%)", pointerEvents: "none" }} />
            <div style={{ display: "flex", justifyContent: "center", gap: 48, flexWrap: "wrap", position: "relative" }}>
              {session && (
                <Gauge
                  value={Math.round(session.percent)}
                  label="Current Session"
                  sub={session.resetsAt ? `Resets in ${timeUntil(session.resetsAt)}` : null}
                />
              )}
              {weekly && (
                <Gauge
                  value={Math.round(weekly.percent)}
                  label="Weekly Limit"
                  sub={weekly.resetsAt ? `Resets ${resetLabel(weekly.resetsAt)}` : null}
                />
              )}
            </div>
            {tightest && snapshot.limits.length > 1 && (
              <div style={{ textAlign: "center", marginTop: 18, fontSize: 11.5, color: "#a1a1aa", position: "relative" }}>
                <strong style={{ color: "#f5f5f7", fontWeight: 600 }}>{tightest.shortTitle}</strong> is your tightest limit at {Math.round(tightest.percent)}%
                {tightest.isActive && <span style={{ color: "#7dd3fc" }}> · currently active</span>}
              </div>
            )}
          </div>

          {/* Alerts, driven by the tightest limit rather than only the session. */}
          {tightest && tightest.percent >= 95 && (
            <div className="animate-fade-in" style={{ ...S.alertRed, textAlign: "center" }}>
              <strong>CRITICAL</strong> — {tightest.shortTitle} at {Math.round(tightest.percent)}%
              {tightest.resetsAt ? `. Resets in ${timeUntil(tightest.resetsAt)}.` : "."}
            </div>
          )}
          {tightest && tightest.percent >= 75 && tightest.percent < 95 && (
            <div style={S.alertRed} className="animate-fade-in">
              {tightest.shortTitle} at {Math.round(tightest.percent)}%
              {tightest.resetsAt ? ` — resets in ${timeUntil(tightest.resetsAt)}` : ""}
            </div>
          )}
          {tightest && tightest.percent >= 50 && tightest.percent < 75 && (
            <div style={S.alertYellow} className="animate-fade-in">
              {tightest.shortTitle} at {Math.round(tightest.percent)}% — pace yourself
            </div>
          )}

          {/* Velocity. Shown only when there is enough history to mean something. */}
          {session && (
            <div className="animate-fade-in" style={{ ...S.card, display: "flex", justifyContent: "space-between", alignItems: "center", padding: "18px 22px" }}>
              <div>
                <div style={{ fontSize: 13, fontWeight: 600, color: "#f5f5f7", display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="glow-dot" style={{ color: sessionRate?.perHour > 20 ? "#fb7185" : "#7dd3fc" }} />
                  Usage Velocity
                </div>
                <div style={{ fontSize: 12, color: "#a1a1aa", marginTop: 6 }}>
                  {!sessionRate || sessionRate.perHour <= 0.01
                    ? "Not enough data yet — collecting samples"
                    : sessionProjection?.willExhaustBeforeReset
                      ? `Session hits 100% in ~${formatMs(sessionProjection.msToExhaustion)}, before it resets`
                      : sessionProjection?.projectedAtReset != null
                        ? `Projected ${Math.round(Math.min(sessionProjection.projectedAtReset, 999))}% at reset`
                        : "Actively consuming quota"}
                </div>
              </div>
              <div style={{ textAlign: "right" }}>
                <div style={{ fontSize: 17, fontWeight: 600, color: sessionRate?.perHour > 20 ? "#fb7185" : "#f5f5f7", fontFamily: "'JetBrains Mono', monospace", letterSpacing: "-0.01em" }}>
                  {sessionRate && sessionRate.perHour > 0.01 ? `+${sessionRate.perHour.toFixed(1)}%` : "—"}
                </div>
                <div style={{ fontSize: 10, color: "#71717a", marginTop: 2, fontFamily: "'JetBrains Mono', monospace" }}>per hour</div>
              </div>
            </div>
          )}

          {/* Every limit the API reported, including model-scoped ones. */}
          <div style={S.card} className="animate-fade-in">
            <h3 style={S.secT}>Rate Limit Details</h3>
            <div style={S.detailGrid}>
              {snapshot.limits.map((l, i) => (
                <DetailRow
                  key={l.id}
                  label={l.title}
                  value={l.percent}
                  resetAt={l.resetsAt}
                  color={LIMIT_COLORS[i % LIMIT_COLORS.length]}
                  badge={l.isActive ? "active" : null}
                />
              ))}
            </div>
            {scoped.length === 0 && (
              <div style={{ fontSize: 11, color: "#71717a", marginTop: 12 }}>
                No model-specific limits reported for this account.
              </div>
            )}
          </div>

          {spend && (
            <div style={S.card} className="animate-fade-in">
              <h3 style={S.secT}>Extra Usage</h3>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 12 }}>
                <div>
                  {/* Amounts are minor units scaled by the exponent the API sent. */}
                  <div style={{ fontSize: 22, fontWeight: 500, color: "#f5f5f7", fontFamily: "'Inter', sans-serif", letterSpacing: "-0.02em" }}>
                    {formatMoney(spend.used)}
                  </div>
                  <div style={{ fontSize: 11, color: "#a1a1aa", marginTop: 4 }}>
                    of {formatMoney(spend.limit)} monthly cap
                    {disabledExplanation(spend) ? ` · ${disabledExplanation(spend)}` : ""}
                  </div>
                </div>
                {spend.overage ? (
                  <div style={{ padding: "6px 12px", borderRadius: 999, background: "rgba(251, 113, 133, 0.12)", border: "1px solid rgba(251, 113, 133, 0.3)", color: "#fecdd3", fontSize: 11, fontWeight: 600 }}>
                    Over by {formatMoney(spend.overage)}
                  </div>
                ) : (
                  <div style={{ padding: "6px 12px", borderRadius: 999, background: "rgba(110, 231, 183, 0.08)", border: "1px solid rgba(110, 231, 183, 0.22)", color: "#a7f3d0", fontSize: 11, fontWeight: 600 }}>
                    {spend.enabled ? "Within cap" : "Disabled"}
                  </div>
                )}
              </div>
              {spend.percent != null && (
                <div style={{ marginTop: 14, height: 6, borderRadius: 999, background: "rgba(255,255,255,0.06)", overflow: "hidden" }}>
                  <div style={{
                    height: "100%",
                    width: `${Math.min(100, spend.percent)}%`,
                    background: spend.overage ? "linear-gradient(90deg, #fb7185, #f472b6)" : "linear-gradient(90deg, #7dd3fc, #c4b5fd)",
                    transition: "width 0.9s cubic-bezier(0.16, 1, 0.3, 1)",
                    boxShadow: spend.overage ? "0 0 12px rgba(251, 113, 133, 0.5)" : "0 0 12px rgba(125, 211, 252, 0.4)",
                  }} />
                </div>
              )}
              {spend.disclaimer && (
                <div style={{ fontSize: 10, color: "#52525b", marginTop: 10, lineHeight: 1.5 }}>{spend.disclaimer}</div>
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
                    <Tooltip contentStyle={tooltipStyle} />
                    <Area type="monotone" dataKey="session" stroke="#7dd3fc" strokeWidth={2} fill="url(#gsMini)" dot={{ r: 2, fill: "#7dd3fc" }} name="Session %" />
                    <Area type="monotone" dataKey="weekly" stroke="#c4b5fd" strokeWidth={1.5} fill="none" dot={{ r: 1.5, fill: "#c4b5fd" }} name="Weekly %" strokeDasharray="4 3" />
                    {scoped[0] && <Area type="monotone" dataKey="model" stroke="#fcd34d" strokeWidth={1.5} fill="none" dot={{ r: 1.5, fill: "#fcd34d" }} name={`${scoped[0].shortTitle} %`} strokeDasharray="2 3" />}
                  </AreaChart>
                </ResponsiveContainer>
              </div>
            </div>
          )}

          {snapshot.schemaWarnings.length > 0 && (
            <div style={{ ...S.card, padding: "14px 22px" }} className="animate-fade-in">
              <h3 style={{ ...S.secT, margin: "0 0 8px" }}>Schema Notes</h3>
              {snapshot.schemaWarnings.map((w) => (
                <div key={w} style={{ fontSize: 11, color: "#71717a", lineHeight: 1.6 }}>• {w}</div>
              ))}
            </div>
          )}
        </>
      )}

      {view === "chart" && (
        <>
          {chartData.length > 1 ? (
            <>
              <div style={S.card} className="animate-fade-in">
                <h3 style={S.secT}>Utilization Over Time</h3>
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
                      <Tooltip contentStyle={tooltipStyle} />
                      <Area type="monotone" dataKey="session" stroke="#7dd3fc" strokeWidth={2.2} fill="url(#gsFull)" dot={{ r: 3, fill: "#7dd3fc" }} name="Session %" />
                      <Area type="monotone" dataKey="weekly" stroke="#c4b5fd" strokeWidth={2} fill="none" dot={{ r: 2.5, fill: "#c4b5fd" }} name="Weekly %" strokeDasharray="5 3" />
                      {scoped[0] && <Area type="monotone" dataKey="model" stroke="#fcd34d" strokeWidth={2} fill="none" dot={{ r: 2.5, fill: "#fcd34d" }} name={`${scoped[0].shortTitle} %`} strokeDasharray="3 3" />}
                    </AreaChart>
                  </ResponsiveContainer>
                </div>
                <div style={{ display: "flex", gap: 18, justifyContent: "center", marginTop: 12, flexWrap: "wrap" }}>
                  <span style={S.leg}><span style={{ width: 8, height: 8, borderRadius: 99, background: "#7dd3fc", display: "inline-block", boxShadow: "0 0 8px #7dd3fc" }} /> Session (5h)</span>
                  <span style={S.leg}><span style={{ width: 12, height: 2, background: "#c4b5fd", display: "inline-block", boxShadow: "0 0 6px #c4b5fd" }} /> Weekly (7d)</span>
                  {scoped[0] && <span style={S.leg}><span style={{ width: 12, height: 2, background: "#fcd34d", display: "inline-block", boxShadow: "0 0 6px #fcd34d" }} /> {scoped[0].shortTitle}</span>}
                </div>
              </div>

              <div style={S.card} className="animate-fade-in">
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 14 }}>
                  <h3 style={{ ...S.secT, margin: 0 }}>Poll Log ({history.length})</h3>
                  <button
                    onClick={downloadHistoryCsv}
                    style={{ background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.1)", borderRadius: 8, color: "#d4d4d8", cursor: "pointer", fontSize: 11, padding: "5px 12px", fontFamily: "inherit", fontWeight: 500, transition: "background 0.2s, border-color 0.2s" }}
                    onMouseOver={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.08)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.18)"; }}
                    onMouseOut={(e) => { e.currentTarget.style.background = "rgba(255,255,255,0.04)"; e.currentTarget.style.borderColor = "rgba(255,255,255,0.1)"; }}
                  >
                    Export CSV
                  </button>
                </div>
                <div style={{ maxHeight: 280, overflow: "auto", paddingRight: 4 }}>
                  {history.slice(0, 60).map((h, i) => (
                    <div key={`${h.ts}-${i}`} style={{ display: "flex", alignItems: "center", gap: 12, padding: "8px 0", borderBottom: "1px solid rgba(255,255,255,0.04)", fontSize: 11, fontFamily: "'JetBrains Mono', monospace" }}>
                      <span style={{ color: "#71717a", minWidth: 62 }}>
                        {new Date(h.ts).toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: true })}
                      </span>
                      {snapshot?.limits.slice(0, 3).map((l, idx) => (
                        <span key={l.id} style={{ color: LIMIT_COLORS[idx % LIMIT_COLORS.length], fontWeight: 600, minWidth: 62 }}>
                          {l.shortTitle.slice(0, 4)} {typeof h.limits?.[l.id] === "number" ? Math.round(h.limits[l.id]) : "—"}%
                        </span>
                      ))}
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
        Auto-refreshes every {POLL_INTERVAL_SEC}s · Data stays in this browser
      </div>
    </div>
  );
}

const tooltipStyle = {
  background: "rgba(10, 12, 20, 0.85)",
  backdropFilter: "blur(16px)",
  border: "1px solid rgba(255,255,255,0.12)",
  borderRadius: 10,
  color: "#f5f5f7",
  fontSize: 11,
  boxShadow: "0 8px 24px rgba(0,0,0,0.5)",
};

function round(v) {
  return typeof v === "number" ? Math.round(v) : null;
}

/** "just now" / "4m ago" — `timeUntil` returns "now" for a past date, which reads oddly. */
function relativeAge(date) {
  const seconds = Math.max(0, (Date.now() - date.getTime()) / 1000);
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h ${m}m ago` : `${h}h ago`;
}

function formatMs(ms) {
  if (ms == null) return "—";
  const minutes = Math.round(ms / 60000);
  if (minutes < 60) return `${minutes}m`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m > 0 ? `${h}h ${m}m` : `${h}h`;
}

function ConnectScreen({ token, setToken, saveToken, copied, setCopied }) {
  const command = `security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['claudeAiOauth']['accessToken'])"`;
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
            style={{ width: "100%", background: "rgba(0, 0, 0, 0.25)", border: "1px solid rgba(255, 255, 255, 0.08)", borderRadius: 12, padding: "12px 14px", color: "#f5f5f7", fontSize: 12, fontFamily: "'JetBrains Mono', monospace", outline: "none", resize: "none", transition: "border 0.2s, background 0.2s", boxSizing: "border-box", marginBottom: 14 }}
            onFocus={(e) => { e.target.style.borderColor = "rgba(125, 211, 252, 0.4)"; e.target.style.background = "rgba(0,0,0,0.35)"; }}
            onBlur={(e) => { e.target.style.borderColor = "rgba(255, 255, 255, 0.08)"; e.target.style.background = "rgba(0,0,0,0.25)"; }}
            rows={3}
          />
          <button
            onClick={saveToken}
            style={{ width: "100%", background: token.trim() ? "linear-gradient(135deg, #f5f5f7, #e4e4e7)" : "rgba(255, 255, 255, 0.04)", color: token.trim() ? "#0a0a0f" : "#52525b", border: "1px solid rgba(255, 255, 255, 0.12)", borderRadius: 12, padding: "11px 0", fontSize: 13, fontWeight: 600, cursor: token.trim() ? "pointer" : "not-allowed", transition: "all 0.2s", boxShadow: token.trim() ? "0 8px 24px rgba(255, 255, 255, 0.06)" : "none" }}
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
              style={{ position: "relative", background: "rgba(0, 0, 0, 0.3)", border: "1px solid rgba(255, 255, 255, 0.06)", borderRadius: 10, padding: "12px", paddingRight: 36, cursor: "pointer", transition: "border 0.2s, background 0.2s" }}
              onClick={() => {
                navigator.clipboard.writeText(command);
                setCopied(true);
                setTimeout(() => setCopied(false), 2000);
              }}
              onMouseOver={(e) => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.14)"; }}
              onMouseOut={(e) => { e.currentTarget.style.borderColor = "rgba(255,255,255,0.06)"; }}
              title="Click to copy"
            >
              <div style={{ fontSize: 11, color: "#d4d4d8", fontFamily: "'JetBrains Mono', monospace", wordBreak: "break-all", lineHeight: 1.5 }}>
                {command}
              </div>
              <div style={{ position: "absolute", right: 12, top: 12, color: copied ? "#6ee7b7" : "#71717a", transition: "color 0.2s" }}>
                {copied ? (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
                ) : (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                )}
              </div>
            </div>
            <p style={{ margin: "14px 0 0 0", fontSize: 11, color: "#71717a" }}>
              Prefer not to paste a token in a browser? The native macOS menu bar app in <code>macos/</code> reads the same credential straight from your keychain.
            </p>
          </div>
        </div>

        <div style={{ textAlign: "center", marginTop: 20, fontSize: 11, color: "#71717a" }}>
          100% client-side · Token stays in your browser
        </div>
      </div>
    </div>
  );
}
