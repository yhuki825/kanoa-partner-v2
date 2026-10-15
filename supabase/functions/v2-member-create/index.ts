// 自社のCAを追加（代表CAのみ）
// POST { name, email? } → { ok, login_id, temp_password }
// 初期パスワードはこの応答でだけ返す。追加されたCAは初回ログインでパスワード変更が必要
import { cors, json, admin, caller, loginEmail, tempPassword } from "../_shared/v2.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const me = await caller(req);
  if (!me) return json({ error: "unauthorized" }, 401);
  if (me.role !== "ca" || !me.isOwner || !me.companyId) return json({ error: "owner_only" }, 403);

  let b: { name?: string; email?: string };
  try { b = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const name = (b.name ?? "").trim();
  if (!name) return json({ error: "name_required" }, 400);

  const sb = admin();
  const { data: loginId, error: e1 } = await sb.rpc("v2_next_login_id", { p_company: me.companyId });
  if (e1 || !loginId) { console.error(e1); return json({ error: "server" }, 500); }

  const pw = tempPassword();
  const { data: created, error: e2 } = await sb.auth.admin.createUser({
    email: loginEmail(loginId), password: pw, email_confirm: true,
  });
  if (e2 || !created?.user) { console.error(e2); return json({ error: "server" }, 500); }

  const { error: e3 } = await sb.rpc("v2_member_insert", {
    p_company: me.companyId, p_user: created.user.id, p_login: loginId, p_name: name, p_email: b.email ?? "",
  });
  if (e3) { console.error(e3); await sb.auth.admin.deleteUser(created.user.id); return json({ error: "server" }, 500); }

  return json({ ok: true, login_id: loginId, temp_password: pw });
});
