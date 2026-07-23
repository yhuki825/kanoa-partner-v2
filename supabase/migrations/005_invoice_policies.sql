-- 請求: Aラインパートナーの作成・下書き削除を許可（漏れ修正）
create policy p_inv_ins on invoices_v2 for insert with check (
  company_id = v2_company_id() and status = 'draft'
  and exists (select 1 from companies c where c.id = v2_company_id() and c.tier = 1)
);
create policy p_inv_del on invoices_v2 for delete using (
  company_id = v2_company_id() and status = 'draft'
);
