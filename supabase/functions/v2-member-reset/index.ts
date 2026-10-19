// CAのパスワード再設定（代表CA=自社のCA、RA=全CA）。新しい初期パスワードはこの応答でだけ返す
// 再設定されたCAは、次のログインでパスワード変更が必要になる
// POST { member_id } → { ok, login_id, temp_password }
import { cors, json, admin, caller, tempPassword } from "../_shared/v2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const me = await caller(req);
  if (!me) return json({ error: "unauthorized" }, 401);

  let b: { member_id?: string };
  try { b = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  if (!b.member_id) return json({ error: "bad_request" }, 400);

  const sb = admin();
  const { data: t } = await sb.from("v2_members").select("id, user_id, company_id, role, login_id, is_owner")
    .eq("id", b.member_id).maybeSingle();
  if (!t || t.role !== "ca") return json({ error: "not_found" }, 404);
  if (t.id === me.memberId) return json({ error: "use_account_page" }, 400);
  // V1 から移したアカウント（V1 の本番のログイン用アカウントに結びついている）は、切替日まで誰からも書き換えない（権限の判定より先に止める）
  const { data: locked, error: el } = await sb.rpc("v2_member_v1_locked", { p_member: t.id });
  if (el) { console.error(el); return json({ error: "server" }, 500); }
  if (locked !== false) {
    return json({ error: "v1_locked", code: "P0403", hint: "V1から移したアカウントは、切替日まで変更できません" }, 403);
  }
  const allowed = me.role === "ra" || (me.isOwner && me.companyId === t.company_id && !t.is_owner);
  if (!allowed) return json({ error: "owner_only" }, 403);

  const pw = tempPassword();
  const { error: e1 } = await sb.auth.admin.updateUserById(t.user_id, { password: pw });
  if (e1) { console.error(e1); return json({ error: "server" }, 500); }
  const { error: e2 } = await sb.from("v2_members").update({ must_change_pw: true }).eq("id", t.id);
  if (e2) { console.error(e2); return json({ error: "server" }, 500); }
  return json({ ok: true, login_id: t.login_id, temp_password: pw });
});
