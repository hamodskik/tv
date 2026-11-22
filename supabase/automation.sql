-- ============================================================
-- لوحة زبائن عالم محمد تيفي: الأتمتة
--   ☀️ ملخص الصبح للمالك (تيليجرام أو واتساب)
--   🤖 تذكيرات تلقائية للزبائن عبر واتساب (Green-API)، رسالة وحدة كل دقيقة تقريباً
-- شغّله بعد schema.sql في: SQL Editor ← New query ← Run
-- تقدر تشغله أكثر من مرة بدون ما يخرب شي.
-- الإعدادات (التوكنات والأوقات) تنضبط من اللوحة: الإعدادات ← الأتمتة
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- مخطط خاص ما ينوصل له من الإنترنت (التوكنات هنا)
create schema if not exists private;
revoke all on schema private from public;
do $$ begin
  execute 'revoke all on schema private from anon, authenticated';
exception when undefined_object then null; end $$;

create table if not exists private.notify_config (
  id               smallint primary key default 1 check (id = 1),
  summary_enabled  boolean  not null default false,
  summary_hour     smallint not null default 10 check (summary_hour between 0 and 23),
  summary_channel  text     not null default 'telegram' check (summary_channel in ('telegram', 'whatsapp')),
  telegram_token   text     not null default '',
  telegram_chat_id text     not null default '',
  wa_api_url       text     not null default 'https://api.green-api.com',
  wa_instance      text     not null default '',
  wa_token         text     not null default '',
  owner_phone      text     not null default '',
  auto_enabled     boolean  not null default false,
  auto_hour        smallint not null default 11 check (auto_hour between 0 and 23),
  auto_kinds       text[]   not null default array['d7','d3','d1','expired','quality','trialEnd'],
  send_from_hour   smallint not null default 9,
  send_to_hour     smallint not null default 23,
  last_summary_on  date,
  last_auto_on     date,
  updated_at       timestamptz not null default now()
);
insert into private.notify_config (id) values (1) on conflict (id) do nothing;

-- ---------- طابور الرسائل التلقائية ----------
create table if not exists public.outbox (
  id          bigserial primary key,
  customer_id uuid not null references public.customers(id) on delete cascade,
  name        text not null default '',
  phone       text not null,
  kind        text not null,
  sent_key    text not null,
  body        text not null,
  send_after  timestamptz not null default now(),
  status      text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'cancelled')),
  request_id  bigint,
  error       text not null default '',
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create unique index if not exists outbox_once_idx on public.outbox (customer_id, sent_key)
  where status in ('pending', 'sending', 'sent');
create index if not exists outbox_status_idx on public.outbox (status, send_after);

alter table public.outbox enable row level security;
drop policy if exists "staff read outbox"   on public.outbox;
drop policy if exists "owner cancel outbox" on public.outbox;
create policy "staff read outbox"   on public.outbox for select to authenticated using (public.is_staff());
create policy "owner cancel outbox" on public.outbox for update to authenticated
  using (public.is_owner() and status = 'pending') with check (public.is_owner() and status = 'cancelled');
revoke all on public.outbox from anon;
revoke insert, delete on public.outbox from authenticated;

-- ---------- أدوات ----------
create or replace function private.riyadh_now() returns timestamp
language sql stable as $$ select now() at time zone 'Asia/Riyadh' $$;

create or replace function private.ar_date(d date) returns text
language sql immutable as $$
  select extract(day from d)::int || ' ' ||
    (array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'])[extract(month from d)::int]
    || ' ' || extract(year from d)::int
$$;

create or replace function private.days_word(n int) returns text
language sql immutable as $$
  select case when n = 1 then 'يوم واحد' when n = 2 then 'يومين'
              when n between 3 and 10 then n || ' أيام' else n || ' يوم' end
$$;

create or replace function private.screen_label(s text) returns text
language sql immutable as $$
  select case s when 'android' then 'أندرويد / TV Box' when 'lg' then 'شاشة LG' when 'samsung' then 'شاشة سامسونج'
    when 'iphone' then 'آيفون / آيباد' when 'phone' then 'جوال أندرويد' when 'pc' then 'كمبيوتر' else 'جهاز ثاني' end
$$;

create or replace function private.pkg_label(p text) returns text
language sql immutable as $$
  select case p when 'trial' then 'تجربة 24 ساعة' when '1m' then 'شهر' when '3m' then '3 شهور'
    when '6m' then '6 شهور' when '12m' then 'سنة' else coalesce(p, '—') end
$$;

-- يعبي متغيرات القالب، ويشيل سطر رابط الدفع أو بيانات الدخول لو فاضي
create or replace function private.fill_template(src text, c public.customers, s jsonb) returns text
language plpgsql stable as $$
declare
  today date := private.riyadh_now()::date;
  d int := c.end_date - today;
  pay text := coalesce(s->>'payLink', '');
  login text := '';
  app_label text := case coalesce(c.app, 'ibo') when 'ibo' then 'IBO Player' when 'smarters' then 'IPTV Smarters' else 'التطبيق' end;
  lines text[];
  out text[] := '{}';
  l text;
begin
  if coalesce(c.app, 'ibo') <> 'ibo' then
    login := concat_ws(E'\n',
      case when coalesce(s->>'serverUrl', '') <> '' and c.line_user <> '' then '🌐 السيرفر: ' || (s->>'serverUrl') end,
      case when c.line_user <> '' then '👤 Username: ' || c.line_user end,
      case when c.line_pass <> '' then '🔑 Password: ' || c.line_pass end);
  end if;
  lines := string_to_array(src, E'\n');
  foreach l in array coalesce(lines, '{}') loop
    if (position('{رابط_الدفع}' in l) > 0 and pay = '') or (position('{بيانات_الدخول}' in l) > 0 and login = '') then
      continue;
    end if;
    out := out || l;
  end loop;
  src := array_to_string(out, E'\n');
  src := replace(src, '{الاسم}', c.name);
  src := replace(src, '{الجهاز}', coalesce(nullif(c.mac, ''), private.screen_label(c.screen)));
  src := replace(src, '{الانتهاء}', private.ar_date(c.end_date));
  src := replace(src, '{المتبقي}', private.days_word(greatest(d, 0)));
  src := replace(src, '{متى}', case when d <= 0 then 'اليوم' else 'بكرة' end);
  src := replace(src, '{الباقة}', private.pkg_label(c.pkg));
  src := replace(src, '{المتجر}', coalesce(s->>'store', 'عالم محمد تيفي'));
  src := replace(src, '{السيرفر}', coalesce(s->>'server', 'سيرفر فولتشر'));
  src := replace(src, '{رابط_الدفع}', pay);
  src := replace(src, '{التطبيق}', app_label);
  src := replace(src, '{بيانات_الدخول}', login);
  return btrim(src, E' \n');
end $$;

-- يختار صيغة عشوائية من القالب (الصيغ مفصولة بسطر ---)
create or replace function private.pick_variant(src text) returns text
language plpgsql volatile as $$
declare parts text[];
begin
  parts := regexp_split_to_array(coalesce(src, ''), E'\\n\\s*-{3,}\\s*\\n');
  parts := array(select btrim(p) from unnest(parts) p where btrim(p) <> '');
  if coalesce(array_length(parts, 1), 0) = 0 then return null; end if;
  return parts[1 + floor(random() * array_length(parts, 1))::int];
end $$;

-- ---------- الإرسال ----------
create or replace function private.http_json(url text, payload jsonb) returns bigint
language sql volatile as $$
  select net.http_post(url := url, body := payload,
    headers := jsonb_build_object('Content-Type', 'application/json'), timeout_milliseconds := 15000)
$$;

create or replace function private.send_whatsapp(phone text, msg text) returns bigint
language plpgsql volatile as $$
declare cfg private.notify_config;
begin
  select * into cfg from private.notify_config where id = 1;
  if cfg.wa_instance = '' or cfg.wa_token = '' then raise exception 'WhatsApp (Green-API) is not configured'; end if;
  return private.http_json(
    rtrim(cfg.wa_api_url, '/') || '/waInstance' || cfg.wa_instance || '/sendMessage/' || cfg.wa_token,
    jsonb_build_object('chatId', regexp_replace(phone, '\D', '', 'g') || '@c.us', 'message', msg));
end $$;

create or replace function private.send_owner(msg text) returns bigint
language plpgsql volatile as $$
declare cfg private.notify_config;
begin
  select * into cfg from private.notify_config where id = 1;
  if cfg.summary_channel = 'telegram' then
    if cfg.telegram_token = '' or cfg.telegram_chat_id = '' then raise exception 'Telegram is not configured'; end if;
    return private.http_json('https://api.telegram.org/bot' || cfg.telegram_token || '/sendMessage',
      jsonb_build_object('chat_id', cfg.telegram_chat_id, 'text', msg, 'disable_web_page_preview', true));
  else
    if cfg.owner_phone = '' then raise exception 'Owner phone is not set'; end if;
    return private.send_whatsapp(cfg.owner_phone, msg);
  end if;
end $$;

-- ---------- ملخص الصبح ----------
create or replace function private.build_summary() returns text
language plpgsql stable as $$
declare
  today date := private.riyadh_now()::date;
  s jsonb := coalesce((select data from public.settings where id = 1), '{}'::jsonb);
  cur text := coalesce(nullif(s->>'currency', ''), 'ر.س');
  n_active int; n_urgent int; n_d3 int; n_d7 int; n_lost int; n_quality int; n_queue int;
  urgent_names text; d3_names text; lost_names text; revenue numeric;
  url text := coalesce(nullif(s->>'dashboardUrl', ''), 'https://hamodskik.github.io/tv/');
  msg text;
begin
  select count(*) filter (where end_date >= today),
         count(*) filter (where end_date - today between 0 and 1),
         count(*) filter (where end_date - today between 2 and 3),
         count(*) filter (where end_date - today between 4 and 7),
         count(*) filter (where end_date - today between -14 and -1),
         count(*) filter (where not quality_done and today - start_date between 2 and 10 and end_date >= today and pkg <> 'trial')
    into n_active, n_urgent, n_d3, n_d7, n_lost, n_quality
    from public.customers where not example;

  select string_agg(name, '، ' order by end_date) into urgent_names
    from (select name, end_date from public.customers where not example and end_date - today between 0 and 1 order by end_date limit 8) x;
  select string_agg(name, '، ' order by end_date) into d3_names
    from (select name, end_date from public.customers where not example and end_date - today between 2 and 3 order by end_date limit 8) x;
  select string_agg(name, '، ' order by end_date desc) into lost_names
    from (select name, end_date from public.customers where not example and end_date - today between -14 and -1 order by end_date desc limit 8) x;

  select coalesce(sum((p->>'amount')::numeric), 0) into revenue
    from public.customers c, jsonb_array_elements(c.payments) p
   where not c.example and left(p->>'date', 7) = to_char(today, 'YYYY-MM') and (p->>'amount') ~ '^[0-9.]+$';

  select count(*) into n_queue from public.outbox
   where status in ('pending', 'sending') and (send_after at time zone 'Asia/Riyadh')::date = today;

  msg := '☀️ صباح الخير!' || E'\n' || 'ملخص ' || coalesce(s->>'store', 'عالم محمد تيفي') || ' | ' || private.ar_date(today) || E'\n\n'
    || '🟢 نشط: ' || n_active || E'\n'
    || '🔴 ينتهون اليوم أو بكرة: ' || n_urgent || coalesce(E'\n   ' || urgent_names, '') || E'\n'
    || '🟠 خلال 2–3 أيام: ' || n_d3 || coalesce(E'\n   ' || d3_names, '') || E'\n'
    || '🟡 خلال 4–7 أيام: ' || n_d7 || E'\n'
    || '⚫ انتهوا وما جددوا (آخر أسبوعين): ' || n_lost || coalesce(E'\n   ' || lost_names, '') || E'\n'
    || '⭐ يحتاجون فحص جودة: ' || n_quality || E'\n'
    || '💰 دخل هالشهر: ' || trim(to_char(revenue, 'FM999,999,990')) || ' ' || cur;
  if n_queue > 0 then
    msg := msg || E'\n' || '🤖 رسائل تلقائية مجدولة اليوم: ' || n_queue;
  end if;
  if n_urgent = 0 and n_d3 = 0 and n_lost = 0 then
    msg := msg || E'\n\n' || '✅ ما فيه شي عاجل اليوم';
  end if;
  return msg || E'\n\n' || '👉 ' || url;
end $$;

-- ---------- تجهيز التذكيرات اليومية ----------
create or replace function private.enqueue_reminders() returns int
language plpgsql volatile as $$
declare
  cfg private.notify_config;
  today date := private.riyadh_now()::date;
  s jsonb := coalesce((select data from public.settings where id = 1), '{}'::jsonb);
  tone text;
  c public.customers;
  d int; k text; key text; src text; body text;
  kinds text[];
  slot timestamptz := now() + interval '1 minute';
  n int := 0;
begin
  select * into cfg from private.notify_config where id = 1;
  if cfg.wa_instance = '' or cfg.wa_token = '' then raise exception 'WhatsApp (Green-API) is not configured'; end if;
  tone := coalesce(nullif(s->>'tone', ''), 'friendly');

  for c in select * from public.customers where not example and phone <> '' order by end_date loop
    d := c.end_date - today;
    kinds := '{}';
    if c.pkg = 'trial' then
      if d between -7 and -1 then kinds := array_append(kinds, 'trialEnd'); end if;
    elsif d between -14 and -1 then kinds := array_append(kinds, 'expired');
    elsif d between 0 and 1 then kinds := array_append(kinds, 'd1');
    elsif d between 2 and 3 and not c.sent ? ('d1@' || c.end_date) then kinds := array_append(kinds, 'd3');
    elsif d between 4 and 7 and not (c.sent ? ('d3@' || c.end_date) or c.sent ? ('d1@' || c.end_date)) then kinds := array_append(kinds, 'd7');
    end if;
    if not c.quality_done and c.pkg <> 'trial' and d >= 0 and today - c.start_date between 2 and 10 then
      kinds := array_append(kinds, 'quality');
    end if;

    foreach k in array kinds loop
      continue when not (k = any (cfg.auto_kinds));
      key := k || '@' || c.end_date;
      continue when k <> 'quality' and c.sent ? key;
      continue when exists (select 1 from public.outbox o where o.customer_id = c.id and o.sent_key = key
                            and o.status in ('pending', 'sending', 'sent'));
      src := coalesce(s->'resolvedTemplates'->k->>tone, s->'resolvedTemplates'->k->>'friendly');
      continue when src is null;
      body := private.fill_template(private.pick_variant(src), c, s);
      continue when body is null or body = '';
      insert into public.outbox (customer_id, name, phone, kind, sent_key, body, send_after)
      values (c.id, c.name, c.phone, k, key, body, slot);
      slot := slot + make_interval(secs => 60 + floor(random() * 61)::int);  -- فاصل 1–2 دقيقة بين كل رسالة
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- ---------- المعالجة كل دقيقة: يتأكد من اللي انرسل، ويرسل التالي ----------
create or replace function public.tv_tick_minute() returns void
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  cfg private.notify_config;
  r record;
  hr int := extract(hour from private.riyadh_now())::int;
  nxt public.outbox;
  req bigint;
begin
  select * into cfg from private.notify_config where id = 1;

  -- 1) نتائج الرسائل اللي انرسلت
  for r in
    select o.id, o.customer_id, o.kind, o.sent_key, h.status_code, h.error_msg, left(coalesce(h.content, ''), 300) as content
      from public.outbox o join net._http_response h on h.id = o.request_id
     where o.status = 'sending'
  loop
    if r.status_code between 200 and 299 and position('"idMessage"' in r.content) > 0 then
      update public.outbox set status = 'sent' where id = r.id;
      if r.kind = 'quality' then
        update public.customers set quality_done = true where id = r.customer_id;
      else
        update public.customers set sent = sent || jsonb_build_object(r.sent_key, private.riyadh_now()::date::text)
         where id = r.customer_id;
      end if;
    else
      update public.outbox set status = 'failed',
        error = coalesce(r.error_msg, '') || ' ' || coalesce(r.status_code::text, '') || ' ' || r.content where id = r.id;
    end if;
  end loop;
  update public.outbox set status = 'failed', error = 'ما وصل رد من واتساب'
   where status = 'sending' and sent_at < now() - interval '15 minutes';

  -- 2) إرسال الرسالة التالية (وحدة بس كل دقيقة، وفي الأوقات المسموحة)
  if hr < cfg.send_from_hour or hr >= cfg.send_to_hour then return; end if;
  if exists (select 1 from public.outbox where status = 'sending') then return; end if;
  if exists (select 1 from public.outbox where sent_at > now() - interval '50 seconds') then return; end if;

  select * into nxt from public.outbox
   where status = 'pending' and send_after <= now()
   order by send_after limit 1 for update skip locked;
  if nxt.id is null then return; end if;

  begin
    req := private.send_whatsapp(nxt.phone, nxt.body);
    update public.outbox set status = 'sending', request_id = req, sent_at = now() where id = nxt.id;
  exception when others then
    update public.outbox set status = 'failed', error = sqlerrm, sent_at = now() where id = nxt.id;
  end;
end $$;

-- ---------- كل ساعة: ملخص الصبح + تجهيز التذكيرات ----------
create or replace function public.tv_tick_hourly() returns void
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  cfg private.notify_config;
  now_r timestamp := private.riyadh_now();
begin
  select * into cfg from private.notify_config where id = 1;

  if cfg.auto_enabled and extract(hour from now_r) >= cfg.auto_hour
     and cfg.last_auto_on is distinct from now_r::date then
    update private.notify_config set last_auto_on = now_r::date where id = 1;
    begin perform private.enqueue_reminders(); exception when others then null; end;
  end if;

  if cfg.summary_enabled and extract(hour from now_r) >= cfg.summary_hour
     and cfg.last_summary_on is distinct from now_r::date then
    update private.notify_config set last_summary_on = now_r::date where id = 1;
    begin perform private.send_owner(private.build_summary()); exception when others then null; end;
  end if;
end $$;

revoke all on function public.tv_tick_minute() from public, anon, authenticated;
revoke all on function public.tv_tick_hourly() from public, anon, authenticated;

-- ---------- أوامر اللوحة (للمالك فقط) ----------
create or replace function public.get_automation() returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare cfg private.notify_config;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  select * into cfg from private.notify_config where id = 1;
  return jsonb_build_object(
    'summary_enabled', cfg.summary_enabled, 'summary_hour', cfg.summary_hour, 'summary_channel', cfg.summary_channel,
    'telegram_chat_id', cfg.telegram_chat_id, 'has_telegram_token', cfg.telegram_token <> '',
    'wa_api_url', cfg.wa_api_url, 'wa_instance', cfg.wa_instance, 'has_wa_token', cfg.wa_token <> '',
    'owner_phone', cfg.owner_phone,
    'auto_enabled', cfg.auto_enabled, 'auto_hour', cfg.auto_hour, 'auto_kinds', to_jsonb(cfg.auto_kinds),
    'send_from_hour', cfg.send_from_hour, 'send_to_hour', cfg.send_to_hour,
    'last_summary_on', cfg.last_summary_on, 'last_auto_on', cfg.last_auto_on);
end $$;

create or replace function public.set_automation(cfg jsonb) returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  update private.notify_config set
    summary_enabled  = coalesce((cfg->>'summary_enabled')::boolean, summary_enabled),
    summary_hour     = coalesce((cfg->>'summary_hour')::smallint, summary_hour),
    summary_channel  = coalesce(cfg->>'summary_channel', summary_channel),
    telegram_chat_id = coalesce(cfg->>'telegram_chat_id', telegram_chat_id),
    telegram_token   = case when coalesce(cfg->>'telegram_token', '') <> '' then cfg->>'telegram_token' else telegram_token end,
    wa_api_url       = coalesce(nullif(cfg->>'wa_api_url', ''), wa_api_url),
    wa_instance      = coalesce(cfg->>'wa_instance', wa_instance),
    wa_token         = case when coalesce(cfg->>'wa_token', '') <> '' then cfg->>'wa_token' else wa_token end,
    owner_phone      = coalesce(regexp_replace(cfg->>'owner_phone', '\D', '', 'g'), owner_phone),
    auto_enabled     = coalesce((cfg->>'auto_enabled')::boolean, auto_enabled),
    auto_hour        = coalesce((cfg->>'auto_hour')::smallint, auto_hour),
    auto_kinds       = case when jsonb_typeof(cfg->'auto_kinds') = 'array'
                            then array(select jsonb_array_elements_text(cfg->'auto_kinds')) else auto_kinds end,
    send_from_hour   = coalesce((cfg->>'send_from_hour')::smallint, send_from_hour),
    send_to_hour     = coalesce((cfg->>'send_to_hour')::smallint, send_to_hour),
    updated_at       = now()
  where id = 1;
end $$;

-- يرسل ملخص الصبح الحين (تجربة)، ويرجع رقم الطلب عشان اللوحة تشوف النتيجة
create or replace function public.send_summary_now() returns bigint
language plpgsql security definer set search_path = public, private, extensions as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  return private.send_owner(private.build_summary());
end $$;

create or replace function public.preview_summary() returns text
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  return private.build_summary();
end $$;

create or replace function public.enqueue_reminders_now() returns int
language plpgsql security definer set search_path = public, private as $$
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  return private.enqueue_reminders();
end $$;

-- نتيجة طلب إرسال (للتجربة من اللوحة)
create or replace function public.request_result(req bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r record;
begin
  if not public.is_owner() then raise exception 'permission denied'; end if;
  select status_code, error_msg, left(coalesce(content, ''), 300) as content into r from net._http_response where id = req;
  if not found then return jsonb_build_object('done', false); end if;
  return jsonb_build_object('done', true, 'status', r.status_code, 'error', r.error_msg, 'content', r.content);
end $$;

revoke all on function public.get_automation(), public.set_automation(jsonb), public.send_summary_now(),
  public.preview_summary(), public.enqueue_reminders_now(), public.request_result(bigint) from public, anon;
grant execute on function public.get_automation(), public.set_automation(jsonb), public.send_summary_now(),
  public.preview_summary(), public.enqueue_reminders_now(), public.request_result(bigint) to authenticated;

-- ---------- الجدولة ----------
select cron.schedule('tv-hourly', '2 * * * *', 'select public.tv_tick_hourly()');
select cron.schedule('tv-minute', '* * * * *', 'select public.tv_tick_minute()');
