export function StatusDot({ connected }) {
  return <span style={{
    width: 8, height: 8, borderRadius: 99,
    background: connected ? "#10b981" : "#ef4444",
    display: "inline-block",
    boxShadow: connected ? "0 0 6px #10b98166" : "0 0 6px #ef444466",
    animation: connected ? "pulse 2s infinite" : "none",
  }} />;
}
