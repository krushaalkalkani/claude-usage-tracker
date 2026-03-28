export const S = {
  wrap: { 
    fontFamily: "'Inter', sans-serif", 
    minHeight: "100vh", 
    color: "#ededed", 
    padding: "40px 16px", 
    maxWidth: 580, 
    margin: "0 auto",
    display: "flex",
    flexDirection: "column",
  },
  head: { 
    display: "flex", 
    justifyContent: "space-between", 
    alignItems: "center", 
    marginBottom: 32, 
    flexWrap: "wrap", 
    gap: 12 
  },
  logo: { 
    width: 48, 
    height: 48, 
    borderRadius: 8, 
    background: "#fff", 
    display: "flex", 
    alignItems: "center", 
    justifyContent: "center", 
    fontSize: 24, 
    fontWeight: 800, 
    color: "#000", 
    margin: "0 auto 16px"
  },
  logoSm: { 
    width: 32, 
    height: 32, 
    borderRadius: 6, 
    background: "#fff", 
    display: "flex", 
    alignItems: "center", 
    justifyContent: "center", 
    fontSize: 15, 
    fontWeight: 800, 
    color: "#000", 
    flexShrink: 0
  },
  tab: { 
    padding: "6px 12px", 
    borderRadius: 6, 
    border: "1px solid transparent", 
    background: "transparent", 
    color: "#888", 
    fontSize: 13, 
    fontWeight: 500,
    cursor: "pointer", 
    fontFamily: "inherit",
    transition: "all 0.1s"
  },
  tabA: { 
    background: "#111", 
    color: "#ededed", 
    borderColor: "#333" 
  },
  card: { 
    background: "#0a0a0a", 
    borderRadius: 8, 
    padding: 24, 
    marginBottom: 16, 
    border: "1px solid #222", 
    position: "relative" 
  },
  secT: { 
    fontSize: 11, 
    fontWeight: 600, 
    color: "#888", 
    margin: "0 0 16px", 
    textTransform: "uppercase", 
    letterSpacing: "0.06em" 
  },
  detailGrid: { display: "flex", flexDirection: "column" },
  alertRed: { 
    padding: "12px 16px", 
    borderRadius: 6, 
    border: "1px solid #ef444433", 
    fontSize: 13, 
    fontWeight: 500,
    marginBottom: 16, 
    color: "#fca5a5", 
    background: "#ef444411" 
  },
  alertYellow: { 
    padding: "12px 16px", 
    borderRadius: 6, 
    border: "1px solid #f59e0b33", 
    fontSize: 13, 
    fontWeight: 500,
    marginBottom: 16, 
    color: "#fcd34d", 
    background: "#f59e0b11" 
  },
  primaryBtn: { 
    padding: "12px 24px", 
    borderRadius: 6, 
    border: "1px solid #fff", 
    background: "#fff", 
    color: "#000", 
    fontSize: 14, 
    fontWeight: 600, 
    cursor: "pointer", 
    fontFamily: "inherit", 
    transition: "transform 0.1s, opacity 0.2s"
  },
  ghostBtn: { 
    padding: "12px 24px", 
    borderRadius: 6, 
    border: "1px solid #333", 
    background: "transparent", 
    color: "#ededed", 
    fontSize: 13, 
    fontWeight: 500,
    cursor: "pointer", 
    fontFamily: "inherit",
    transition: "background 0.2s, color 0.2s"
  },
  stepNum: { 
    width: 24, 
    height: 24, 
    borderRadius: "50%", 
    background: "#222", 
    color: "#fff", 
    border: "1px solid #444",
    display: "flex", 
    alignItems: "center", 
    justifyContent: "center", 
    fontSize: 12, 
    fontWeight: 600, 
    marginBottom: 12 
  },
  stepText: { 
    fontSize: 14, 
    color: "#a1a1aa", 
    margin: "0 0 12px", 
    lineHeight: 1.5,
    fontWeight: 400
  },
  codeBlock: { 
    background: "#111", 
    borderRadius: 6, 
    padding: 12, 
    border: "1px solid #333", 
    fontFamily: "'JetBrains Mono', monospace", 
    fontSize: 12, 
    overflowX: "auto", 
    userSelect: "all", 
    cursor: "text" 
  },
  tokenInput: { 
    width: "100%", 
    padding: "12px 16px", 
    borderRadius: 6, 
    border: "1px solid #333", 
    background: "#000", 
    color: "#ededed", 
    fontSize: 14, 
    fontFamily: "'JetBrains Mono', monospace", 
    outline: "none", 
    boxSizing: "border-box", 
    resize: "none",
    transition: "border-color 0.1s"
  },
  leg: { 
    display: "flex", 
    alignItems: "center", 
    gap: 6, 
    fontSize: 12, 
    color: "#888",
    fontWeight: 500 
  },
};
