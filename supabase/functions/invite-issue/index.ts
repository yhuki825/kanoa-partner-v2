// 招待コード発行: 呼び出し企業のフロント（1つ下の階層）を招待する
// POST { company_name }   認証: パートナーJWT または KANOA管理者JWT
// 200 { ok, code, temp_password, expires_at, login_url }
// ※ temp_password はこのレスポンスでのみ返る（DBにはハッシュのみ保存）
import { cors, json, serviceClient, callerFromAuth, genTempPassword } from "../_shared/common.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const caller = await callerFromAuth(req);
  if (!caller) return json({ error: "unauthorized" }, 401);

  let body: { company_name?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const companyName = (body.company_name ?? "").trim();
  if (!companyName) return json({ error: "company_name_required" }, 400);

  const sb = serviceClient();

  // 発行者と招待先の階層を決定（KANOA発行=1次、企業発行=自階層+1）
  let issuedBy: string | null = null;
  let tier = 1;
  if (caller.kind === "partner") {
    const { data: me } = await sb.from("companies").select("id,tier,status").eq("id", caller.companyId).maybeSingle();
    if (!me || me.status !== "active") return json({ error: "unauthorized" }, 401);
    issuedBy = me.id;
    tier = me.tier + 1;
  }

  // 企業コード採番（DB側で同時実行安全）＋一時パスワード生成
  const { data: code, error: codeErr } = await sb.rpc("v2_next_code", { p_tier: tier });
  if (codeErr || !code) return json({ error: "code_issue_failed" }, 500);
  const tempPw = genTempPassword();
  const { data: tempHash, error: hashErr } = await sb.rpc("v2_hash_pw", { p_plain: tempPw });
  if (hashErr || !tempHash) return json({ error: "server" }, 500);

  const { data: inv, error: insErr } = await sb.from("invites")
    .insert({ issued_by: issuedBy, code, tier, company_name: companyName, temp_pw_hash: tempHash })
    .select("code, expires_at").single();
  if (insErr) return json({ error: "server" }, 500);

  const loginUrl = Deno.env.get("APP_URL") ?? "";
  return json({ ok: true, code: inv.code, temp_password: tempPw, expires_at: inv.expires_at, login_url: loginUrl });
});
