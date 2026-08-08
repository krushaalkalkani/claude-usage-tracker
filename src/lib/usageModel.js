/**
 * Shared usage data model — the JavaScript twin of `macos/ClaudeUsage/Models/UsageSnapshot.swift`.
 *
 * The personal OAuth usage endpoint is internal to Anthropic and can change shape without
 * notice, so nothing here assumes a field exists. Missing fields become `null`; unknown ones
 * are preserved. The parser never throws on a well-formed JSON document.
 *
 * Keep this in sync with the Swift parser: same limit ids, same money handling, same
 * fallbacks. The ids in particular are what let history recorded by one client be read by
 * the other.
 */

/** @typedef {"normal"|"warning"|"critical"} Severity */

export function severityFrom(percent, warningAt = 75, criticalAt = 90) {
  if (percent >= criticalAt) return "critical";
  if (percent >= warningAt) return "warning";
  return "normal";
}

const SEVERITY_RANK = { normal: 0, warning: 1, critical: 2 };

export function worstSeverity(list) {
  return list.reduce(
    (worst, s) => (SEVERITY_RANK[s] > SEVERITY_RANK[worst] ? s : worst),
    "normal",
  );
}

/** Legacy top-level keys, used only when `limits[]` is absent or incomplete. */
const LEGACY_KEYS = [
  { key: "five_hour", kind: "session", group: "session", title: "5-hour limit", short: "Session" },
  { key: "seven_day", kind: "weekly_all", group: "weekly", title: "7-day limit", short: "Weekly" },
  { key: "seven_day_opus", kind: "weekly_scoped", group: "weekly", title: "Opus · 7-day", short: "Opus", model: "Opus" },
  { key: "seven_day_sonnet", kind: "weekly_scoped", group: "weekly", title: "Sonnet · 7-day", short: "Sonnet", model: "Sonnet" },
  { key: "seven_day_haiku", kind: "weekly_scoped", group: "weekly", title: "Haiku · 7-day", short: "Haiku", model: "Haiku" },
  { key: "seven_day_cowork", kind: "weekly_scoped", group: "weekly", title: "Cowork · 7-day", short: "Cowork", surface: "Cowork" },
  { key: "seven_day_oauth_apps", kind: "weekly_scoped", group: "weekly", title: "OAuth apps · 7-day", short: "OAuth apps", surface: "OAuth apps" },
];

function num(value) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function str(value) {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function clampPercent(p) {
  if (!Number.isFinite(p)) return 0;
  return Math.min(Math.max(p, 0), 1000);
}

/** A stable id shared with the Swift client. */
function identity(kind, model, modelId, surface) {
  const parts = [kind];
  if (modelId) parts.push(`m:${modelId}`);
  else if (model) parts.push(`m:${model.toLowerCase()}`);
  if (surface) parts.push(`s:${surface.toLowerCase()}`);
  return parts.join("|");
}

function inferGroup(kind) {
  if (kind.includes("session")) return "session";
  if (kind.includes("weekly") || kind.includes("seven_day")) return "weekly";
  return "other";
}

function titlesFor(kind, group, model, surface) {
  const period = group === "session" ? "5-hour" : group === "weekly" ? "7-day" : kind.replace(/_/g, " ");
  if (model) return [`${model} · ${period}`, model];
  if (surface) return [`${surface} · ${period}`, surface];
  if (group === "session") return ["5-hour limit", "Session"];
  if (group === "weekly") return ["7-day limit", "Weekly"];
  const pretty = kind.replace(/_/g, " ");
  return [pretty.charAt(0).toUpperCase() + pretty.slice(1), kind];
}

function parseLimitEntry(entry) {
  if (!entry || typeof entry !== "object") return null;
  const percent = num(entry.percent) ?? num(entry.utilization);
  if (percent === null) return null;

  const kind = str(entry.kind) || "unknown";
  const group = ["session", "weekly", "other"].includes(entry.group)
    ? entry.group
    : inferGroup(kind);

  const scope = entry.scope || null;
  const model = str(scope?.model?.display_name);
  const modelId = str(scope?.model?.id);
  const surface = str(scope?.surface) || str(scope?.surface?.display_name);

  const severity = ["normal", "warning", "critical"].includes(entry.severity)
    ? entry.severity
    : severityFrom(percent);

  const [title, shortTitle] = titlesFor(kind, group, model, surface);

  return {
    id: identity(kind, model, modelId, surface),
    kind,
    group,
    title,
    shortTitle,
    percent: clampPercent(percent),
    remainingPercent: Math.max(0, 100 - clampPercent(percent)),
    resetsAt: str(entry.resets_at),
    severity,
    isActive: entry.is_active === true,
    modelName: model,
    modelId,
    surface,
    isModelScoped: !!model,
    usedDollars: num(entry.used_dollars),
    limitDollars: num(entry.limit_dollars),
    remainingDollars: num(entry.remaining_dollars),
  };
}

/**
 * A money amount that respects the exponent the API sent.
 *
 * `extra_usage.used_credits: 3303` with `decimal_places: 2` is **$33.03**. v1 rendered it as
 * "$3303.00" — a 100x overstatement — by ignoring the exponent. Nothing here divides by a
 * hardcoded 100.
 */
export function money(amountMinor, currency = "USD", exponent = 2) {
  if (amountMinor === null || amountMinor === undefined) return null;
  const exp = Math.max(0, Math.min(Number(exponent) || 0, 6));
  return {
    amountMinor: Math.round(amountMinor),
    currency: currency || "USD",
    exponent: exp,
    amount: Math.round(amountMinor) / Math.pow(10, exp),
  };
}

export function formatMoney(m) {
  if (!m) return "—";
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: m.currency,
      minimumFractionDigits: m.exponent,
      maximumFractionDigits: m.exponent,
    }).format(m.amount);
  } catch {
    return `${m.amount.toFixed(m.exponent)} ${m.currency}`;
  }
}

function moneyFromNode(node) {
  if (!node || typeof node !== "object") return null;
  const minor = num(node.amount_minor);
  if (minor === null) return null;
  return money(minor, str(node.currency) || "USD", num(node.exponent) ?? 2);
}

function parseSpend(root) {
  const spendNode = root.spend && typeof root.spend === "object" ? root.spend : null;
  const extraNode = root.extra_usage && typeof root.extra_usage === "object" ? root.extra_usage : null;
  if (!spendNode && !extraNode) return null;

  // Prefer the modern `spend` object: it carries an explicit exponent per amount.
  let used = moneyFromNode(spendNode?.used);
  let limit = moneyFromNode(spendNode?.limit);

  if (!used || !limit) {
    const exponent = num(extraNode?.decimal_places) ?? 2;
    const currency = str(extraNode?.currency) || "USD";
    if (!used && num(extraNode?.used_credits) !== null) {
      used = money(num(extraNode.used_credits), currency, exponent);
    }
    if (!limit && num(extraNode?.monthly_limit) !== null) {
      limit = money(num(extraNode.monthly_limit), currency, exponent);
    }
  }

  const percent =
    num(spendNode?.percent) ??
    num(extraNode?.utilization) ??
    (used && limit && limit.amount > 0 ? (used.amount / limit.amount) * 100 : null);

  const enabled = spendNode?.enabled ?? extraNode?.is_enabled ?? false;

  const severity = ["normal", "warning", "critical"].includes(spendNode?.severity)
    ? spendNode.severity
    : percent !== null
      ? severityFrom(percent)
      : "normal";

  const overage =
    used && limit && used.amountMinor > limit.amountMinor && used.exponent === limit.exponent
      ? money(used.amountMinor - limit.amountMinor, used.currency, used.exponent)
      : null;

  const info = {
    enabled: !!enabled,
    used,
    limit,
    percent,
    severity,
    overage,
    disabledReason: str(spendNode?.disabled_reason) || str(extraNode?.disabled_reason),
    userDisabled: extraNode?.user_disabled ?? null,
    limitReached: extraNode?.spend_limit_reached ?? null,
    everEnabled: extraNode?.credits_ever_enabled ?? null,
    balance: moneyFromNode(spendNode?.balance),
    disclaimer: str(spendNode?.disclaimer),
  };

  const presentable = info.enabled || info.everEnabled || info.used || info.limit;
  return presentable ? info : null;
}

const DISABLED_REASONS = {
  org_level_disabled_until: "Disabled by organization",
  user_disabled: "Turned off",
  spend_limit_reached: "Monthly cap reached",
};

export function disabledExplanation(spend) {
  if (!spend || spend.enabled || !spend.disabledReason) return null;
  const known = DISABLED_REASONS[spend.disabledReason];
  if (known) return known;
  const pretty = spend.disabledReason.replace(/_/g, " ");
  return pretty.charAt(0).toUpperCase() + pretty.slice(1);
}

/** Session first, then account-wide weekly, then scoped windows by utilisation. */
function displayRank(limit) {
  if (limit.group === "session") return 0;
  if (limit.group === "weekly" && !limit.isModelScoped && !limit.surface) return 1;
  if (limit.isModelScoped) return 2;
  return 3;
}

/**
 * Normalizes one `/api/oauth/usage` response.
 * @param {unknown} raw
 * @returns {{limits: Array, spend: object|null, schemaWarnings: string[], raw: unknown}}
 */
export function parseUsage(raw) {
  const warnings = [];
  const limits = [];
  const seen = new Set();

  if (!raw || typeof raw !== "object") {
    return { limits: [], spend: null, schemaWarnings: ["response was not an object"], raw };
  }

  // 1. The modern shape wins.
  if (Array.isArray(raw.limits)) {
    for (const entry of raw.limits) {
      const parsed = parseLimitEntry(entry);
      if (parsed && !seen.has(parsed.id)) {
        seen.add(parsed.id);
        limits.push(parsed);
      }
    }
    if (limits.length === 0 && raw.limits.length > 0) {
      warnings.push("limits[] present but no entry could be read");
    }
  } else {
    warnings.push("limits[] missing — falling back to legacy top-level keys");
  }

  // 2. Legacy keys fill gaps only.
  for (const spec of LEGACY_KEYS) {
    const node = raw[spec.key];
    if (!node || typeof node !== "object") continue;
    const percent = num(node.utilization);
    if (percent === null) continue;
    const id = identity(spec.kind, spec.model, null, spec.surface);
    if (seen.has(id)) continue;
    seen.add(id);
    limits.push({
      id,
      kind: spec.kind,
      group: spec.group,
      title: spec.title,
      shortTitle: spec.short,
      percent: clampPercent(percent),
      remainingPercent: Math.max(0, 100 - clampPercent(percent)),
      resetsAt: str(node.resets_at),
      severity: severityFrom(percent),
      isActive: false,
      modelName: spec.model ?? null,
      modelId: null,
      surface: spec.surface ?? null,
      isModelScoped: !!spec.model,
      usedDollars: num(node.used_dollars),
      limitDollars: num(node.limit_dollars),
      remainingDollars: num(node.remaining_dollars),
    });
  }

  if (limits.length === 0) warnings.push("no usage limits found in response");

  limits.sort((a, b) => {
    const ra = displayRank(a);
    const rb = displayRank(b);
    if (ra !== rb) return ra - rb;
    if (a.percent !== b.percent) return b.percent - a.percent;
    return a.id.localeCompare(b.id);
  });

  return { limits, spend: parseSpend(raw), schemaWarnings: warnings, raw };
}

// MARK: selectors

export const sessionLimit = (s) => s.limits.find((l) => l.group === "session") || null;

export const weeklyLimit = (s) =>
  s.limits.find((l) => l.group === "weekly" && !l.isModelScoped && !l.surface) || null;

export const modelLimits = (s) =>
  s.limits.filter((l) => l.isModelScoped).sort((a, b) => b.percent - a.percent);

export const surfaceLimits = (s) => s.limits.filter((l) => l.surface && !l.isModelScoped);

/** The limit closest to its ceiling; ties go to the one the API marked active. */
export function bottleneck(s) {
  return s.limits.reduce((best, l) => {
    if (!best) return l;
    if (Math.abs(l.percent - best.percent) < 1 && l.isActive !== best.isActive) {
      return l.isActive ? l : best;
    }
    return l.percent > best.percent ? l : best;
  }, null);
}

export function snapshotSeverity(s) {
  const all = s.limits.map((l) => l.severity);
  if (s.spend) all.push(s.spend.severity);
  return worstSeverity(all);
}

// MARK: analytics (mirrors UsageAnalytics.swift)

export const MIN_SAMPLES = 3;
export const MIN_SPAN_MS = 300_000;

/**
 * Samples belonging to the current quota window. A reset makes utilisation fall off a cliff;
 * averaging across that boundary would report a nonsense rate, so the series is cut at the
 * most recent material drop.
 */
export function currentWindowSeries(samples, limitId, dropTolerance = 5) {
  const series = samples
    .map((s) => [new Date(s.ts).getTime(), s.limits?.[limitId]])
    .filter(([, v]) => typeof v === "number")
    .sort((a, b) => a[0] - b[0]);

  if (series.length < 2) return series;
  let cut = 0;
  for (let i = series.length - 1; i > 0; i--) {
    if (series[i - 1][1] - series[i][1] > dropTolerance) {
      cut = i;
      break;
    }
  }
  return series.slice(cut);
}

/** Least-squares slope in percentage points per hour, or null when the evidence is thin. */
export function burnRate(samples, limitId) {
  const series = currentWindowSeries(samples, limitId);
  if (series.length < MIN_SAMPLES) return null;
  const span = series[series.length - 1][0] - series[0][0];
  if (span < MIN_SPAN_MS) return null;

  const t0 = series[0][0];
  const xs = series.map(([t]) => (t - t0) / 3_600_000);
  const ys = series.map(([, v]) => v);
  const n = series.length;
  const meanX = xs.reduce((a, b) => a + b, 0) / n;
  const meanY = ys.reduce((a, b) => a + b, 0) / n;

  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (let i = 0; i < n; i++) {
    const dx = xs[i] - meanX;
    const dy = ys[i] - meanY;
    sxy += dx * dy;
    sxx += dx * dx;
    syy += dy * dy;
  }
  if (sxx <= 0) return null;

  return {
    perHour: Math.max(0, sxy / sxx),
    perDay: Math.max(0, sxy / sxx) * 24,
    sampleCount: n,
    spanMs: span,
    fitQuality: syy > 0 ? Math.min(1, Math.max(0, (sxy * sxy) / (sxx * syy))) : 1,
  };
}

export function projection(limit, samples, now = new Date()) {
  const rate = burnRate(samples, limit.id);
  const resetsAt = limit.resetsAt ? new Date(limit.resetsAt) : null;
  const msUntilReset = resetsAt ? Math.max(0, resetsAt - now) : null;

  let projectedAtReset = null;
  let msToExhaustion = null;

  if (rate && rate.perHour > 0.01) {
    if (msUntilReset !== null) {
      projectedAtReset = limit.percent + rate.perHour * (msUntilReset / 3_600_000);
    }
    if (limit.percent < 100) {
      const hours = (100 - limit.percent) / rate.perHour;
      if (Number.isFinite(hours) && hours >= 0) msToExhaustion = hours * 3_600_000;
    } else {
      msToExhaustion = 0;
    }
  }

  return {
    limitId: limit.id,
    burnRate: rate,
    projectedAtReset,
    msToExhaustion,
    msUntilReset,
    willExhaustBeforeReset:
      msToExhaustion !== null && msUntilReset !== null && msToExhaustion < msUntilReset,
    isIndeterminate: !rate,
  };
}
