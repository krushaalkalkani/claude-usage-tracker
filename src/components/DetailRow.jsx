import { timeUntil } from "../utils/time";

export function DetailRow({ label, value, resetAt, color }) {
  const v = value != null ? Math.round(value) : null;
  if (v === null) return null;
  
  const isCritical = v >= 80;
  const isWarn = v >= 50;
  
  let barCol = color;
  if (isCritical) barCol = "#ef4444";
  else if (isWarn) barCol = "#f59e0b";

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 0", borderBottom: "1px solid #222" }}>
      <span style={{ fontSize: 13, color: "#a1a1aa", minWidth: 115, fontWeight: 500 }}>{label}</span>
      <div style={{ flex: 1, display: "flex", alignItems: "center", gap: 10 }}>
        <div style={{ flex: 1, height: 4, borderRadius: 2, background: "#222", overflow: "hidden" }}>
          <div style={{ height: "100%", background: barCol, width: `${v}%`, transition: "width 0.8s cubic-bezier(0.16, 1, 0.3, 1)" }} />
        </div>
        <span style={{ fontSize: 13, fontWeight: 600, color: isCritical ? "#ef4444" : "#ededed", minWidth: 42, textAlign: "right" }}>{v}%</span>
      </div>
      {resetAt && <span style={{ fontSize: 11, color: "#666", whiteSpace: "nowrap", fontFamily: "'JetBrains Mono', monospace" }}>↻ {timeUntil(resetAt)}</span>}
    </div>
  );
}
