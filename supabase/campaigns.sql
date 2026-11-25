-- ============================================================
-- الحملات التلقائية (عبر Green-API)
-- يحتاج automation.sql يكون متشغل قبله.
-- الصق الملف كامل في: SQL Editor ← New query ← Run (تقدر تشغله أكثر من مرة)
--
-- طريقة الإرسال:
--   • عدد محدد كل ساعة (افتراضي 5)، وبين كل رسالة دقيقتين
--   • حد أقصى باليوم (افتراضي 40)، وفي نفس ساعات الإرسال المسموحة للتذكيرات
--   • التذكيرات لها أولوية على الحملات
--   • لو فشلت 3 رسائل ورا بعض، الحملة توقف لحالها ويوصلك تنبيه
--   • نص كل رسالة يتجهز في اللوحة (الصيغة تتغير كل 5 أشخاص + كلمات متبدلة)
--   • قوائم أرقام لكل سيرفر (الرقم يقدر يكون في أكثر من سيرفر)، و"لا ترسل له"
-- ============================================================

-- ---------- قوائم الأرقام (لكل سيرفر) ----------
create table if not exists public.contacts (
  phone      text primary key check (phone ~ '^[0-9]{10,15}$'),
  name       text not null default '' check (char_length(name) <= 200),
  servers    text[] not null default '{}',          -- أرقام السيرفرات من إعدادات اللوحة
  opted_out  boolean not null default false,        -- طلب ما نراسله
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id) on delete set null
);
create index if not exists contacts_servers_idx on public.contacts using gin (servers);
alter table public.contacts enable row level security;
drop policy if exists "staff read contacts" on public.contacts;
create policy "staff read contacts" on public.contacts for select to authenticated using (public.is_staff());
revoke all on public.contacts from anon;
revoke insert, update, delete on public.contacts from authenticated;
grant select on public.contacts to authenticated;

-- استيراد أرقام لقائمة سيرفر: items = [{phone, name}]
create or replace function public.contacts_import(p_server text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare n_valid int; n_had int; n_new int;
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  if coalesce(char_length(p_server), 0) not between 1 and 40 then raise exception 'bad server'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 20000 then raise exception 'bad items'; end if;
  create temp table if not exists _imp (phone text primary key, name text) on commit drop;
  truncate _imp;
  insert into _imp
  select distinct on (ph) ph, nm from (
    select regexp_replace(coalesce(e->>'phone', ''), '\D', '', 'g') as ph, left(btrim(coalesce(e->>'name', '')), 200) as nm
      from jsonb_array_elements(p_items) e) s
   where ph ~ '^[0-9]{10,15}$' order by ph, (nm = '');
  select count(*) into n_valid from _imp;
  select count(*) into n_had from _imp i join public.contacts c using (phone) where p_server = any (c.servers);
  select count(*) into n_new from _imp i where not exists (select 1 from public.contacts c where c.phone = i.phone);
  insert into public.contacts (phone, name, servers)
  select phone, name, array[p_server] from _imp
  on conflict (phone) do update set
    servers    = case when p_server = any (contacts.servers) then contacts.servers else contacts.servers || p_server end,
    name       = case when contacts.name = '' then excluded.name else contacts.name end,
    updated_at = now();
  return jsonb_build_object('added', n_valid - n_had, 'new', n_new, 'already', n_had,
                            'invalid', jsonb_array_length(p_items) - n_valid);
end $$;

-- إزالة أرقام من قائمة سيرفر (الرقم ينحذف لو ما بقى في أي قائمة وما عليه "لا ترسل له")
create or replace function public.contacts_remove(p_server text, p_phones text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  update public.contacts set servers = array_remove(servers, p_server), updated_at = now()
   where phone = any (p_phones) and p_server = any (servers);
  get diagnostics n = row_count;
  delete from public.contacts where phone = any (p_phones) and servers = '{}' and not opted_out;
  return n;
end $$;

-- "لا ترسل له" (أو إلغاؤها)
create or replace function public.contacts_optout(p_phone text, p_out boolean) returns void
language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  if ph !~ '^[0-9]{10,15}$' then raise exception 'bad phone'; end if;
  insert into public.contacts (phone, opted_out) values (ph, p_out)
  on conflict (phone) do update set opted_out = p_out, updated_at = now();
  if p_out then
    update public.camp_queue set status = 'skipped', error = 'طلب ما نراسله' where phone = ph and status = 'pending';
  end if;
end $$;

revoke all on function public.contacts_import(text, jsonb), public.contacts_remove(text, text[]), public.contacts_optout(text, boolean) from public, anon;
grant execute on function public.contacts_import(text, jsonb), public.contacts_remove(text, text[]), public.contacts_optout(text, boolean) to authenticated;

alter table private.notify_config add column if not exists camp_per_hour  smallint not null default 5;
alter table private.notify_config add column if not exists camp_gap_min   smallint not null default 2;
alter table private.notify_config add column if not exists camp_daily_cap smallint not null default 40;
alter table private.notify_config add column if not exists camp_next_at   timestamptz not null default now();

create table if not exists public.campaigns (
  id           bigserial primary key,
  title        text not null default '' check (char_length(title) <= 120),
  status       text not null default 'running' check (status in ('running', 'paused', 'done', 'cancelled')),
  fails_in_row smallint not null default 0,
  note         text not null default '',
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid() references auth.users(id) on delete set null
);
alter table public.campaigns add column if not exists server_id text not null default '';

create table if not exists public.camp_queue (
  id          bigserial primary key,
  campaign_id bigint not null references public.campaigns(id) on delete cascade,
  seq         int not null,
  phone       text not null check (phone ~ '^[0-9]{10,15}$'),
  name        text not null default '' check (char_length(name) <= 200),
  variant     smallint not null default 1,
  body        text not null check (char_length(body) between 1 and 4000),
  status      text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  request_id  bigint,
  error       text not null default '',
  sent_at     timestamptz,
  unique (campaign_id, phone)
);
create index if not exists camp_queue_next_idx on public.camp_queue (campaign_id, status, seq);
create index if not exists camp_queue_sent_idx on public.camp_queue (sent_at);
create index if not exists camp_queue_phone_idx on public.camp_queue (phone);

alter table public.campaigns  enable row level security;
alter table public.camp_queue enable row level security;
drop policy if exists "staff read campaigns"  on public.campaigns;
drop policy if exists "staff read camp_queue" on public.camp_queue;
create policy "staff read campaigns"  on public.campaigns  for select to authenticated using (public.is_staff());
create policy "staff read camp_queue" on public.camp_queue for select to authenticated using (public.is_staff());
-- الكتابة عن طريق الأوامر تحت بس
revoke all on public.campaigns, public.camp_queue from anon;
revoke insert, update, delete on public.campaigns, public.camp_queue from authenticated;
grant select on public.campaigns, public.camp_queue to authenticated;

-- ---------- كل دقيقة: يتأكد من اللي انرسل، ويرسل التالي ----------
create or replace function public.tv_camp_tick() returns void
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  cfg private.notify_config;
  r record;
  hr int := extract(hour from private.riyadh_now())::int;
  day_start timestamptz := date_trunc('day', private.riyadh_now()) at time zone 'Asia/Riyadh';
  nxt public.camp_queue;
  req bigint;
begin
  select * into cfg from private.notify_config where id = 1;

  -- 1) نتائج الرسائل اللي انرسلت
  for r in
    select q.id, q.campaign_id, h.status_code, h.error_msg, left(coalesce(h.content, ''), 300) as content
      from public.camp_queue q join net._http_response h on h.id = q.request_id
     where q.status = 'sending'
  loop
    if r.status_code between 200 and 299 and position('"idMessage"' in r.content) > 0 then
      update public.camp_queue set status = 'sent' where id = r.id;
      update public.campaigns set fails_in_row = 0 where id = r.campaign_id;
    else
      update public.camp_queue set status = 'failed',
        error = btrim(coalesce(r.error_msg, '') || ' ' || coalesce(r.status_code::text, '') || ' ' || r.content) where id = r.id;
      update public.campaigns set fails_in_row = fails_in_row + 1 where id = r.campaign_id;
    end if;
  end loop;
  for r in update public.camp_queue set status = 'failed', error = 'ما وصل رد من واتساب'
            where status = 'sending' and sent_at < now() - interval '15 minutes' returning campaign_id
  loop
    update public.campaigns set fails_in_row = fails_in_row + 1 where id = r.campaign_id;
  end loop;

  -- 2) توقف تلقائي لو فشلت 3 ورا بعض، وإنهاء الحملات اللي خلصت
  for r in update public.campaigns set status = 'paused',
             note = 'توقفت لحالها: 3 رسائل فشلت ورا بعض. شيّك على ربط واتساب ثم كمّلها.'
            where status = 'running' and fails_in_row >= 3 returning title
  loop
    begin perform private.send_owner('⚠️ توقفت حملة "' || r.title || '" لحالها لأن 3 رسائل فشلت ورا بعض. شيّك على ربط واتساب.');
    exception when others then null; end;
  end loop;
  for r in update public.campaigns c set status = 'done'
            where c.status = 'running'
              and not exists (select 1 from public.camp_queue q where q.campaign_id = c.id and q.status in ('pending', 'sending'))
            returning c.id, c.title
  loop
    begin perform private.send_owner('✅ خلصت حملة "' || r.title || '": انرسل '
      || (select count(*) from public.camp_queue where campaign_id = r.id and status = 'sent') || ' رسالة.');
    exception when others then null; end;
  end loop;

  -- 3) إرسال الرسالة التالية
  if cfg.wa_instance = '' or cfg.wa_token = '' then return; end if;
  if hr < cfg.send_from_hour or hr >= cfg.send_to_hour then return; end if;
  if now() < cfg.camp_next_at then return; end if;
  if exists (select 1 from public.camp_queue where status = 'sending') then return; end if;
  -- التذكيرات أول
  if exists (select 1 from public.outbox where status = 'sending'
                or (status = 'pending' and send_after <= now())
                or sent_at > now() - interval '50 seconds') then return; end if;
  -- الحد بالساعة وباليوم (لكل الحملات مع بعض)
  if (select count(*) from public.camp_queue where sent_at >= date_trunc('hour', now())) >= cfg.camp_per_hour then return; end if;
  if (select count(*) from public.camp_queue where sent_at >= day_start) >= cfg.camp_daily_cap then return; end if;

  select q.* into nxt from public.camp_queue q join public.campaigns c on c.id = q.campaign_id
   where c.status = 'running' and q.status = 'pending'
   order by c.id, q.seq limit 1 for update of q skip locked;
  if nxt.id is null then return; end if;

  -- نتجاوز الرقم لو طلب ما نراسله
  if exists (select 1 from public.contacts where phone = nxt.phone and opted_out) then
    update public.camp_queue set status = 'skipped', error = 'طلب ما نراسله' where id = nxt.id;
    return;
  end if;
  -- نتجاوز الرقم لو صار زبون نشط بعد ما بدأت الحملة
  if exists (select 1 from public.customers where phone = nxt.phone and not example
               and end_date >= private.riyadh_now()::date) then
    update public.camp_queue set status = 'skipped', error = 'صار زبون نشط' where id = nxt.id;
    return;
  end if;

  update private.notify_config
     set camp_next_at = now() + make_interval(secs => greatest(cfg.camp_gap_min, 1) * 60 - 15)
   where id = 1;
  begin
    req := private.send_whatsapp(nxt.phone, nxt.body);
    update public.camp_queue set status = 'sending', request_id = req, sent_at = now() where id = nxt.id;
  exception when others then
    update public.camp_queue set status = 'failed', error = sqlerrm, sent_at = now() where id = nxt.id;
    update public.campaigns set fails_in_row = fails_in_row + 1 where id = nxt.campaign_id;
  end;
end $$;
revoke all on function public.tv_camp_tick() from public, anon, authenticated;

-- ---------- أوامر اللوحة ----------
-- إنشاء حملة: items = [{phone, name, body, variant}]
drop function if exists public.camp_create(text, jsonb);
create or replace function public.camp_create(p_title text, p_items jsonb, p_server text default '') returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  cfg private.notify_config;
  cid bigint; n_in int; n_add int; n_recent int;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  select * into cfg from private.notify_config where id = 1;
  if cfg.wa_instance = '' or cfg.wa_token = '' then raise exception 'WhatsApp (Green-API) is not configured'; end if;
  if jsonb_typeof(p_items) <> 'array' then raise exception 'bad items'; end if;
  n_in := jsonb_array_length(p_items);
  if n_in = 0 or n_in > 3000 then raise exception 'items must be 1..3000'; end if;

  insert into public.campaigns (title, server_id)
  values (left(coalesce(nullif(btrim(p_title), ''), 'حملة'), 120), left(coalesce(p_server, ''), 40)) returning id into cid;

  with src as (
    select regexp_replace(coalesce(e->>'phone', ''), '\D', '', 'g') as phone,
           left(coalesce(e->>'name', ''), 200) as name,
           left(coalesce(e->>'body', ''), 4000) as body,
           coalesce((e->>'variant')::smallint, 1) as variant, o as seq
      from jsonb_array_elements(p_items) with ordinality as t(e, o)
  ), ok as (
    select * from src
     where phone ~ '^[0-9]{10,15}$' and btrim(body) <> ''
       and not exists (select 1 from public.contacts k where k.phone = src.phone and k.opted_out)
       -- ما نرسل لرقم وصلته رسالة حملة خلال آخر 3 أيام
       and not exists (select 1 from public.camp_queue q where q.phone = src.phone
                         and q.status in ('sent', 'sending', 'pending') and coalesce(q.sent_at, now()) > now() - interval '3 days'
                         and q.campaign_id <> cid)
  ), ins as (
    insert into public.camp_queue (campaign_id, seq, phone, name, variant, body)
    select cid, seq, phone, name, variant, body from ok
    on conflict (campaign_id, phone) do nothing
    returning 1
  )
  select (select count(*) from ins),
         (select count(*) from src where phone ~ '^[0-9]{10,15}$' and btrim(body) <> '') - (select count(*) from ok)
    into n_add, n_recent;

  if n_add = 0 then delete from public.campaigns where id = cid; cid := null; end if;
  return jsonb_build_object('id', cid, 'added', n_add, 'recent', n_recent, 'invalid', n_in - n_add - n_recent);
end $$;

-- إيقاف مؤقت / تكملة / إلغاء
create or replace function public.camp_control(p_id bigint, p_action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  if p_action = 'pause' then
    update public.campaigns set status = 'paused', note = '' where id = p_id and status = 'running';
  elsif p_action = 'resume' then
    update public.campaigns set status = 'running', fails_in_row = 0, note = '' where id = p_id and status = 'paused';
  elsif p_action = 'cancel' then
    update public.campaigns set status = 'cancelled', note = '' where id = p_id and status in ('running', 'paused');
    update public.camp_queue set status = 'skipped', error = 'انلغت الحملة' where campaign_id = p_id and status = 'pending';
  elsif p_action = 'retry_failed' then
    update public.camp_queue set status = 'pending', error = '', request_id = null, sent_at = null
     where campaign_id = p_id and status = 'failed';
    update public.campaigns set status = 'running', fails_in_row = 0, note = '' where id = p_id and status in ('paused', 'done');
  else
    raise exception 'bad action';
  end if;
end $$;

-- الإعدادات والحالة
create or replace function public.camp_overview() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare
  cfg private.notify_config;
  day_start timestamptz := date_trunc('day', private.riyadh_now()) at time zone 'Asia/Riyadh';
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  select * into cfg from private.notify_config where id = 1;
  return jsonb_build_object(
    'wa_ok', cfg.wa_instance <> '' and cfg.wa_token <> '',
    'per_hour', cfg.camp_per_hour, 'gap_min', cfg.camp_gap_min, 'daily_cap', cfg.camp_daily_cap,
    'from_hour', cfg.send_from_hour, 'to_hour', cfg.send_to_hour,
    'sent_today', (select count(*) from public.camp_queue where sent_at >= day_start),
    'sent_hour',  (select count(*) from public.camp_queue where sent_at >= date_trunc('hour', now())),
    'campaigns', coalesce((select jsonb_agg(x order by x.id desc) from (
       select c.id, c.title, c.status, c.note, c.created_at, c.server_id,
              -- كم واحد صار زبون (انضاف أو دفع) خلال 14 يوم من رسالته
              (select count(distinct q2.phone) from public.camp_queue q2
                where q2.campaign_id = c.id and q2.status = 'sent'
                  and exists (select 1 from public.customers cu where cu.phone = q2.phone and not cu.example
                                and (cu.created_at between q2.sent_at and q2.sent_at + interval '14 days'
                                     or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(cu.payments) = 'array' then cu.payments else '[]' end) p
                                                 where p->>'date' ~ '^\d{4}-\d{2}-\d{2}$'
                                                   and (p->>'date')::date between (q2.sent_at at time zone 'Asia/Riyadh')::date
                                                                              and (q2.sent_at at time zone 'Asia/Riyadh')::date + 14)))) as converted,
              count(*) filter (where q.status = 'pending')  as pending,
              count(*) filter (where q.status = 'sending')  as sending,
              count(*) filter (where q.status = 'sent')     as sent,
              count(*) filter (where q.status = 'failed')   as failed,
              count(*) filter (where q.status = 'skipped')  as skipped,
              max(q.sent_at) as last_at,
              (array_agg(q.error order by q.sent_at desc) filter (where q.status = 'failed'))[1] as last_error
         from public.campaigns c left join public.camp_queue q on q.campaign_id = c.id
        group by c.id order by c.id desc limit 15) x), '[]'::jsonb));
end $$;

create or replace function public.camp_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  update private.notify_config set
    camp_per_hour  = least(greatest(coalesce((p->>'per_hour')::smallint,  camp_per_hour),  1), 30),
    camp_gap_min   = least(greatest(coalesce((p->>'gap_min')::smallint,   camp_gap_min),   1), 30),
    camp_daily_cap = least(greatest(coalesce((p->>'daily_cap')::smallint, camp_daily_cap), 1), 300)
  where id = 1;
end $$;

-- تجربة: يرسل رسالة وحدة لرقمك عبر Green-API، ويرجع رقم الطلب (تتابعه بـ request_result)
create or replace function public.camp_test(p_phone text, p_body text) returns bigint
language plpgsql security definer set search_path = public, private, extensions as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  if ph !~ '^[0-9]{10,15}$' then raise exception 'bad phone'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'empty body'; end if;
  return private.send_whatsapp(ph, left(p_body, 4000));
end $$;

revoke all on function public.camp_create(text, jsonb, text), public.camp_control(bigint, text), public.camp_overview(),
  public.camp_settings(jsonb), public.camp_test(text, text) from public, anon;
grant execute on function public.camp_create(text, jsonb, text), public.camp_control(bigint, text), public.camp_overview(),
  public.camp_settings(jsonb), public.camp_test(text, text) to authenticated;

-- ---------- الجدولة ----------
select cron.schedule('tv-camp', '* * * * *', 'select public.tv_camp_tick()');
