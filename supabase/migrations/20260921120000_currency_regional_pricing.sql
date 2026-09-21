-- Currency & Regional Pricing
--
-- Product prices stay in INR (products.price is never touched). The storefront
-- converts them for display with the rates below.
--
--   currencies.auto_rate    latest rate from the exchange-rate provider (written only
--                           by the refresh-exchange-rates edge function, service role)
--   currencies.manual_rate  optional admin override (NULL = follow the automatic rate)
--   currencies.rate         the EFFECTIVE rate the storefront reads = manual_rate,
--                           else auto_rate, else the last value it had. Maintained by
--                           a trigger, so a failed provider call can never blank it.
--   currency_settings       one-row, staff-only: auto-refresh switch + provider status.
--
-- Rates are "units of currency per 1 INR" (e.g. USD 0.0104).

-- ---------------------------------------------------------------------------
-- 1. currencies: automatic + manual rate, region and formatting metadata
-- ---------------------------------------------------------------------------
alter table public.currencies alter column rate type numeric(20,10);

alter table public.currencies
  add column if not exists country_name          text,
  add column if not exists country_code          text,                -- flag: ISO 3166-1 alpha-2 ('EU' for the euro area)
  add column if not exists countries             text[] not null default '{}',   -- visitors from these countries default to this currency
  add column if not exists format_locale         text   not null default 'en-US', -- BCP-47 locale used to format prices
  add column if not exists auto_rate             numeric(20,10),
  add column if not exists auto_rate_updated_at  timestamptz,
  add column if not exists manual_rate           numeric(20,10),
  add column if not exists manual_rate_updated_at timestamptz;

alter table public.currencies drop constraint if exists currencies_auto_rate_chk;
alter table public.currencies drop constraint if exists currencies_manual_rate_chk;
alter table public.currencies drop constraint if exists currencies_region_chk;
alter table public.currencies add constraint currencies_auto_rate_chk   check (auto_rate is null or auto_rate > 0);
alter table public.currencies add constraint currencies_manual_rate_chk check (manual_rate is null or manual_rate > 0);
alter table public.currencies add constraint currencies_region_chk
  check (country_code is null or country_code ~ '^[A-Z]{2}$');

-- effective rate = manual override, else automatic, else keep what is there
create or replace function public.currencies_sync_rate()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.code = 'INR' then
    new.rate := 1; new.auto_rate := 1; new.manual_rate := null; new.manual_rate_updated_at := null;
    return new;
  end if;
  if tg_op = 'INSERT' or new.manual_rate is distinct from old.manual_rate then
    new.manual_rate_updated_at := case when new.manual_rate is null then null else now() end;
  end if;
  if new.manual_rate is not null then
    new.rate := new.manual_rate;
  elsif new.auto_rate is not null then
    new.rate := new.auto_rate;
  end if;
  return new;
end $$;
drop trigger if exists currencies_sync_rate_trg on public.currencies;
create trigger currencies_sync_rate_trg before insert or update on public.currencies
  for each row execute function public.currencies_sync_rate();
revoke execute on function public.currencies_sync_rate() from public, anon, authenticated;

-- INR is the base: no override, rate stays 1, always active
create or replace function public.currencies_protect_base()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.code = 'INR' then
    if tg_op = 'DELETE' then
      raise exception 'INR is the base currency and cannot be deleted' using errcode = '23514';
    end if;
    if new.code <> 'INR' or new.rate <> 1 or not new.active or new.manual_rate is not null then
      raise exception 'INR is the base currency: rate must stay 1, it cannot be overridden and it must stay active' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- Staff may edit display settings and set/clear the override; the automatic rate
-- and the effective rate are written only by the server (service role) / trigger.
revoke update on public.currencies from authenticated;
grant update (name, symbol, symbol_first, active, sort_order, manual_rate,
              country_name, country_code, countries, format_locale)
  on public.currencies to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Region metadata for the supported currencies (rates untouched here)
-- ---------------------------------------------------------------------------
update public.currencies c set
  country_name = v.country_name, country_code = v.country_code,
  countries = v.countries, format_locale = v.format_locale
from (values
  ('INR', 'India',                 'IN', array['IN'],                                   'en-IN'),
  ('USD', 'United States',         'US', array['US','PR','GU','VI','AS','MP','EC','SV','PA','TL','PW','FM','MH','TC','VG','BQ'], 'en-US'),
  ('EUR', 'Eurozone',              'EU', array['AT','BE','BG','HR','CY','EE','FI','FR','DE','GR','IE','IT','LV','LT','LU','MT','NL','PT','SK','SI','ES','AD','MC','SM','VA','ME','XK'], 'en-IE'),
  ('GBP', 'United Kingdom',        'GB', array['GB','GG','JE','IM'],                    'en-GB'),
  ('AED', 'United Arab Emirates',  'AE', array['AE'],                                   'en-AE'),
  ('SAR', 'Saudi Arabia',          'SA', array['SA'],                                   'en-US'),
  ('AUD', 'Australia',             'AU', array['AU','CX','CC','HM','KI','NR','NF','TV'],'en-US'),
  ('CAD', 'Canada',                'CA', array['CA'],                                   'en-US'),
  ('SGD', 'Singapore',             'SG', array['SG'],                                   'en-US'),
  ('JPY', 'Japan',                 'JP', array['JP'],                                   'en-US')
) as v(code, country_name, country_code, countries, format_locale)
where c.code = v.code;

update public.currencies set auto_rate = 1 where code = 'INR';

-- ---------------------------------------------------------------------------
-- 3. currency_settings: staff-only switch + provider status (one row)
-- ---------------------------------------------------------------------------
create table if not exists public.currency_settings (
  id                 boolean primary key default true check (id),   -- single row
  base_currency      text        not null default 'INR' check (base_currency = 'INR'),
  auto_rates_enabled boolean     not null default true,
  provider           text,                 -- provider that supplied the last successful update
  last_attempt_at    timestamptz,
  last_success_at    timestamptz,
  last_status        text        not null default 'never' check (last_status in ('never','ok','partial','error')),
  last_message       text,
  updated_count      integer     not null default 0,
  updated_at         timestamptz not null default now()
);
insert into public.currency_settings (id) values (true) on conflict (id) do nothing;

alter table public.currency_settings enable row level security;
drop policy if exists currency_settings_staff_read   on public.currency_settings;
drop policy if exists currency_settings_staff_update on public.currency_settings;
create policy currency_settings_staff_read on public.currency_settings
  for select to authenticated using ((select public.current_role_is_staff()));
create policy currency_settings_staff_update on public.currency_settings
  for update to authenticated using ((select public.current_role_is_staff()))
  with check ((select public.current_role_is_staff()));

revoke all on public.currency_settings from anon, authenticated;
grant select on public.currency_settings to authenticated;
grant update (auto_rates_enabled) on public.currency_settings to authenticated;

create or replace function public.currency_settings_touch()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists currency_settings_touch_trg on public.currency_settings;
create trigger currency_settings_touch_trg before update on public.currency_settings
  for each row execute function public.currency_settings_touch();
revoke execute on function public.currency_settings_touch() from public, anon, authenticated;
