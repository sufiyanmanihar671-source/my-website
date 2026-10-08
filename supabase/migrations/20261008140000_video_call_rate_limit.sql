-- Rate limit for the only table anonymous visitors can write to (video call booking form).
-- Limits are generous for real customers and stop scripted spam from filling the admin inbox:
--   * the same WhatsApp number or email: at most 3 requests per hour
--   * the whole site: at most 60 requests per hour
-- SECURITY DEFINER so it can count existing rows (visitors cannot read this table under RLS);
-- it reads only counts and never returns data. No existing rows change.

create or replace function public.video_call_rate_limit()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_wa    text := regexp_replace(coalesce(new.whatsapp_number, ''), '\D', '', 'g');
  v_email text := lower(btrim(coalesce(new.email, '')));
begin
  if (select count(*) from public.video_call_requests
       where created_at > now() - interval '1 hour') >= 60 then
    raise exception 'Too many video call requests right now. Please try again later.' using errcode = '54000';
  end if;

  if (v_wa <> '' or v_email <> '') and (
       select count(*) from public.video_call_requests r
        where r.created_at > now() - interval '1 hour'
          and ((v_wa <> '' and regexp_replace(coalesce(r.whatsapp_number, ''), '\D', '', 'g') = v_wa)
            or (v_email <> '' and lower(btrim(coalesce(r.email, ''))) = v_email))
     ) >= 3 then
    raise exception 'Too many video call requests from this contact. Please try again later.' using errcode = '54000';
  end if;

  return new;
end $function$;

revoke all on function public.video_call_rate_limit() from public, anon, authenticated;

create trigger video_call_rate_limit_trg
  before insert on public.video_call_requests
  for each row execute function public.video_call_rate_limit();
