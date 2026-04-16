export function Gauge({ value, label, sub, size = 150 }) {
  const v = value ?? 0;
  const center = size / 2;
  const ringWidth = 6;
  const ringR = center - 14;
  const c = 2 * Math.PI * ringR;
  const off = c - (v / 100) * c;

  const isCritical = v >= 80;
  const isWarn = v >= 50;
  const gradId = `g-${label?.replace(/\s/g, "") || "x"}-${Math.round(v)}`;
  const arcColor = isCritical ? "#fb7185" : isWarn ? "#fbbf24" : "#7dd3fc";
  const arcColor2 = isCritical ? "#f472b6" : isWarn ? "#fde68a" : "#c4b5fd";

  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10 }}>
      <div style={{ position: "relative", width: size, height: size }}>
        <svg viewBox={`0 0 ${size} ${size}`} width={size} height={size}>
          <defs>
            <linearGradient id={gradId} x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stopColor={arcColor} />
              <stop offset="100%" stopColor={arcColor2} />
            </linearGradient>
            <filter id={`glow-${gradId}`} x="-50%" y="-50%" width="200%" height="200%">
              <feGaussianBlur stdDeviation="3" result="blur" />
              <feMerge>
                <feMergeNode in="blur" />
                <feMergeNode in="SourceGraphic" />
              </feMerge>
            </filter>
          </defs>
          <circle cx={center} cy={center} r={center - 3} fill="none" stroke="rgba(255,255,255,0.04)" strokeWidth={1} />
          <circle cx={center} cy={center} r={ringR} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth={ringWidth} />
          <circle
            cx={center} cy={center} r={ringR}
            fill="none" stroke={`url(#${gradId})`} strokeWidth={ringWidth}
            strokeDasharray={c} strokeDashoffset={off}
            strokeLinecap="round"
            transform={`rotate(-90 ${center} ${center})`}
            filter={`url(#glow-${gradId})`}
            className={isCritical ? "gauge-arc-critical" : ""}
            style={{ color: arcColor, transition: "stroke-dashoffset 1.2s cubic-bezier(0.4, 0, 0.2, 1), stroke 0.6s" }}
          />
        </svg>
        <div style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          pointerEvents: "none",
        }}>
          <span style={{
            fontSize: 44,
            fontWeight: 300,
            color: "#f5f5f7",
            letterSpacing: "-0.045em",
            lineHeight: 1,
            fontFamily: "'Inter', sans-serif",
          }}>
            {v}
            <span style={{
              fontSize: 18,
              fontWeight: 400,
              color: "rgba(255,255,255,0.4)",
              marginLeft: 2,
              letterSpacing: 0,
            }}>%</span>
          </span>
        </div>
      </div>
      <span style={{
        fontSize: 10,
        fontWeight: 600,
        color: "#a1a1aa",
        textTransform: "uppercase",
        letterSpacing: "0.14em",
      }}>
        {label}
      </span>
      {sub && (
        <span style={{
          fontSize: 11,
          color: "#71717a",
          textAlign: "center",
          maxWidth: size + 40,
          lineHeight: 1.35,
          fontFamily: "'JetBrains Mono', monospace",
          marginTop: -2,
        }}>
          {sub}
        </span>
      )}
    </div>
  );
}
