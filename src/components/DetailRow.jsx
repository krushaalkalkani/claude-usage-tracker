import { timeUntil } from "../utils/time";

export function DetailRow({ label, value, resetAt, color, badge }) {
  const v = value != null ? Math.round(value) : null;
  if (v === null) return null;

  const isCritical = v >= 80;
  const isWarn = v >= 50;

  const barStart = isCritical ? "#fb7185" : isWarn ? "#fbbf24" : color;
  const barEnd = isCritical ? "#f472b6" : isWarn ? "#fde68a" : lighten(color);

  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14, padding: "14px 0", borderBottom: "1px solid rgba(255,255,255,0.05)" }}>
      <span style={{ fontSize: 13, color: "#d4d4d8", minWidth: 120, fontWeight: 500, display: "flex", alignItems: "center", gap: 6 }}>
        {label}
        {badge && (
          <span style={{
            fontSize: 9,
            fontWeight: 700,
            letterSpacing: "0.06em",
            textTransform: "uppercase",
            padding: "2px 6px",
            borderRadius: 999,
            background: "rgba(125, 211, 252, 0.14)",
            border: "1px solid rgba(125, 211, 252, 0.3)",
            color: "#7dd3fc",
          }}>
            {badge}
          </span>
        )}
      </span>
      <div style={{ flex: 1, display: "flex", alignItems: "center", gap: 12 }}>
        <div style={{ flex: 1, height: 6, borderRadius: 999, background: "rgba(255,255,255,0.06)", overflow: "hidden", boxShadow: "inset 0 1px 2px rgba(0,0,0,0.3)" }}>
          <div style={{
            height: "100%",
            background: `linear-gradient(90deg, ${barStart}, ${barEnd})`,
            width: `${v}%`,
            transition: "width 0.9s cubic-bezier(0.16, 1, 0.3, 1)",
            boxShadow: `0 0 12px ${barStart}66`,
          }} />
        </div>
        <span style={{ fontSize: 13, fontWeight: 600, color: isCritical ? "#fb7185" : "#f5f5f7", minWidth: 42, textAlign: "right", fontFamily: "'Inter', sans-serif" }}>{v}%</span>
      </div>
      {resetAt && (
        <span style={{ fontSize: 10, color: "#71717a", whiteSpace: "nowrap", fontFamily: "'JetBrains Mono', monospace", letterSpacing: "0.02em" }}>
          ↻ {timeUntil(resetAt)}
        </span>
      )}
    </div>
  );
}

function lighten(hex) {
  if (!hex || hex[0] !== "#") return hex;
  const n = parseInt(hex.slice(1), 16);
  const r = Math.min(255, ((n >> 16) & 0xff) + 40);
  const g = Math.min(255, ((n >> 8) & 0xff) + 40);
  const b = Math.min(255, (n & 0xff) + 40);
  return `rgb(${r}, ${g}, ${b})`;
}
