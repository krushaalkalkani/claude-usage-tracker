export function Gauge({ value, label, sub, size = 130 }) {
  const v = value ?? 0;
  const center = size / 2;
  const ringWidth = 5;
  const ringR = center - 16;
  const c = 2 * Math.PI * ringR;
  const off = c - (v / 100) * c;

  const isCritical = v >= 80;
  const isWarn = v >= 50;
  const arcColor = isCritical ? "#ef4444" : isWarn ? "#f59e0b" : "#3b82f6";

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
      <div style={{ position: "relative", width: size, height: size }}>
        <svg viewBox={`0 0 ${size} ${size}`} width={size} height={size}>
          {/* Subtle outer ring */}
          <circle cx={center} cy={center} r={center - 4} fill="none" stroke="rgba(255,255,255,0.03)" strokeWidth={1} />
          {/* Track */}
          <circle cx={center} cy={center} r={ringR} fill="none" stroke="rgba(255,255,255,0.06)" strokeWidth={ringWidth} />
          {/* Arc */}
          <circle
            cx={center} cy={center} r={ringR}
            fill="none" stroke={arcColor} strokeWidth={ringWidth}
            strokeDasharray={c} strokeDashoffset={off}
            strokeLinecap="round"
            transform={`rotate(-90 ${center} ${center})`}
            className={isCritical ? "gauge-arc-critical" : ""}
            style={{ color: arcColor, transition: "stroke-dashoffset 1.2s cubic-bezier(0.4, 0, 0.2, 1), stroke 0.6s" }}
          />
          {/* Glow effect for progress */}
          <circle
            cx={center} cy={center} r={ringR}
            fill="none" stroke={arcColor} strokeWidth={ringWidth + 6}
            strokeDasharray={c} strokeDashoffset={off}
            strokeLinecap="round" opacity={0.08}
            transform={`rotate(-90 ${center} ${center})`}
            style={{ transition: "stroke-dashoffset 1.2s cubic-bezier(0.4, 0, 0.2, 1)" }}
          />
        </svg>
        <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", pointerEvents: "none" }}>
          <span style={{ fontSize: 28, fontWeight: 200, color: "#f0f0f0", letterSpacing: "-0.03em", lineHeight: 1, fontFamily: "'Inter', sans-serif" }}>
            {v}<span style={{ fontSize: 14, fontWeight: 400, color: "rgba(255,255,255,0.25)" }}>%</span>
          </span>
          <span style={{ fontSize: 9, fontWeight: 600, color: "#555", marginTop: 5, textTransform: "uppercase", letterSpacing: "0.08em" }}>{label}</span>
        </div>
      </div>
      {sub && <span style={{ fontSize: 10, color: "#444", textAlign: "center", maxWidth: size, lineHeight: 1.3, fontFamily: "'JetBrains Mono', monospace" }}>{sub}</span>}
    </div>
  );
}
