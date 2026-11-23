-- ============================================================
-- لوحة زبائن عالم محمد تيفي: ربط البانل (Reseller API v1)
--   يسحب خطوطك من البانل، ويربطها بالزبائن باليوزر، ويحدّث تواريخ الانتهاء
--   وكلمات المرور والجوالات، ويعرض رصيد الكريدت. مزامنة يومية + زر "مزامنة الحين".
-- شغّله بعد schema.sql و automation.sql في: SQL Editor ← New query ← Run
-- تقدر تشغله أكثر من مرة بدون ما يخرب شي.
-- مفتاح الـ API ينحفظ في مخطط خاص ما ينوصل له من الإنترنت، وينحط من اللوحة.
-- ============================================================

create extension if not exists http with schema extensions;

create schema if not exists private;

-- ---------- إعداد كل بانل (بانل واحد لكل سيرفر) ----------
create table if not exists private.panels (
  id                text primary key,            -- = رقم السيرفر في إعدادات اللوحة
  base_url          text not null default '',
  api_key           text not null default '',
  enabled           boolean not null default true,
  sync_hour         smallint not null default 9 check (sync_hour between 0 and 23),
  packages          jsonb not null default '[]'::jsonb,
  credits           numeric,
  account_name      text not null default '',
  lines_total       int,
  last_status       text not null default 'never',  -- never | ok | error
  last_error        text not null default '',
  last_result       jsonb not null default '{}'::jsonb,
  last_sync_at      timestamptz,
  last_sync_started timestamptz,
  last_sync_on      date,
  requested_at      timestamptz,
  updated_at        timestamptz not null default now()
);

-- ---------- نسخة من خطوط البانل ----------
create table if not exists public.panel_lines (
  panel_id           text   not null,
  line_id            bigint not null,
  username           text   not null default '',
  password           text   not null default '',
  fullname           text   not null default '',
  package_id         bigint,
  expires_at         timestamptz,
  enabled            boolean not null default true,
  banned             boolean not null default false,
  is_trial           boolean not null default false,
  max_connections    int,
  active_connections int,
  activates_on       text not null default '',
  playlist_host      text not null default '',
  phone_found        text not null default '',
  customer_id        uuid references public.customers(id) on delete set null,
  synced_at          timestamptz not null default now(),
  primary key (panel_id, line_id)
);
create index if not exists panel_lines_username_idx on public.panel_lines (lower(username));
create index if not exists panel_lines_customer_idx on public.panel_lines (customer_id);

alter table public.panel_lines enable row level security;
drop policy if exists "staff read panel lines" on public.panel_lines;
create policy "staff read panel lines" on public.panel_lines for select to authenticated using (public.is_staff());
revoke all on public.panel_lines from anon;
revoke insert, update, delete on public.panel_lines from authenticated;

-- ---------- أدوات ----------
create or replace function private.riyadh_now() returns timestamp
language sql stable as $$ select now() at time zone 'Asia/Riyadh' $$;

-- يطلع رقم جوال من نص (مثل اسم الخط في البانل) ويحوله للصيغة الدولية
create or replace function private.extract_phone(t text) returns text
language plpgsql immutable as $$
declare s text; m text;
begin
  s := translate(coalesce(t, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  s := regexp_replace(s, '[\s\-\(\)\.]', '', 'g');
  m := substring(s from '(?:\+|00)?9665[0-9]{8}');
  if m is not null then return regexp_replace(m, '^(\+|00)', ''); end if;
  m := substring(s from '05[0-9]{8}');
  if m is not null then return '966' || substr(m, 2); end if;
  m := substring(s from '(?:\+|00)[1-9][0-9]{9,13}');
  if m is not null then return regexp_replace(m, '^(\+|00)', ''); end if;
  return '';
end $$;

create or replace function private.pkg_from_days(d int) returns text
language sql immutable as $$
  select case when d is null then '12m' when d <= 2 then 'trial' when d <= 45 then '1m'
              when d <= 120 then '3m' when d <= 240 then '6m' else '12m' end
$$;

create or replace function private.panel_get(p_base text, p_key text, p_path text) returns extensions.http_response
language plpgsql volatile as $$
declare r extensions.http_response; tries int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '25');
  loop
    r := extensions.http((
      'GET', rtrim(p_base, '/') || '/api/reseller/v1' || p_path,
      array[extensions.http_header('Authorization', 'Bearer ' || p_key),
            extensions.http_header('Accept', 'application/json')],
      null, null)::extensions.http_request);
    exit when (r.status not in (429, 503)) or tries >= 3;
    tries := tries + 1;
    perform pg_sleep(2 * tries);
  end loop;
  return r;
end $$;

-- يشرح خطأ البانل بالعربي
create or replace function private.panel_error(r extensions.http_response) returns text
language plpgsql immutable as $$
declare code text;
begin
  begin code := (r.content::jsonb)->'error'->>'code'; exception when others then code := null; end;
  return case code
    when 'invalid_key'       then 'مفتاح الـ API غلط أو انحذف'
    when 'key_disabled'      then 'مفتاح الـ API موقوف من البانل، فعّله من API Reseller'
    when 'ip_not_allowed'    then 'المفتاح مقيّد بعناوين IP. شيل قيد الـ IP من المفتاح، لأن عناوين Supabase تتغير'
    when 'host_not_allowed'  then 'المفتاح مقيّد بدومين ثاني (DOMAIN في إعدادات المفتاح). خل رابط البانل بنفس الدومين، أو غيّر دومين المفتاح'
    when 'signature_invalid' then 'المفتاح مفعّل عليه HMAC. طفّ الـ HMAC للمفتاح هذا'
    when 'https_required'    then 'لازم الرابط يبدأ بـ https://'
    when 'account_suspended' then 'حساب الريسيلر موقوف'
    when 'account_disabled'  then 'حساب الريسيلر معطّل'
    when 'rate_limited'      then 'طلبات كثيرة، بنحاول مرة ثانية بعد شوي'
    when 'circuit_open'      then 'البانل وقف الطلبات مؤقتاً بعد أخطاء كثيرة، بنحاول بعد شوي'
    when 'insufficient_credits'  then 'الرصيد ما يكفي لهالباقة. اشحن كريدت أو اختر باقة أرخص'
    when 'validation_failed'     then 'البانل رفض البيانات: ' || coalesce(left((r.content::jsonb)->'error'->>'details', 200), 'تأكد من الباقة')
    when 'external_ref_conflict' then 'فيه طلب سابق بنفس الرقم وبباقة ثانية. سكّر النافذة وجرّب من جديد'
    when 'idempotency_conflict'  then 'فيه طلب سابق بنفس الرقم وبيانات ثانية. سكّر النافذة وجرّب من جديد'
    when 'operation_pending'     then 'الطلب لسا ينفّذ في البانل. اضغط نفس الزر مرة ثانية بعد ثواني (ما بينخصم مرتين)'
    when 'not_found'             then 'البانل ما لقى الطلب أو الخط (يمكن انحذف)'
    when 'sandbox_read_only'     then 'هذا مفتاح Sandbox: يجرب بس وما يغيّر شي'
    else case
      when code is null and r.status in (401, 403, 404, 405)
        then 'الرابط ما يوصل لـ API الريسيلر (رد ' || r.status || '). حط الدومين والبورت بس مثل https://example.com:8443 بدون أي مسار بعده، وتأكد إن الدومين نفس دومين المفتاح'
      when r.status between 500 and 599 then 'البانل واقف أو فيه مشكلة مؤقتة (رد ' || r.status || '). جرّب بعد شوي'
      else 'البانل رد بخطأ ' || coalesce(r.status::text, '') || coalesce(' (' || code || ')', '') end
  end;
end $$;

-- ---------- ربط الخطوط بالزبائن + تحديث بياناتهم ----------
create or replace function private.panel_link(p_id text) returns jsonb
language plpgsql volatile as $$
declare
  today date := private.riyadh_now()::date;
  n_linked int; n_dates int := 0; n_phones int := 0; n_pass int := 0;
  r record;
  new_end date;
begin
  -- فك الربط لو تغيّر يوزر الزبون
  update public.panel_lines pl set customer_id = null
   where pl.panel_id = p_id and pl.customer_id is not null
     and not exists (select 1 from public.customers c where c.id = pl.customer_id and lower(c.line_user) = lower(pl.username));
  -- الربط باليوزر
  update public.panel_lines pl set customer_id = c.id
    from public.customers c
   where pl.panel_id = p_id and c.line_user <> '' and lower(c.line_user) = lower(pl.username)
     and pl.customer_id is distinct from c.id;
  select count(*) into n_linked from public.panel_lines where panel_id = p_id and customer_id is not null;

  for r in
    select pl.*, c.end_date as c_end, c.phone as c_phone, c.line_pass as c_pass, c.server_id as c_server, c.pkg as c_pkg
      from public.panel_lines pl join public.customers c on c.id = pl.customer_id
     where pl.panel_id = p_id
  loop
    new_end := case when r.expires_at is null then null else (r.expires_at at time zone 'Asia/Riyadh')::date end;
    update public.customers set
      end_date  = coalesce(new_end, end_date),
      line_pass = case when r.password <> '' then r.password else line_pass end,
      phone     = case when phone = '' and r.phone_found <> '' then r.phone_found else phone end,
      server_id = case when server_id = '' then p_id else server_id end,
      payments  = case when new_end is not null and new_end - end_date >= 20
                       then payments || jsonb_build_array(jsonb_build_object(
                              'date', today::text, 'amount', 0, 'pkg', pkg, 'kind', 'panel', 'days', new_end - end_date))
                       else payments end
    where id = r.customer_id
      and (end_date is distinct from coalesce(new_end, end_date)
           or (r.password <> '' and line_pass is distinct from r.password)
           or (phone = '' and r.phone_found <> '')
           or server_id = '');
    if new_end is not null and new_end is distinct from r.c_end then n_dates := n_dates + 1; end if;
    if r.c_phone = '' and r.phone_found <> '' then n_phones := n_phones + 1; end if;
    if r.password <> '' and r.password is distinct from r.c_pass then n_pass := n_pass + 1; end if;
  end loop;

  return jsonb_build_object('linked', n_linked, 'dates_updated', n_dates, 'phones_added', n_phones, 'passwords_updated', n_pass);
end $$;

-- يسحب كل صفحات الخطوط لحالة معيّنة (all / expired / disabled / banned) ويحفظها
create or replace function private.panel_fetch(p private.panels, p_status text) returns int
language plpgsql volatile as $$
declare r extensions.http_response; js jsonb; pg int := 1; total int := 0; n int := 0;
begin
  loop
    r := private.panel_get(p.base_url, p.api_key, '/lines?status=' || p_status || '&per_page=100&page=' || pg);
    if r.status <> 200 then raise exception '%', private.panel_error(r); end if;
    js := r.content::jsonb;
    total := coalesce((js->>'total')::int, 0);

    insert into public.panel_lines as t (panel_id, line_id, username, password, fullname, package_id, expires_at,
        enabled, banned, is_trial, max_connections, active_connections, activates_on, playlist_host, phone_found, synced_at)
    select p.id, (l->>'id')::bigint, coalesce(l->>'username', ''), coalesce(l->>'password', ''), coalesce(l->>'fullname', ''),
           nullif(l->>'package_id', '')::bigint, nullif(l->>'expires_at', '')::timestamptz,
           coalesce((l->>'enabled')::boolean, true), coalesce((l->>'banned')::boolean, false), coalesce((l->>'is_trial')::boolean, false),
           nullif(l->>'max_connections', '')::int, nullif(l->>'active_connections', '')::int,
           coalesce(l->>'activates_on', ''), coalesce(l->'playlist'->>'host', ''),
           private.extract_phone(l->>'fullname'), clock_timestamp()
      from jsonb_array_elements(coalesce(js->'data', '[]'::jsonb)) l
     where l ? 'id'
    on conflict (panel_id, line_id) do update set
      username = excluded.username, password = excluded.password, fullname = excluded.fullname,
      package_id = excluded.package_id, expires_at = excluded.expires_at, enabled = excluded.enabled,
      banned = excluded.banned, is_trial = excluded.is_trial, max_connections = excluded.max_connections,
      active_connections = excluded.active_connections, activates_on = excluded.activates_on,
      playlist_host = excluded.playlist_host, phone_found = excluded.phone_found, synced_at = excluded.synced_at;

    n := n + jsonb_array_length(coalesce(js->'data', '[]'::jsonb));
    exit when pg * 100 >= total or jsonb_array_length(coalesce(js->'data', '[]'::jsonb)) = 0 or pg >= 300;
    pg := pg + 1;
  end loop;
  return n;
end $$;

-- ---------- المزامنة الكاملة لبانل واحد ----------
create or replace function private.panel_sync(p_id text) returns jsonb
language plpgsql volatile as $$
declare
  p private.panels;
  r extensions.http_response;
  js jsonb;
  started timestamptz := clock_timestamp();
  link jsonb;
  v_credits numeric;
  acc text;
  acc_total int;
  n_lines int;
  st text;
  extra_passes text[] := '{}';
begin
  select * into p from private.panels where id = p_id;
  if p.id is null or p.api_key = '' or p.base_url = '' then raise exception 'البانل مو مربوط (الرابط أو المفتاح ناقص)'; end if;

  r := private.panel_get(p.base_url, p.api_key, '/account');
  if r.status <> 200 then raise exception '%', private.panel_error(r); end if;
  js := r.content::jsonb;
  v_credits := (js->>'credits')::numeric;
  acc := coalesce(js->>'username', '');
  acc_total := nullif(js->'lines'->>'total', '')::int;

  r := private.panel_get(p.base_url, p.api_key, '/packages?kind=line');
  if r.status = 200 and jsonb_typeof(r.content::jsonb) = 'array' then
    update private.panels set packages = r.content::jsonb where id = p_id;
  end if;

  -- كل الخطوط
  perform private.panel_fetch(p, 'all');
  select count(*) into n_lines from public.panel_lines where panel_id = p_id and synced_at >= started;

  -- لو البانل يقول عندك خطوط أكثر من اللي رجعت، نسحب المنتهية والموقوفة والمحظورة لحالها
  if acc_total is null or n_lines < acc_total then
    foreach st in array array['expired', 'disabled', 'banned'] loop
      begin
        perform private.panel_fetch(p, st);
        extra_passes := extra_passes || st;
      exception when others then null;
      end;
    end loop;
  end if;

  -- الخطوط اللي انحذفت من البانل
  delete from public.panel_lines where panel_id = p_id and synced_at < started;
  select count(*) into n_lines from public.panel_lines where panel_id = p_id;

  link := private.panel_link(p_id);
  link := link || jsonb_build_object('lines', n_lines, 'panel_total', acc_total, 'extra_passes', to_jsonb(extra_passes),
    'unlinked_active', (select count(*) from public.panel_lines where panel_id = p_id and customer_id is null
                         and enabled and not banned and (expires_at is null or expires_at > now())),
    'unlinked_expired', (select count(*) from public.panel_lines where panel_id = p_id and customer_id is null
                         and not (enabled and not banned and (expires_at is null or expires_at > now()))));

  update private.panels set credits = v_credits, account_name = acc, lines_total = n_lines,
    last_status = 'ok', last_error = '', last_result = link, last_sync_at = now(), updated_at = now()
   where id = p_id;
  return link;
end $$;

-- ---------- كل دقيقة: ينفّذ المزامنة المطلوبة أو اليومية (بانل واحد في كل مرة) ----------
create or replace function public.tv_panel_tick() returns void
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  p private.panels;
  now_r timestamp := private.riyadh_now();
begin
  select * into p from private.panels
   where enabled and api_key <> '' and base_url <> ''
     and ((requested_at is not null and (last_sync_started is null or requested_at > last_sync_started))
          or (extract(hour from now_r) >= sync_hour and last_sync_on is distinct from now_r::date))
   order by requested_at desc nulls last
   limit 1;
  if p.id is null then return; end if;

  update private.panels set last_sync_started = now(), last_sync_on = now_r::date where id = p.id;
  begin
    perform private.panel_sync(p.id);
  exception when others then
    update private.panels set last_status = 'error', last_error = sqlerrm, last_sync_at = now() where id = p.id;
  end;
end $$;
revoke all on function public.tv_panel_tick() from public, anon, authenticated;

-- ---------- أوامر اللوحة ----------
create or replace function public.get_panels() returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'base_url', case when public.is_owner() then base_url else '' end, 'has_key', api_key <> '',
      'enabled', enabled, 'sync_hour', sync_hour, 'credits', credits, 'account_name', account_name,
      'lines_total', lines_total, 'last_status', last_status, 'last_error', last_error, 'last_result', last_result,
      'last_sync_at', last_sync_at, 'requested_at', requested_at, 'last_sync_started', last_sync_started,
      'packages', packages) order by id) from private.panels), '[]'::jsonb);
end $$;

create or replace function public.set_panel(cfg jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
declare pid text := nullif(trim(cfg->>'id'), ''); url text;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  if pid is null then raise exception 'missing server id'; end if;
  -- الدومين والبورت بس (أي مسار بعدهم مثل رابط الدخول السري للبانل ينشال)
  url := coalesce(substring(trim(coalesce(cfg->>'base_url', '')) from '^(https?://[^/?#\s]+)'), '');
  if url <> '' and url !~* '^https://' then raise exception 'الرابط لازم يبدأ بـ https://'; end if;
  insert into private.panels (id) values (pid) on conflict (id) do nothing;
  update private.panels set
    base_url  = case when cfg ? 'base_url' then url else base_url end,
    api_key   = case when coalesce(trim(cfg->>'api_key'), '') <> '' then trim(cfg->>'api_key') else api_key end,
    enabled   = coalesce((cfg->>'enabled')::boolean, enabled),
    sync_hour = coalesce((cfg->>'sync_hour')::smallint, sync_hour),
    updated_at = now()
  where id = pid;
end $$;

create or replace function public.delete_panel(pid text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  delete from public.panel_lines where panel_id = pid;
  delete from private.panels where id = pid;
end $$;

-- اختبار الاتصال (فوري)
create or replace function public.test_panel(pid text) returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare p private.panels; r extensions.http_response; js jsonb;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  select * into p from private.panels where id = pid;
  if p.id is null or p.base_url = '' or p.api_key = '' then
    return jsonb_build_object('ok', false, 'error', 'حط رابط البانل ومفتاح الـ API واحفظ أول');
  end if;
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '6');
    r := extensions.http(('GET', p.base_url || '/api/reseller/v1/account',
      array[extensions.http_header('Authorization', 'Bearer ' || p.api_key)], null, null)::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'ما قدرنا نوصل للبانل: تأكد من الرابط والبورت (' || left(sqlerrm, 120) || ')');
  end;
  if r.status <> 200 then return jsonb_build_object('ok', false, 'error', private.panel_error(r)); end if;
  js := r.content::jsonb;
  update private.panels set credits = (js->>'credits')::numeric, account_name = coalesce(js->>'username', '') where id = pid;
  return jsonb_build_object('ok', true, 'credits', js->'credits', 'username', js->'username',
    'lines', js->'lines', 'sandbox', coalesce((js->>'sandbox')::boolean, false));
end $$;

-- يطلب مزامنة (تبدأ خلال دقيقة)
create or replace function public.request_panel_sync(pid text) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  update private.panels set requested_at = now() where id = pid;
end $$;

-- يعيد الربط بعد ما تغيّر يوزر زبون من اللوحة
create or replace function public.panel_relink(pid text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  return private.panel_link(pid);
end $$;

-- يستورد خطوط غير مربوطة كزبائن جدد
create or replace function public.import_panel_lines(pid text, line_ids bigint[]) returns int
language plpgsql security definer set search_path = public, private as $$
declare
  p private.panels;
  today date := private.riyadh_now()::date;
  n int := 0;
  l public.panel_lines;
  dur int; endd date; nm text;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  select * into p from private.panels where id = pid;
  for l in select * from public.panel_lines where panel_id = pid and customer_id is null and line_id = any (line_ids) loop
    continue when exists (select 1 from public.customers c where lower(c.line_user) = lower(l.username) and l.username <> '');
    select (x->>'duration_days')::int into dur from jsonb_array_elements(coalesce(p.packages, '[]'::jsonb)) x
     where (x->>'id')::bigint = l.package_id limit 1;
    endd := coalesce((l.expires_at at time zone 'Asia/Riyadh')::date, today + coalesce(dur, 365));
    nm := nullif(btrim(regexp_replace(translate(l.fullname, '٠١٢٣٤٥٦٧٨٩', '0123456789'), '(\+|00)?[0-9][0-9\s\-]{8,}[0-9]', '', 'g'), ' -_|،,'), '');
    insert into public.customers (name, phone, screen, app, pkg, start_date, end_date, line_user, line_pass,
                                  server_id, quality_done, notes, created_by)
    values (left(coalesce(nm, l.username, 'زبون من البانل'), 200), l.phone_found, 'android', 'ibo',
            case when l.is_trial then 'trial' else private.pkg_from_days(dur) end,
            least(today, endd - coalesce(dur, 365)), endd, l.username, l.password, pid, true,
            'مستورد من البانل (خط #' || l.line_id || ')', auth.uid());
    n := n + 1;
  end loop;
  perform private.panel_link(pid);
  return n;
end $$;

revoke all on function public.get_panels(), public.set_panel(jsonb), public.delete_panel(text), public.test_panel(text),
  public.request_panel_sync(text), public.panel_relink(text), public.import_panel_lines(text, bigint[]) from public, anon;
grant execute on function public.get_panels(), public.set_panel(jsonb), public.delete_panel(text), public.test_panel(text),
  public.request_panel_sync(text), public.panel_relink(text), public.import_panel_lines(text, bigint[]) to authenticated;

-- ---------- الجدولة: كل دقيقة يشيّك لو فيه مزامنة مطلوبة أو حان وقت اليومية ----------
select cron.schedule('tv-panel', '* * * * *', $$set statement_timeout to '300s'; select public.tv_panel_tick()$$);

-- ============================================================
-- تفعيل خط جديد وتجديده من اللوحة (يصرف كريدت، للمالك فقط)
-- ============================================================
create or replace function private.panel_post(p_base text, p_key text, p_path text, p_body jsonb, p_idem text) returns extensions.http_response
language plpgsql volatile as $$
declare r extensions.http_response; tries int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '6');
  loop
    r := extensions.http((
      'POST', rtrim(p_base, '/') || '/api/reseller/v1' || p_path,
      array[extensions.http_header('Authorization', 'Bearer ' || p_key),
            extensions.http_header('Idempotency-Key', p_idem),
            extensions.http_header('Accept', 'application/json')],
      'application/json', p_body::text)::extensions.http_request);
    exit when r.status <> 503 or tries >= 1;   -- operation_pending: نعيد بنفس المفتاح (ما يخصم مرتين)
    tries := tries + 1;
    perform pg_sleep(1);
  end loop;
  return r;
end $$;

-- اسم الخط في البانل: اسم الزبون + جواله (عشان المزامنة تلقط الجوال)
create or replace function private.panel_fullname(c public.customers) returns text
language sql stable as $$
  select left(btrim(c.name || case when c.phone ~ '^9665[0-9]{8}$' then ' 0' || substr(c.phone, 4)
                                    when c.phone <> '' then ' +' || c.phone else '' end), 64)
$$;

create or replace function private.panel_store_line(pid text, cid uuid, l jsonb) returns void
language plpgsql volatile as $$
begin
  insert into public.panel_lines (panel_id, line_id, username, password, fullname, package_id, expires_at, enabled, banned,
      is_trial, max_connections, active_connections, activates_on, playlist_host, phone_found, customer_id, synced_at)
  values (pid, (l->>'id')::bigint, coalesce(l->>'username', ''), coalesce(l->>'password', ''), coalesce(l->>'fullname', ''),
      nullif(l->>'package_id', '')::bigint, nullif(l->>'expires_at', '')::timestamptz, coalesce((l->>'enabled')::boolean, true),
      coalesce((l->>'banned')::boolean, false), coalesce((l->>'is_trial')::boolean, false), nullif(l->>'max_connections', '')::int,
      nullif(l->>'active_connections', '')::int, coalesce(l->>'activates_on', ''), coalesce(l->'playlist'->>'host', ''),
      private.extract_phone(l->>'fullname'), cid, now())
  on conflict (panel_id, line_id) do update set
    username = excluded.username, password = excluded.password, fullname = excluded.fullname, package_id = excluded.package_id,
    expires_at = excluded.expires_at, enabled = excluded.enabled, banned = excluded.banned, is_trial = excluded.is_trial,
    max_connections = excluded.max_connections, playlist_host = excluded.playlist_host, customer_id = cid, synced_at = now();
end $$;

create or replace function public.panel_create_line(pid text, cid uuid, package_id bigint, idem text) returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  p private.panels; c public.customers; r extensions.http_response; js jsonb; l jsonb; pk jsonb;
  dur int; endd date; host text; is_trial boolean;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  if coalesce(length(idem), 0) not between 8 and 100 then raise exception 'bad idempotency key'; end if;
  select * into p from private.panels where id = pid;
  if p.id is null or p.api_key = '' or p.base_url = '' then return jsonb_build_object('ok', false, 'error', 'البانل مو مربوط'); end if;
  select * into c from public.customers where id = cid;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'الزبون مو موجود'); end if;
  if c.panel_order_id <> '' then return jsonb_build_object('ok', false, 'error', 'هالزبون عنده خط انسوى من اللوحة أصلاً'); end if;
  select x into pk from jsonb_array_elements(coalesce(p.packages, '[]'::jsonb)) x where (x->>'id')::bigint = package_id limit 1;
  if pk is null then return jsonb_build_object('ok', false, 'error', 'الباقة مو موجودة. اضغط "مزامنة الحين" في تبويب البانل وجرّب'); end if;

  begin
    r := private.panel_post(p.base_url, p.api_key, '/orders/line',
      jsonb_build_object('package_id', package_id, 'external_ref', 'tvd-' || left(idem, 50),
                         'fullname', private.panel_fullname(c), 'note', 'لوحة عالم محمد تيفي'), idem);
  exception when others then
    return jsonb_build_object('ok', false, 'retry', true, 'error', 'ما وصل رد من البانل. اضغط نفس الزر مرة ثانية (ما بينخصم مرتين)');
  end;
  if r.status not in (200, 201) then
    return jsonb_build_object('ok', false, 'retry', r.status in (429, 500, 502, 503, 504), 'error', private.panel_error(r));
  end if;

  js := r.content::jsonb; l := js->'line';
  if l is null or coalesce(l->>'username', '') = '' then return jsonb_build_object('ok', false, 'error', 'البانل ما رجّع بيانات الخط'); end if;
  dur := nullif(pk->>'duration_days', '')::int;
  is_trial := coalesce((pk->>'is_trial')::boolean, false);
  endd := coalesce((nullif(l->>'expires_at', '')::timestamptz at time zone 'Asia/Riyadh')::date, private.riyadh_now()::date + coalesce(dur, 0));
  host := coalesce(l->'playlist'->>'host', '');

  update public.customers set line_user = l->>'username', line_pass = coalesce(l->>'password', ''), end_date = endd,
         panel_order_id = coalesce(js->>'id', ''), server_id = pid,
         pkg = case when is_trial then 'trial' else private.pkg_from_days(dur) end
   where id = cid;
  perform private.panel_store_line(pid, cid, l);
  update private.panels set credits = coalesce(nullif(js->>'remaining_credits', '')::numeric, credits) where id = pid;

  -- رابط السيرفر من البانل لو ما كان محطوط في الإعدادات
  if host <> '' then
    update public.settings set data = jsonb_set(data, '{servers}', (
        select jsonb_agg(case when x->>'id' = pid and coalesce(x->>'url', '') = '' then x || jsonb_build_object('url', host) else x end)
          from jsonb_array_elements(data->'servers') x))
     where id = 1 and jsonb_typeof(data->'servers') = 'array' and jsonb_array_length(data->'servers') > 0;
  end if;

  return jsonb_build_object('ok', true, 'username', l->>'username', 'password', l->>'password', 'host', host, 'end_date', endd,
    'charged', js->'charged_credits', 'remaining', js->'remaining_credits',
    'replayed', coalesce((js->>'replayed')::boolean, false), 'sandbox', coalesce((js->>'sandbox')::boolean, false));
end $$;

create or replace function public.panel_renew_line(pid text, cid uuid, package_id bigint, idem text) returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  p private.panels; c public.customers; r extensions.http_response; js jsonb; l jsonb; pk jsonb; endd date;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  if coalesce(length(idem), 0) not between 8 and 100 then raise exception 'bad idempotency key'; end if;
  select * into p from private.panels where id = pid;
  if p.id is null or p.api_key = '' or p.base_url = '' then return jsonb_build_object('ok', false, 'error', 'البانل مو مربوط'); end if;
  select * into c from public.customers where id = cid;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'الزبون مو موجود'); end if;
  if c.panel_order_id = '' then return jsonb_build_object('ok', false, 'error', 'هالخط ما انسوى من اللوحة، فتجديده يكون من البانل'); end if;
  select x into pk from jsonb_array_elements(coalesce(p.packages, '[]'::jsonb)) x where (x->>'id')::bigint = package_id limit 1;
  if pk is null then return jsonb_build_object('ok', false, 'error', 'الباقة مو موجودة. اضغط "مزامنة الحين" وجرّب'); end if;
  if coalesce((pk->>'is_trial')::boolean, false) then return jsonb_build_object('ok', false, 'error', 'باقات التجربة ما تتجدد'); end if;

  begin
    r := private.panel_post(p.base_url, p.api_key, '/orders/' || c.panel_order_id || '/renew',
      jsonb_build_object('package_id', package_id, 'external_ref', 'tvr-' || left(idem, 50)), idem);
  exception when others then
    return jsonb_build_object('ok', false, 'retry', true, 'error', 'ما وصل رد من البانل. اضغط نفس الزر مرة ثانية (ما بينخصم مرتين)');
  end;
  if r.status not in (200, 201) then
    return jsonb_build_object('ok', false, 'retry', r.status in (429, 500, 502, 503, 504), 'error', private.panel_error(r));
  end if;

  js := r.content::jsonb; l := js->'line';
  endd := (nullif(l->>'expires_at', '')::timestamptz at time zone 'Asia/Riyadh')::date;
  update public.customers set end_date = coalesce(endd, end_date), panel_order_id = coalesce(nullif(js->>'id', ''), panel_order_id),
         line_pass = coalesce(nullif(l->>'password', ''), line_pass),
         pkg = private.pkg_from_days(nullif(pk->>'duration_days', '')::int)
   where id = cid;
  if l is not null then perform private.panel_store_line(pid, cid, l); end if;
  update private.panels set credits = coalesce(nullif(js->>'remaining_credits', '')::numeric, credits) where id = pid;

  return jsonb_build_object('ok', true, 'old_end', c.end_date, 'end_date', coalesce(endd, c.end_date),
    'charged', js->'charged_credits', 'remaining', js->'remaining_credits',
    'replayed', coalesce((js->>'replayed')::boolean, false), 'sandbox', coalesce((js->>'sandbox')::boolean, false));
end $$;

revoke all on function public.panel_create_line(text, uuid, bigint, text), public.panel_renew_line(text, uuid, bigint, text) from public, anon;
grant execute on function public.panel_create_line(text, uuid, bigint, text), public.panel_renew_line(text, uuid, bigint, text) to authenticated;

