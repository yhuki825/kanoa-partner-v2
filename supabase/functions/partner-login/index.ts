// パートナーログイン: 企業コード＋パスワード → Supabase Auth セッション発行
// POST { code, pw }
// 200 { ok, access_token, refresh_token, company:{id,tier,code,name}, must_change_pw }
// 401(資格情報) / 403(停止) / 429(試行過多)
import { cors, json, serviceClient, sessionForCompany, legacyHash } from "../_shared/common.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { code?: string; pw?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const code = (body.code ?? "").trim().toUpperCase();
  const pw = body.pw ?? "";
  if (!code || !pw) return json({ error: "bad_request" }, 400);

  const sb = serviceClient();

  // レート制限: 同一コードで直近10分に失敗5回以上 → 429
  const since = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { data: comp } = await sb.from("companies")
    .select("id, auth_user_id").eq("code", code).maybeSingle();
  if (comp) {
    const { count } = await sb.from("login_logs_v2")
      .select("id", { count: "exact", head: true })
      .eq("company_id", comp.id).eq("success", false).gte("created_at", since);
    if ((count ?? 0) >= 5) return json({ error: "too_many_attempts" }, 429);
  }

  // 照合（bcrypt。V1移行分はレガシーハッシュでも照合→自動でbcrypt化）
  const { data: res, error } = await sb.rpc("v2_verify_login", {
    p_code: code, p_pw: pw, p_legacy_hash: await legacyHash(pw),
  });
  if (error) { console.error("verify_login", error); return json({ error: "server" }, 500); }

  const log = (companyId: string | null, success: boolean) =>
    sb.from("login_logs_v2").insert({ company_id: companyId, success, method: "パスワード" });

  if (!res) { if (comp) await log(comp.id, false); return json({ error: "invalid" }, 401); }
  if (res.suspended) { await log(comp?.id ?? null, false); return json({ error: "suspended" }, 403); }

  try {
    const session = await sessionForCompany({
      id: res.id, tier: res.tier, code: res.code, auth_user_id: comp?.auth_user_id ?? null,
    });
    await log(res.id, true);
    return json({
      ok: true, ...session,
      company: { id: res.id, tier: res.tier, code: res.code, name: res.name },
      must_change_pw: !!res.must_change_pw,
    });
  } catch (e) {
    console.error("session issue", e);
    return json({ error: "server" }, 500);
  }
});
