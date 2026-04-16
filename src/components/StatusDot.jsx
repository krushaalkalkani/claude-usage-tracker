export function StatusDot({ connected }) {
  const color = connected ? "#6ee7b7" : "#fb7185";
  return (
    <span style={{
      width: 8,
      height: 8,
      borderRadius: 99,
      background: color,
      display: "inline-block",
      boxShadow: `0 0 10px ${color}, 0 0 2px ${color}`,
      animation: connected ? "floatPulse 2.4s ease-in-out infinite" : "none",
    }} />
  );
}
