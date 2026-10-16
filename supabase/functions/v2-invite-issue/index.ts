// フロント会社の招待コード発行
// RA → 1次パートナーを招待 ／ 代表CA → 自社の1つ下の階層を招待
// POST { company_name } → { ok, code, temp_password, expires_at }
// POST { reissue_code } → 同じ企業コードで初期パスワードと期限を付け直す
// 初期パスワードはこの応答でだけ返す（DBにはハッシュのみ）
import { cors, json, admin, caller, tempPassword } from "../_shared/v2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const me = await caller(req);
  if (!me) return json({ error: "unauthorized" }, 401);
  if (me.role === "ca" && !me.isOwner) return json({ error: "owner_only" }, 403);

  let body: { company_name?: string; reissue_code?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }

  // 再発行: 自分が出した未使用（または期限切れ）の招待に、新しい初期パスワードと期限を付け直す（企業コードは同じ）
  if (body.reissue_code) {
    const sb0 = admin();
    const { data: inv } = await sb0.from("v2_invites").select("id, code, issued_by, status")
      .eq("code", body.reissue_code.trim().toUpperCase()).maybeSingle();
    const mine = inv && (me.role === "ra" ? inv.issued_by === null : inv.issued_by === me.companyId);
    if (!inv || !mine) return json({ error: "not_found" }, 404);
    if (!["issued", "expired"].includes(inv.status)) return json({ error: "already_used" }, 409);
    const pw = tempPassword();
    const { data: hash, error: he } = await sb0.rpc("v2_hash_pw", { p_plain: pw });
    if (he || !hash) { console.error(he); return json({ error: "server" }, 500); }
    const expires = new Date(Date.now() + 14 * 86400000).toISOString();
    const { error: ue } = await sb0.from("v2_invites")
      .update({ temp_pw_hash: hash, status: "issued", expires_at: expires }).eq("id", inv.id);
    if (ue) { console.error(ue); return json({ error: "server" }, 500); }
    return json({ ok: true, code: inv.code, temp_password: pw, expires_at: expires });
  }

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
