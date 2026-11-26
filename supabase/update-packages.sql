-- ============================================================
-- تحديث: باقات "سنة و3 شهور" و"سنتين"
-- الصق الملف كامل في: SQL Editor ← New query ← Run (تقدر تشغله أكثر من مرة)
-- ============================================================

alter table public.customers drop constraint if exists customers_pkg_check;
alter table public.customers add  constraint customers_pkg_check check (pkg in ('trial', '1m', '3m', '6m', '12m', '15m', '24m'));

create or replace function private.pkg_label(p text) returns text
language sql immutable as $$
  select case p when 'trial' then 'تجربة 24 ساعة' when '1m' then 'شهر' when '3m' then '3 شهور'
    when '6m' then '6 شهور' when '12m' then 'سنة' when '15m' then 'سنة و3 شهور' when '24m' then 'سنتين'
    else coalesce(p, '—') end
$$;

create or replace function private.pkg_from_days(d int) returns text
language sql immutable as $$
  select case when d is null then '12m' when d <= 2 then 'trial' when d <= 45 then '1m'
              when d <= 120 then '3m' when d <= 240 then '6m' when d <= 400 then '12m'
              when d <= 600 then '15m' else '24m' end
$$;
