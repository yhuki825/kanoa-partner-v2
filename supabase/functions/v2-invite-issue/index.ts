// フロント会社の招待コード発行
// RA → 1次パートナーを招待 ／ 代表CA → 自社の1つ下の階層を招待
// POST { company_name } → { ok, code, temp_password, expires_at }
// 初期パスワードはこの応答でだけ返す（DBにはハッシュのみ）
import { cors, json, admin, caller, tempPassword } from "../_shared/v2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const me = await caller(req);
  if (!me) return json({ error: "unauthorized" }, 401);
  if (me.role === "ca" && !me.isOwner) return json({ error: "owner_only" }, 403);

  let body: { company_name?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const name = (body.company_name ?? "").trim();
  if (!name) return json({ error: "company_name_required" }, 400);

  const tier = me.role === "ra" ? 1 : (me.tier ?? 0) + 1;
  if (tier > 702) return json({ error: "tier_limit" }, 400);

  const sb = admin();
  const { data: code, error: e1 } = await sb.rpc("v2_next_code", { p_tier: tier });
  if (e1 || !code) { console.error(e1); return json({ error: "server" }, 500); }
  const pw = tempPassword();
  const { data: hash, error: e2 } = await sb.rpc("v2_hash_pw", { p_plain: pw });
  if (e2 || !hash) { console.error(e2); return json({ error: "server" }, 500); }

  const { data: inv, error: e3 } = await sb.from("v2_invites").insert({
    issued_by: me.role === "ra" ? null : me.companyId, issued_member: me.memberId,
    code, tier, company_name: name, temp_pw_hash: hash,
  }).select("code, expires_at").single();
  if (e3) { console.error(e3); return json({ error: "server" }, 500); }

  return json({ ok: true, code: inv.code, temp_password: pw, expires_at: inv.expires_at });
});
