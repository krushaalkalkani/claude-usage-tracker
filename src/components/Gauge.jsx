export function Gauge({ value, label, sub, size = 140 }) {
  const sw = 6, r = (size - sw) / 2, c = 2 * Math.PI * r;
  const v = value ?? 0;
  const off = c - (v / 100) * c;
  
  const isCritical = v >= 90;
  const strokeColor = v >= 80 ? "#ef4444" : v >= 50 ? "#f59e0b" : "#e2e8f0";

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 12 }}>
      <div style={{ position: "relative", width: size, height: size }}>
        <svg fill="none" viewBox={`0 0 ${size} ${size}`} width={size} height={size} style={{ transform: "rotate(-90deg)", overflow: "visible" }}>
          {/* Background track */}
          <circle cx={size/2} cy={size/2} r={r} stroke="rgba(255,255,255,0.06)" strokeWidth={sw} />
          {/* Progress track */}
          <circle cx={size/2} cy={size/2} r={r} stroke={strokeColor} strokeWidth={sw}
            strokeDasharray={c} strokeDashoffset={off} strokeLinecap="round"
            style={{ transition: "stroke-dashoffset 1s cubic-bezier(0.4, 0, 0.2, 1)" }} />
        </svg>
        <div style={{ position: "absolute", inset: 0, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center" }}>
          <span style={{ fontSize: 32, fontWeight: 300, color: isCritical ? "#f8fafc" : "#e2e8f0", letterSpacing: "-0.04em" }}>{v}<span style={{fontSize: 18, color: "rgba(255,255,255,0.4)"}}>%</span></span>
        </div>
      </div>
      <div style={{ textAlign: "center", fontFamily: "'Inter', sans-serif" }}>
        <span style={{ display: "block", fontSize: 13, fontWeight: 500, color: "#f8fafc" }}>{label}</span>
        {sub && <span style={{ display: "block", fontSize: 12, color: "#64748b", marginTop: 4, maxWidth: size, lineHeight: 1.3 }}>{sub}</span>}
      </div>
    </div>
  );
}
