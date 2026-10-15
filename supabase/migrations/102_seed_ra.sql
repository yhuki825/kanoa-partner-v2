-- KANOA管理者（V1と共用のSupabaseユーザー）をRAとして登録
-- V1の kanoa_admins の全員を対象にする。V1側の行・ユーザーは変更しない
insert into v2_members (user_id, role, name, email)
select k.user_id, 'ra', coalesce(nullif(k.name, ''), u.email), u.email
from kanoa_admins k join auth.users u on u.id = k.user_id
on conflict (user_id) do nothing;
