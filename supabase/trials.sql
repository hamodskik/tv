-- ============================================================
-- التجارب المجانية من اللوحة (بدون ما تنضاف كزبون)
-- يحتاج panel.sql يكون متشغل قبله.
-- الصق الملف كامل في: SQL Editor ← New query ← Run (تقدر تشغله أكثر من مرة)
--
-- • يقبل باقات التجربة بس (is_trial و 0 كريدت). أي باقة ثانية ينرفض الطلب، فما ينخصم رصيد.
-- • التجربة تنحفظ في جدول trials لحالها، وما تدخل في عدد الزبائن ولا الأرباح.
-- ============================================================

create table if not exists public.trials (
  id           bigserial primary key,
  panel_id     text not null,
  name         text not null default '' check (char_length(name) <= 200),
  phone        text not null default '' check (phone = '' or phone ~ '^[0-9]{10,15}$'),
  package_id   bigint,
  package_name text not null default '',
  username     text not null default '',
  password     text not null default '',
  host         text not null default '',
  order_id     text not null default '',
  expires_at   timestamptz,
  followed_up  boolean not null default false,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid() references auth.users(id) on delete set null
);
create unique index if not exists trials_order_idx on public.trials (order_id) where order_id <> '';
create index if not exists trials_phone_idx on public.trials (phone);

alter table public.trials enable row level security;
drop policy if exists "staff read trials" on public.trials;
create policy "staff read trials" on public.trials for select to authenticated using (public.is_staff());
revoke all on public.trials from anon;
revoke insert, update, delete on public.trials from authenticated;
grant select on public.trials to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.trials;
exception when duplicate_object then null;
end $$;

-- يسوي خط تجربة في البانل. يرفض أي باقة مو تجربة مجانية.
create or replace function public.panel_create_trial(pid text, package_id bigint, p_name text, p_phone text, idem text) returns jsonb
language plpgsql security definer set search_path = public, private, extensions as $$
declare
  p private.panels; r extensions.http_response; js jsonb; l jsonb; pk jsonb;
  nm text := left(btrim(coalesce(p_name, '')), 200);
  ph text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  full_name text; exp timestamptz; tid bigint;
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  if coalesce(length(idem), 0) not between 8 and 100 then raise exception 'bad idempotency key'; end if;
  if ph <> '' and ph !~ '^[0-9]{10,15}$' then return jsonb_build_object('ok', false, 'error', 'رقم الجوال غلط'); end if;
  select * into p from private.panels where id = pid;
  if p.id is null or p.api_key = '' or p.base_url = '' then return jsonb_build_object('ok', false, 'error', 'البانل مو مربوط'); end if;
  select x into pk from jsonb_array_elements(coalesce(p.packages, '[]'::jsonb)) x where (x->>'id')::bigint = package_id limit 1;
  if pk is null then return jsonb_build_object('ok', false, 'error', 'الباقة مو موجودة. اضغط "مزامنة الحين" في تبويب البانل وجرّب'); end if;
  -- حماية الرصيد: تجربة مجانية بس
  if not (coalesce((pk->>'is_trial')::boolean, false) or pk->>'type' = 'trial')
     or coalesce(nullif(pk->>'credits', '')::numeric, 1) <> 0 then
    return jsonb_build_object('ok', false, 'error', 'هذي الباقة مو تجربة مجانية، ما نقدر نسويها من هنا');
  end if;

  full_name := left(btrim(coalesce(nullif(nm, ''), 'تجربة')
                 || case when ph ~ '^9665[0-9]{8}$' then ' 0' || substr(ph, 4) when ph <> '' then ' +' || ph else '' end), 64);
  begin
    r := private.panel_post(p.base_url, p.api_key, '/orders/line',
      jsonb_build_object('package_id', package_id, 'external_ref', 'tvt-' || left(idem, 50),
                         'fullname', full_name, 'note', 'تجربة من لوحة عالم محمد تيفي'), idem);
  exception when others then
    return jsonb_build_object('ok', false, 'retry', true, 'error', 'ما وصل رد من البانل. اضغط نفس الزر مرة ثانية (ما تنسوى مرتين)');
  end;
  if r.status not in (200, 201) then
    return jsonb_build_object('ok', false, 'retry', r.status in (429, 500, 502, 503, 504), 'error', private.panel_error(r));
  end if;

  js := r.content::jsonb; l := js->'line';
  if l is null or coalesce(l->>'username', '') = '' then return jsonb_build_object('ok', false, 'error', 'البانل ما رجّع بيانات الخط'); end if;
  exp := nullif(l->>'expires_at', '')::timestamptz;

  perform private.panel_store_line(pid, null, l);
  update private.panels set credits = coalesce(nullif(js->>'remaining_credits', '')::numeric, credits) where id = pid;

  insert into public.trials (panel_id, name, phone, package_id, package_name, username, password, host, order_id, expires_at)
  values (pid, nm, ph, package_id, coalesce(pk->>'name', ''), l->>'username', coalesce(l->>'password', ''),
          coalesce(l->'playlist'->>'host', ''), coalesce(js->>'id', ''), exp)
  on conflict (order_id) where order_id <> '' do update set username = excluded.username
  returning id into tid;

  return jsonb_build_object('ok', true, 'id', tid, 'username', l->>'username', 'password', l->>'password',
    'host', coalesce(l->'playlist'->>'host', ''), 'expires_at', exp, 'package_name', pk->>'name',
    'charged', js->'charged_credits', 'remaining', js->'remaining_credits',
    'replayed', coalesce((js->>'replayed')::boolean, false), 'sandbox', coalesce((js->>'sandbox')::boolean, false));
end $$;

-- علامة "تابعته بعد التجربة"
create or replace function public.trial_mark(p_id bigint, p_followed boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'permission denied'; end if;
  update public.trials set followed_up = p_followed where id = p_id;
end $$;

revoke all on function public.panel_create_trial(text, bigint, text, text, text), public.trial_mark(bigint, boolean) from public, anon;
grant execute on function public.panel_create_trial(text, bigint, text, text, text), public.trial_mark(bigint, boolean) to authenticated;
