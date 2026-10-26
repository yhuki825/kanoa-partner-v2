-- 136: 求人のCSV一括登録（2026-10-26 ユーザー要望「案件を一括で登録したい」）
--  ・画面がCSVを読み、1行＝1求人の形（JSON）にして渡す。この関数が全行を確かめ、結果を行ごとに返す
--  ・p_commit = false: 確かめるだけ（画面で「登録します／スキップ／エラー」を見せる）
--    p_commit = true : 1行でもエラーがあれば何も登録しない（途中まで登録されて残らない）。エラーが無ければ全行を1回で登録
--  ・同じ求人企業・同じ求人名の求人がすでにあれば、その行は「スキップ」（二重登録しない）。CSVの中の重複はエラー
--  ・求人企業は名前が完全に一致すれば既存を使い、無ければ作る
--  ・登録できるのは KANOA（RA）だけ
-- ※ begin/commit は書いていない。適用するときはトランザクションの中で流すこと
-- 戻すとき: drop function if exists v2_jobs_import(jsonb, boolean);
-- ※ 文言だけの誤りを v_msgs（text[]）に足すときは text '…' と型を明示する（付けないと配列の書き方として読まれて止まる）
set check_function_bodies = off;

create or replace function public.v2_jobs_import(p_rows jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r jsonb; v_line int; v_msgs text[]; v_client text; v_title text; v_status text; v_flow jsonb; v_req jsonb;
  v_fee numeric; v_pol jsonb; v_cids uuid[]; v_codes text[]; v_bad text[]; v_key text; v_seen jsonb := '{}';
  v_result text; v_rows jsonb := '[]'; v_valid jsonb := '[]'; v_n_ok int := 0; v_n_skip int := 0; v_n_err int := 0;
  v_client_id uuid; v_job uuid; v_new_clients jsonb := '{}'; x jsonb;
  c_allowed text[] := array['name','kana','birth_date','gender','education','job_changes','employment_type','current_income',
                            'prefecture','email','phone','desired_location','travel_ok','relocation_ok','desired_income',
                            'recommendation','resume','cv'];
  c_default_flow jsonb := '["書類選考","一次面接","二次面接","最終面接","内定","入社"]';
begin
  if not v2_is_ra() then
    raise exception 'permission_denied' using errcode = 'P0403', hint = '求人の一括登録はKANOAだけができます';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'empty' using errcode = 'P0400', hint = 'CSVに求人の行がありません';
  end if;
  if jsonb_array_length(p_rows) > 500 then
    raise exception 'too_many' using errcode = 'P0400', hint = '一度に登録できるのは500行までです。ファイルを分けてください';
  end if;

  -- ---------- 1) 全行を確かめる ----------
  for r in select value from jsonb_array_elements(p_rows) loop
    v_line := coalesce((r->>'line')::int, 0);
    -- 画面側で見つけた誤り（読めない数字・知らない項目名など）
    v_msgs := coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(r->'errors') = 'array' then r->'errors' else '[]' end)), '{}');
    v_client := nullif(trim(coalesce(r->>'client', '')), '');
    v_title := nullif(trim(coalesce(r->>'title', '')), '');
    if v_client is null then v_msgs := v_msgs || text '求人企業が空です'; end if;
    if v_title is null then v_msgs := v_msgs || text '求人名・職種が空です'; end if;
    if v_client like '（例）%' or v_client like '(例)%' then v_msgs := v_msgs || text 'ひな形の見本の行です（消してから読み込んでください）'; end if;

    v_status := case coalesce(nullif(trim(coalesce(r->>'status', '')), ''), '募集中')
      when '募集中' then 'open' when 'open' then 'open' when '一時停止' then 'paused' when 'paused' then 'paused'
      when '終了' then 'closed' when 'closed' then 'closed' end;
    if v_status is null then v_msgs := v_msgs || ('状態は「募集中」「一時停止」「終了」のどれかにしてください（' || (r->>'status') || '）'); end if;

    v_flow := case when jsonb_typeof(r->'flow') = 'array' and jsonb_array_length(r->'flow') > 0 then r->'flow' else c_default_flow end;
    if exists (select 1 from jsonb_array_elements(v_flow) e where jsonb_typeof(e) <> 'string' or trim(e #>> '{}') = '') then
      v_msgs := v_msgs || text '選考フローに空の段階があります';
    end if;
    if jsonb_array_length(v_flow) > 20 then v_msgs := v_msgs || text '選考フローは20段階までです'; end if;

    v_req := case when jsonb_typeof(r->'entry_requirements') = 'array' then r->'entry_requirements' else '[]' end;
    v_bad := array(select e #>> '{}' from jsonb_array_elements(v_req) e where (e #>> '{}') <> all (c_allowed));
    if cardinality(v_bad) > 0 then v_msgs := v_msgs || ('エントリー時必須項目に使えない項目があります（' || array_to_string(v_bad, '・') || '）'); end if;
    -- 候補者名は常に必須（登録画面と同じ）
    v_req := '["name"]'::jsonb || coalesce((select jsonb_agg(distinct e) from jsonb_array_elements(v_req) e where (e #>> '{}') <> 'name'), '[]');

    v_fee := null;
    if r ? 'fee' and jsonb_typeof(r->'fee') = 'number' then
      v_fee := (r->>'fee')::numeric;
      if v_fee <> trunc(v_fee) or v_fee < 0 or v_fee >= 1000000000000 then
        v_msgs := v_msgs || text '紹介料は0以上・1兆円未満の整数（円・税抜）にしてください'; v_fee := null;
      end if;
    elsif r ? 'fee' and jsonb_typeof(r->'fee') not in ('null') then
      v_msgs := v_msgs || text '紹介料は数字で入れてください';
    end if;

    -- 公開先: "all"＝1次パートナー全社（利用中）／会社コードの配列／空＝非公開
    v_cids := '{}';
    if jsonb_typeof(r->'shares') = 'string' and r->>'shares' = 'all' then
      v_cids := array(select id from v2_companies where tier = 1 and status = 'active' order by code);
    elsif jsonb_typeof(r->'shares') = 'array' then
      v_codes := array(select upper(trim(e #>> '{}')) from jsonb_array_elements(r->'shares') e where trim(e #>> '{}') <> '');
      v_bad := array(select c from unnest(v_codes) c where not exists (select 1 from v2_companies co where co.code = c and co.tier = 1));
      if cardinality(v_bad) > 0 then v_msgs := v_msgs || ('公開先に1次パートナーではない会社コードがあります（' || array_to_string(v_bad, '・') || '）'); end if;
      v_cids := array(select distinct co.id from v2_companies co where co.code = any (v_codes) and co.tier = 1);
    end if;

    v_pol := '[]';
    if jsonb_typeof(r->'refund') = 'array' and jsonb_array_length(r->'refund') > 0 then
      begin
        v_pol := v2_refund_policy_normalize(r->'refund');
      exception when others then
        get stacked diagnostics v_key = pg_exception_hint;
        v_msgs := v_msgs || coalesce(nullif(v_key, ''), '返金規定の形が正しくありません'); v_pol := '[]';
      end;
    end if;

    -- 重複: CSVの中（エラー）／登録済み（スキップ）
    v_result := 'ok';
    if v_client is not null and v_title is not null then
      v_key := lower(v_client) || chr(31) || lower(v_title);
      if v_seen ? v_key then
        v_msgs := v_msgs || ('CSVの中に同じ求人企業・求人名の行がもう1つあります（' || (v_seen->>v_key) || '行目）');
      else
        v_seen := v_seen || jsonb_build_object(v_key, v_line);
        if exists (select 1 from v2_jobs j join v2_clients c on c.id = j.client_id
                   where lower(trim(c.name)) = lower(v_client) and lower(trim(j.title)) = lower(v_title)) then
          v_result := 'skip';
        end if;
      end if;
    end if;
    if cardinality(v_msgs) > 0 then v_result := 'error'; end if;

    if v_result = 'ok' then v_n_ok := v_n_ok + 1;
    elsif v_result = 'skip' then v_n_skip := v_n_skip + 1;
    else v_n_err := v_n_err + 1; end if;

    v_rows := v_rows || jsonb_build_object('line', v_line, 'client', v_client, 'title', v_title, 'result', v_result,
      'messages', to_jsonb(v_msgs), 'shares', cardinality(v_cids), 'fee', v_fee);
    if v_result = 'ok' then
      v_valid := v_valid || jsonb_build_object('client', v_client, 'title', v_title,
        'description', coalesce(r->>'description', ''), 'location', nullif(trim(coalesce(r->>'location', '')), ''),
        'employment', nullif(trim(coalesce(r->>'employment', '')), ''), 'salary', nullif(trim(coalesce(r->>'salary', '')), ''),
        'conditions', coalesce(r->>'conditions', ''), 'status', v_status, 'flow', v_flow, 'req', v_req,
        'checks', jsonb_build_object('spi', coalesce((r->>'spi')::boolean, false), 'compliance', coalesce((r->>'compliance')::boolean, false)),
        'fee', v_fee, 'cids', to_jsonb(v_cids), 'policy', v_pol);
    end if;
  end loop;

  if not p_commit then
    return jsonb_build_object('rows', v_rows, 'ok', v_n_ok, 'skip', v_n_skip, 'error', v_n_err, 'committed', false);
  end if;
  if v_n_err > 0 then
    raise exception 'has_errors' using errcode = 'P0400', hint = 'エラーの行があるため、1件も登録していません。CSVを直して選び直してください';
  end if;

  -- ---------- 2) 登録（全行まとめて。途中で失敗すれば全部取り消される） ----------
  for x in select value from jsonb_array_elements(v_valid) loop
    v_client := x->>'client';
    v_client_id := (v_new_clients->>lower(v_client))::uuid;
    if v_client_id is null then
      select id into v_client_id from v2_clients where lower(trim(name)) = lower(v_client) order by created_at limit 1;
      if v_client_id is null then
        insert into v2_clients(name) values (v_client) returning id into v_client_id;
      end if;
      v_new_clients := v_new_clients || jsonb_build_object(lower(v_client), v_client_id);
    end if;
    insert into v2_jobs(client_id, title, description, location, employment, salary, conditions, entry_requirements, flow, checks, status)
    values (v_client_id, x->>'title', x->>'description', x->>'location', x->>'employment', x->>'salary', x->>'conditions',
            x->'req', x->'flow', x->'checks', x->>'status')
    returning id into v_job;
    if jsonb_typeof(x->'fee') = 'number' then
      insert into v2_job_kanoa_fees(job_id, fee) values (v_job, (x->>'fee')::numeric);
    end if;
    insert into v2_job_shares(job_id, company_id, published)
    select v_job, (c #>> '{}')::uuid, true from jsonb_array_elements(x->'cids') c;
    if jsonb_array_length(x->'policy') > 0 then
      insert into v2_job_refund_policies(job_id, policy) values (v_job, x->'policy');
    end if;
  end loop;
  return jsonb_build_object('rows', v_rows, 'ok', v_n_ok, 'skip', v_n_skip, 'error', 0, 'committed', true);
end $$;

revoke all on function public.v2_jobs_import(jsonb, boolean) from public, anon;
grant execute on function public.v2_jobs_import(jsonb, boolean) to authenticated;
