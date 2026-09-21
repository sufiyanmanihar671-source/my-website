// refresh-exchange-rates — keeps currencies.auto_rate up to date.
//
// Who calls it:
//   * pg_cron, every 6 hours (no credentials)          -> refreshes if switched on
//   * the storefront, only when rates look >24h stale  -> same, heavily throttled
//   * the admin "Update Rates" button (staff JWT)      -> { force: true }, always runs
//
// verify_jwt is OFF because the scheduled call carries no user. That is safe here:
// the caller supplies no data — rates always come from the fixed providers in core.js —
// and unauthenticated calls are throttled by an atomic claim on currency_settings.
// Only a verified active admin/manager can force a run or bypass the on/off switch.
//
// A failed run never touches the stored rates: the last successful ones stay in use,
// and the failure is recorded in currency_settings for the admin dashboard.
import { createClient } from "npm:@supabase/supabase-js@2";
import { collectRates, planUpdates, summarise } from "./core.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MIN_GAP_AUTO_MS = 10 * 60 * 1000;   // unauthenticated / scheduled: at most one attempt per 10 min
const MIN_GAP_FORCE_MS = 15 * 1000;       // admin button: at most one attempt per 15 s
const RECENT_SUCCESS_MS = 55 * 60 * 1000; // scheduled runs skip if rates were refreshed within the hour

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST" && req.method !== "GET") return json({ ok: false, error: "Method not allowed" }, 405);

  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    let wantsForce = false;
    if (req.method === "POST") {
      try { wantsForce = (await req.json())?.force === true; } catch { /* empty body */ }
    }

    // is the caller a verified, active staff member?
    let isStaff = false;
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (token) {
      const { data } = await db.auth.getUser(token);
      if (data?.user) {
        const { data: prof } = await db.from("profiles").select("role,is_active").eq("id", data.user.id).maybeSingle();
        isStaff = !!prof && prof.is_active === true && ["admin", "manager"].includes(prof.role);
      }
    }
    if (wantsForce && !isStaff) return json({ ok: false, error: "Only staff can force an update." }, 403);
    const force = wantsForce && isStaff;

    const { data: settings, error: sErr } = await db.from("currency_settings").select("*").eq("id", true).single();
    if (sErr || !settings) return json({ ok: false, error: "Currency settings are missing." }, 500);
    if (!force && !settings.auto_rates_enabled) return json({ ok: true, skipped: "Automatic updates are switched off." });
    if (!force && settings.last_success_at && Date.now() - Date.parse(settings.last_success_at) < RECENT_SUCCESS_MS) {
      return json({ ok: true, skipped: "Rates were updated recently." });
    }

    // atomic claim: only one concurrent caller wins the slot
    const cutoff = new Date(Date.now() - (force ? MIN_GAP_FORCE_MS : MIN_GAP_AUTO_MS)).toISOString();
    const { data: claimed } = await db.from("currency_settings")
      .update({ last_attempt_at: new Date().toISOString() })
      .eq("id", true)
      .or(`last_attempt_at.is.null,last_attempt_at.lt.${cutoff}`)
      .select("id");
    if (!claimed || !claimed.length) return json({ ok: true, skipped: "An update was attempted a moment ago." });

    const { data: rows, error: cErr } = await db.from("currencies").select("code,auto_rate");
    if (cErr || !rows) throw new Error("could not read currencies");
    const wanted = rows.map((r: { code: string }) => r.code).filter((c: string) => c !== "INR");

    const collected = await collectRates(wanted, fetch);
    const plan = planUpdates(rows, collected.rates);
    const { status, message } = summarise(wanted.length, plan, collected);

    const now = new Date().toISOString();
    for (const u of plan.updates) {
      const { error } = await db.from("currencies")
        .update({ auto_rate: u.auto_rate, auto_rate_updated_at: now }).eq("code", u.code);
      if (error) throw new Error("could not save the " + u.code + " rate");
    }
    await db.from("currency_settings").update({
      last_status: status,
      last_message: message,
      updated_count: plan.updates.length,
      ...(plan.updates.length ? { last_success_at: now, provider: collected.used.join(" + ") } : {}),
    }).eq("id", true);

    return json({
      ok: status !== "error", status, message,
      updated: plan.updates.map((u: { code: string }) => u.code),
      missing: plan.missing, rejected: plan.rejected,
    });
  } catch (e) {
    console.error("refresh-exchange-rates failed:", e);
    return json({ ok: false, error: "The exchange-rate update could not run." }, 500);
  }
});
