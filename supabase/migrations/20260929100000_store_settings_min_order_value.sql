-- Site-wide B2B order policy, shown on every product detail page and edited in admin.
-- Minimum Order Value is for the WHOLE order (mix & match across products), never per product.
-- One row only (id is always true). Everyone may read the policy; only active staff may change it.
create table if not exists public.store_settings (
  id              boolean primary key default true check (id),
  min_order_value numeric(12,2) not null default 5000
                  check (min_order_value >= 0 and min_order_value <= 10000000),
  mix_and_match   boolean not null default true,
  updated_at      timestamptz not null default now()
);

insert into public.store_settings (id) values (true) on conflict (id) do nothing;

alter table public.store_settings enable row level security;

revoke all on public.store_settings from anon, authenticated;
grant select (id, min_order_value, mix_and_match, updated_at) on public.store_settings to anon, authenticated;
grant update (min_order_value, mix_and_match) on public.store_settings to authenticated;

drop policy if exists store_settings_read on public.store_settings;
create policy store_settings_read on public.store_settings
  for select to anon, authenticated using (true);

drop policy if exists store_settings_staff_update on public.store_settings;
create policy store_settings_staff_update on public.store_settings
  for update to authenticated
  using ((select public.current_role_is_staff()))
  with check ((select public.current_role_is_staff()));

create or replace function public.store_settings_touch()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists store_settings_touch on public.store_settings;
create trigger store_settings_touch before update on public.store_settings
  for each row execute function public.store_settings_touch();
