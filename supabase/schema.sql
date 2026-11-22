-- ============================================================
-- لوحة زبائن عالم محمد تيفي: قاعدة البيانات في Supabase
-- الصق الملف كامل في: SQL Editor ← New query ← Run
-- تقدر تشغله أكثر من مرة بدون ما يخرب شي.
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- الأشخاص المسموح لهم ----------
-- owner = المالك (يحذف ويعدل الإعدادات)، staff = موظف (يضيف ويعدل ويجدد بس)
create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null default 'staff' check (role in ('owner', 'staff')),
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;

drop policy if exists "staff can see own row" on public.staff;
create policy "staff can see own row" on public.staff
  for select to authenticated using (user_id = auth.uid());

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid() and role = 'owner');
$$;

revoke all on function public.is_staff() from public, anon;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_owner() to authenticated;

-- ---------- الزبائن ----------
create table if not exists public.customers (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (char_length(name) between 1 and 200),
  phone         text not null default '' check (char_length(phone) <= 20),
  mac           text not null default '' check (char_length(mac) <= 17),
  device_key    text not null default '' check (char_length(device_key) <= 40),
  screen        text not null default 'android',
  pkg           text not null default '12m' check (pkg in ('trial', '1m', '3m', '6m', '12m')),
  start_date    date not null,
  end_date      date not null,
  notes         text not null default '' check (char_length(notes) <= 2000),
  referred_by   text not null default '' check (char_length(referred_by) <= 200),
  quality_done  boolean not null default false,
  sent          jsonb not null default '{}'::jsonb,   -- التذكيرات اللي انرسلت
  payments      jsonb not null default '[]'::jsonb,   -- سجل الدفعات
  example       boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references auth.users(id) on delete set null
);
-- ---------- تحديث 2: أجهزة وتطبيقات أكثر + يوزر وباس الخط ----------
alter table public.customers add column if not exists app       text not null default 'ibo';
alter table public.customers add column if not exists line_user text not null default '';
alter table public.customers add column if not exists line_pass text not null default '';
alter table public.customers drop constraint if exists customers_screen_check;
alter table public.customers add  constraint customers_screen_check
  check (screen in ('android', 'lg', 'samsung', 'iphone', 'phone', 'pc', 'other'));
alter table public.customers drop constraint if exists customers_app_check;
alter table public.customers add  constraint customers_app_check check (app in ('ibo', 'smarters', 'other'));
alter table public.customers drop constraint if exists customers_line_user_len;
alter table public.customers add  constraint customers_line_user_len check (char_length(line_user) <= 100);
alter table public.customers drop constraint if exists customers_line_pass_len;
alter table public.customers add  constraint customers_line_pass_len check (char_length(line_pass) <= 100);

create index if not exists customers_end_date_idx on public.customers (end_date);
create index if not exists customers_line_user_idx on public.customers (line_user);
create index if not exists customers_mac_idx on public.customers (mac);
create index if not exists customers_phone_idx on public.customers (phone);

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists customers_touch on public.customers;
create trigger customers_touch before update on public.customers
  for each row execute function public.touch_updated_at();

alter table public.customers enable row level security;

drop policy if exists "staff read customers"   on public.customers;
drop policy if exists "staff add customers"    on public.customers;
drop policy if exists "staff edit customers"   on public.customers;
drop policy if exists "owner delete customers" on public.customers;
create policy "staff read customers"   on public.customers for select to authenticated using (public.is_staff());
create policy "staff add customers"    on public.customers for insert to authenticated with check (public.is_staff());
create policy "staff edit customers"   on public.customers for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "owner delete customers" on public.customers for delete to authenticated using (public.is_owner());

-- ---------- الإعدادات (صف واحد) ----------
create table if not exists public.settings (
  id         smallint primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.settings (id, data) values (1, '{}'::jsonb) on conflict (id) do nothing;

alter table public.settings enable row level security;
drop policy if exists "staff read settings"  on public.settings;
drop policy if exists "owner write settings" on public.settings;
drop policy if exists "owner add settings"   on public.settings;
create policy "staff read settings"  on public.settings for select to authenticated using (public.is_staff());
create policy "owner write settings" on public.settings for update to authenticated using (public.is_owner()) with check (public.is_owner());
create policy "owner add settings"   on public.settings for insert to authenticated with check (public.is_owner());

-- ما أحد بدون تسجيل دخول يقدر يلمس الجداول
revoke all on public.customers, public.settings, public.staff from anon;

-- ---------- التحديث المباشر بين الأجهزة ----------
do $$
begin
  alter publication supabase_realtime add table public.customers;
exception when duplicate_object then null;
end $$;

-- ---------- عرض سريع داخل Supabase (Table Editor) ----------
-- يرتب الزبائن حسب الأيام المتبقية بتوقيت السعودية
create or replace view public.customers_status with (security_invoker = true) as
select
  name                                                   as "الاسم",
  phone                                                  as "الجوال",
  mac                                                    as "MAC",
  pkg                                                    as "الباقة",
  end_date                                               as "ينتهي",
  end_date - (now() at time zone 'Asia/Riyadh')::date    as "الأيام المتبقية"
from public.customers
order by end_date;
revoke all on public.customers_status from anon;
