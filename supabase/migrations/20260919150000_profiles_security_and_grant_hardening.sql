-- ============================================================================
-- Nisha Art Jewellery — profiles security + grant hardening
-- ----------------------------------------------------------------------------
-- Fixes
--   1. profiles was readable by EVERYONE (policy USING (true)) -> customer
--      phone numbers / emails / company details were public.
--   2. Any signed-in customer could UPDATE their own profile row without a
--      check, including role = 'admin' (privilege escalation -> full write
--      access to the catalogue). Roles / status are now guarded.
--   3. The anonymous role held INSERT/UPDATE/DELETE/TRUNCATE on every table
--      (RLS was the only guard). Anonymous now gets read-only access to the
--      public catalogue + the public video-call request form, nothing else.
--
-- RLS stays ENABLED everywhere. No data is modified or deleted.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. profiles Row Level Security
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_own_or_staff on public.profiles;
drop policy if exists profiles_insert_own          on public.profiles;
drop policy if exists profiles_update_own          on public.profiles;
drop policy if exists profiles_update_own_or_staff on public.profiles;

-- a signed-in user reads ONLY their own row; staff (admin/manager) read all.
-- Anonymous visitors read nothing.
create policy profiles_select_own_or_staff on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select public.current_role_is_staff()));

-- registration: a user may create only their own row, and only as a plain customer
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()) and role = 'customer' and is_active = true);

-- a user edits their own row; staff can edit rows (role/status are further
-- guarded by the trigger below)
create policy profiles_update_own_or_staff on public.profiles
  for update to authenticated
  using      (id = (select auth.uid()) or (select public.current_role_is_staff()))
  with check (id = (select auth.uid()) or (select public.current_role_is_staff()));

-- ---------------------------------------------------------------------------
-- 2. Guard privileged columns (role, is_active)
--    * role can only be changed by an active ADMIN, never on your own row
--    * is_active can only be changed by active staff, never on your own row
--    * requests without a JWT (SQL editor / service role / migrations) are trusted
-- ---------------------------------------------------------------------------
create or replace function public.profiles_guard_privileged_columns()
returns trigger language plpgsql security definer set search_path = public as $$
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

  return new;
end $$;

drop trigger if exists profiles_guard_privileged_columns_trg on public.profiles;
create trigger profiles_guard_privileged_columns_trg
  before update on public.profiles
  for each row execute function public.profiles_guard_privileged_columns();

revoke execute on function public.profiles_guard_privileged_columns() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Grants: least privilege (defence in depth on top of RLS)
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon;

-- public storefront: read-only catalogue
grant select on public.categories, public.subcategories, public.currencies,
                public.products, public.product_images to anon;
grant select on public.product_colors_public to anon;          -- view, no quantities
-- public "book a video call" form (no read-back)
grant insert on public.video_call_requests to anon;

-- signed-in users never need these
revoke truncate, trigger, references on all tables in schema public from authenticated;
