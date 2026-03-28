export function Gauge({ value, label, sub, size = 140 }) {
  const v = value ?? 0;
  const outerR = size / 2;
  const ringWidth = 7;
  const gap = 14;
  const ringR = outerR - gap - ringWidth / 2;
  const c = 2 * Math.PI * ringR;
  const off = c - (v / 100) * c;

  const isCritical = v >= 90;
  const arcColor = v >= 80 ? "#ef4444" : v >= 50 ? "#f59e0b" : "#3b82f6";
  const bgColor = v >= 80 ? "rgba(239,68,68,0.10)" : v >= 50 ? "rgba(245,158,11,0.08)" : "rgba(59,130,246,0.08)";

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10 }}>
      <div style={{ position: "relative", width: size, height: size }}>
        <svg fill="none" viewBox={`0 0 ${size} ${size}`} width={size} height={size} style={{ overflow: "visible" }}>
          {/* Outer filled circle background */}
          <circle cx={outerR} cy={outerR} r={outerR - 1} fill={bgColor} stroke="rgba(255,255,255,0.04)" strokeWidth={1} />
          {/* Inner ring track */}
          <circle cx={outerR} cy={outerR} r={ringR} stroke="rgba(255,255,255,0.06)" strokeWidth={ringWidth} fill="none" />
          {/* Inner ring progress arc */}
          <circle cx={outerR} cy={outerR} r={ringR} stroke={arcColor} strokeWidth={ringWidth}
            strokeDasharray={c} strokeDashoffset={off} strokeLinecap="round" fill="none"
            transform={`rotate(-90 ${outerR} ${outerR})`}
            style={{ transition: "stroke-dashoffset 1s cubic-bezier(0.4, 0, 0.2, 1), stroke 0.4s" }} />
        </svg>
        {/* Center text */}
        <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", pointerEvents: "none" }}>
          <span style={{ fontSize: 30, fontWeight: 300, color: isCritical ? "#f8fafc" : "#e2e8f0", letterSpacing: "-0.04em", lineHeight: 1 }}>
            {v}<span style={{ fontSize: 16, color: "rgba(255,255,255,0.35)" }}>%</span>
          </span>
          <span style={{ fontSize: 10, fontWeight: 500, color: "#71717a", marginTop: 4, textTransform: "uppercase", letterSpacing: "0.05em" }}>{label}</span>
        </div>
      </div>
      {sub && <span style={{ fontSize: 11, color: "#52525b", textAlign: "center", maxWidth: size, lineHeight: 1.3 }}>{sub}</span>}
    </div>
  );
}
