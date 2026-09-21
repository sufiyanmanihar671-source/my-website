-- Refresh the automatic exchange rates every 6 hours.
--
-- pg_cron fires pg_net, which calls the refresh-exchange-rates edge function. The function
-- needs no credentials for a scheduled run (see its header comment): it always pulls from
-- its own fixed providers, honours the admin's "Automatic rates" switch, and throttles itself.
create extension if not exists pg_net  with schema extensions;
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'refresh-exchange-rates';
select cron.schedule(
  'refresh-exchange-rates',
  '17 */6 * * *',
  $$select net.http_post(
      url     := 'https://qmgbmcxzqmcyupakpejw.supabase.co/functions/v1/refresh-exchange-rates',
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body    := '{}'::jsonb,
      timeout_milliseconds := 30000
    );$$
);
