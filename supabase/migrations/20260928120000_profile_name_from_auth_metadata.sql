-- Storefront auth (Google OAuth + email/password): fill the new customer's profile name.
-- Email sign-up sends { full_name } in user metadata; Google sends full_name / name.
-- Only the name is taken from metadata (it is user-supplied): role stays the column
-- default 'customer' and is_active the default true, so nothing privileged can be set.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_name  text := left(btrim(regexp_replace(coalesce(
                   new.raw_user_meta_data->>'full_name',
                   new.raw_user_meta_data->>'name', ''), '\s+', ' ', 'g')), 120);
  v_first text := nullif(split_part(v_name, ' ', 1), '');
  v_last  text := nullif(btrim(substr(v_name, length(split_part(v_name, ' ', 1)) + 1)), '');
begin
  insert into public.profiles (id, phone, email, first_name, last_name)
  values (new.id, new.phone, new.email, v_first, v_last)
  on conflict (id) do nothing;
  return new;
end;
$function$;
