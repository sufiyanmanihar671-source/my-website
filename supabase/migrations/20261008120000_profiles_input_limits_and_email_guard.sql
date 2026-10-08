-- Profiles hardening (non-destructive; no data changes).
-- 1) Length / format limits on the free-text columns a signed-in customer can write to their own row
--    through the API. The website never needs more than this; existing rows already fit.
-- 2) The privileged-column guard also protects `email`: only staff may change it, so a customer cannot
--    make the admin panel show a different email for their account. (role / is_active rules unchanged.)

alter table public.profiles
  add constraint profiles_text_lengths_chk check (
        char_length(coalesce(first_name, ''))       <= 120
    and char_length(coalesce(last_name, ''))        <= 120
    and char_length(coalesce(company_name, ''))     <= 160
    and char_length(coalesce(city, ''))             <= 100
    and char_length(coalesce(state, ''))            <= 100
    and char_length(coalesce(country, ''))          <= 100
    and char_length(coalesce(business_details, '')) <= 2000
  ),
  add constraint profiles_whatsapp_chk check (
    whatsapp_number is null or whatsapp_number = '' or whatsapp_number ~ '^\+?[0-9 ()-]{6,20}$'
  );

create or replace function public.profiles_guard_privileged_columns()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := (select auth.uid());
  v_role   text;
  v_active boolean;
begin
  if v_uid is null then
    return new;
  end if;

  select p.role, p.is_active into v_role, v_active
    from public.profiles p where p.id = v_uid;

  if new.role is distinct from old.role then
    if not (coalesce(v_role,'') = 'admin' and coalesce(v_active,false)) then
      raise exception 'Only an active admin can change a role' using errcode = '42501';
    end if;
    if new.id = v_uid then
      raise exception 'You cannot change your own role' using errcode = '42501';
    end if;
  end if;

  if new.is_active is distinct from old.is_active then
    if not (coalesce(v_role,'') in ('admin','manager') and coalesce(v_active,false)) then
      raise exception 'Only staff can change account status' using errcode = '42501';
    end if;
    if new.id = v_uid then
      raise exception 'You cannot deactivate your own account' using errcode = '42501';
    end if;
  end if;

  if new.email is distinct from old.email then
    if not (coalesce(v_role,'') in ('admin','manager') and coalesce(v_active,false)) then
      raise exception 'Only staff can change the account email here' using errcode = '42501';
    end if;
  end if;

  return new;
end $function$;
