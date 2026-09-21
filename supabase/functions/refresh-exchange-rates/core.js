// Pure logic for refresh-exchange-rates (no Deno / Supabase imports, so it can be unit-tested in Node).
//
// All rates are "units of currency per 1 INR". INR is the base and is never fetched.

export const PROVIDERS = [
  {
    name: "ExchangeRate-API",
    url: "https://open.er-api.com/v6/latest/INR",
    parse(j) {
      if (!j || j.result !== "success" || !j.rates || typeof j.rates !== "object") throw new Error("unexpected response");
      return { rates: j.rates, asOf: j.time_last_update_unix ? new Date(j.time_last_update_unix * 1000).toISOString() : null };
    },
  },
  {
    name: "currency-api (jsDelivr)",
    url: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/inr.json",
    parse: parseFawaz,
  },
  {
    name: "currency-api (Cloudflare Pages)",
    url: "https://latest.currency-api.pages.dev/v1/currencies/inr.json",
    parse: parseFawaz,
  },
];

function parseFawaz(j) {
  if (!j || !j.inr || typeof j.inr !== "object") throw new Error("unexpected response");
  const rates = {};
  for (const k of Object.keys(j.inr)) rates[k.toUpperCase()] = j.inr[k];
  return { rates, asOf: j.date || null };
}

export function validRate(v) {
  return typeof v === "number" && Number.isFinite(v) && v > 0;
}

async function getJson(url, fetchImpl, timeoutMs) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: ctl.signal, headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error("HTTP " + res.status);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

// Ask the providers in order until every wanted code has a valid rate.
// A later provider is only used for codes the earlier ones did not supply.
export async function collectRates(wanted, fetchImpl, providers = PROVIDERS, timeoutMs = 8000) {
  const rates = {};
  const used = [];
  const errors = [];
  let asOf = null;
  for (const p of providers) {
    const missing = wanted.filter((c) => !(c in rates));
    if (!missing.length) break;
    try {
      const out = p.parse(await getJson(p.url, fetchImpl, timeoutMs));
      let got = 0;
      for (const c of missing) {
        if (validRate(out.rates[c])) { rates[c] = out.rates[c]; got++; }
      }
      if (got) { used.push(p.name); asOf = asOf || out.asOf; }
      else errors.push(p.name + ": no usable rates");
    } catch (e) {
      errors.push(p.name + ": " + (e && e.name === "AbortError" ? "timed out" : (e && e.message) || "failed"));
    }
  }
  return { rates, used, errors, asOf };
}

// Decide which rows to update. A new rate that is more than `maxJump`x away from the
// previous automatic rate is treated as a provider glitch and skipped.
export function planUpdates(rows, rates, maxJump = 2) {
  const updates = [];
  const missing = [];
  const rejected = [];
  for (const r of rows) {
    if (r.code === "INR") continue;
    const v = rates[r.code];
    if (!validRate(v)) { missing.push(r.code); continue; }
    const prev = Number(r.auto_rate);
    if (validRate(prev) && (v / prev > maxJump || v / prev < 1 / maxJump)) {
      rejected.push({ code: r.code, reason: "moved by more than " + maxJump + "x in one update" });
      continue;
    }
    updates.push({ code: r.code, auto_rate: v });
  }
  return { updates, missing, rejected };
}

// Status written to currency_settings after a run.
export function summarise(total, plan, collected) {
  const failedCodes = plan.missing.concat(plan.rejected.map((x) => x.code));
  let status;
  if (plan.updates.length === 0) status = "error";
  else if (failedCodes.length) status = "partial";
  else status = "ok";

  let message;
  if (status === "ok") {
    message = "Updated " + plan.updates.length + " of " + total + " currencies from " + collected.used.join(" + ") +
      (collected.asOf ? " (rates as of " + String(collected.asOf).slice(0, 10) + ")" : "") + ".";
  } else if (status === "partial") {
    message = "Updated " + plan.updates.length + " of " + total + " currencies; kept the previous rate for " + failedCodes.join(", ") + ".";
  } else {
    message = "Exchange-rate update failed; the last successful rates are still in use. " + (collected.errors.join("; ") || "No usable rates were returned.");
  }
  return { status, message: message.slice(0, 400) };
}
