// 招待の受諾（初回ログイン）: 企業コード＋一時パスワード → 本パスワード設定 → 企業登録 → セッション発行
// POST { code, temp_pw, new_pw, contact?, email?, phone? }
// 200 { ok, access_token, refresh_token, company } / 各種エラー
import { cors, json, serviceClient, sessionForCompany } from "../_shared/common.ts";

const ERR_STATUS: Record<string, number> = {
  not_found: 404, already_used: 409, expired: 410, bad_password: 401, weak_password: 400,
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: { code?: string; temp_pw?: string; new_pw?: string; contact?: string; email?: string; phone?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const { code = "", temp_pw = "", new_pw = "" } = body;
  if (!code || !temp_pw || !new_pw) return json({ error: "bad_request" }, 400);

  const sb = serviceClient();
  const { data: res, error } = await sb.rpc("v2_accept_invite", {
    p_code: code.trim(), p_temp_pw: temp_pw, p_new_pw: new_pw,
    p_contact: body.contact ?? null, p_email: body.email ?? null, p_phone: body.phone ?? null,
  });
  if (error) { console.error("accept_invite", error); return json({ error: "server" }, 500); }
  if (res?.error) return json({ error: res.error }, ERR_STATUS[res.error] ?? 400);

  try {
    const session = await sessionForCompany({ id: res.id, tier: res.tier, code: res.code, auth_user_id: null });
    await sb.from("login_logs_v2").insert({ company_id: res.id, success: true, method: "招待受諾" });
    return json({ ok: true, ...session, company: { id: res.id, tier: res.tier, code: res.code, name: res.name } });
  } catch (e) {
    console.error("session issue", e);
    return json({ error: "server" }, 500);
  }
});
