// 招待の受付（初回登録）: 企業コード＋初期パスワード → 会社と代表CAを作成
// POST { code, temp_pw, new_pw, name, email? } → { ok, login_id }
// 成功後、画面側で login_id と new_pw で通常ログインする
import { cors, json, admin, loginEmail } from "../_shared/v2.ts";

const STATUS: Record<string, number> = { not_found: 404, already_used: 409, expired: 410, bad_password: 401 };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let b: { code?: string; temp_pw?: string; new_pw?: string; name?: string; email?: string };
  try { b = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const newPw = b.new_pw ?? "";
  const name = (b.name ?? "").trim();
  if (!b.code || !b.temp_pw || !name) return json({ error: "bad_request" }, 400);
  if (newPw.length < 8) return json({ error: "weak_password" }, 400);

  const sb = admin();
  // ① 照合
  const { data: chk, error: e1 } = await sb.rpc("v2_invite_check", { p_code: b.code, p_temp_pw: b.temp_pw });
  if (e1) { console.error(e1); return json({ error: "server" }, 500); }
  if (chk?.error) return json({ error: chk.error }, STATUS[chk.error] ?? 400);

  // ② ログイン用アカウント（代表CAは必ず -01）
  const loginId = `${chk.code}-01`;
  const { data: created, error: e2 } = await sb.auth.admin.createUser({
    email: loginEmail(loginId), password: newPw, email_confirm: true,
  });
  if (e2 || !created?.user) { console.error(e2); return json({ error: "server" }, 500); }

  // ③ 会社＋代表CA＋消込を1トランザクションで。失敗したら②を取り消す
  const { data: res, error: e3 } = await sb.rpc("v2_invite_consume", {
    p_invite: chk.invite_id, p_user: created.user.id, p_name: name, p_email: b.email ?? "",
  });
  if (e3) {
    console.error(e3);
    await sb.auth.admin.deleteUser(created.user.id);
    return json({ error: /invite_unavailable/.test(e3.message) ? "already_used" : "server" }, e3 ? 409 : 500);
  }
  return json({ ok: true, login_id: res.login_id });
});
