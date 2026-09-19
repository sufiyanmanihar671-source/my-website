-- Performance hardening found by the Supabase advisors after the integrity migration.
--  * Wrap auth.uid() / current_role_is_staff() in (select ...) so Postgres evaluates them once
--    per statement instead of once per row (advisor 0003_auth_rls_initplan).
--  * Scope the read policies to `authenticated`; anon has no table privileges on these tables anyway.
--  * Cover enquiry_notes.updated_by with an index (advisor 0001_unindexed_foreign_keys).
-- Behaviour is unchanged: customers read their own rows, staff read everything.

drop policy if exists watchlist_select_own on public.watchlist;
create policy watchlist_select_own on public.watchlist for select to authenticated
  using (user_id = (select auth.uid()) or (select public.current_role_is_staff()));

drop policy if exists watchlist_insert_own on public.watchlist;
create policy watchlist_insert_own on public.watchlist for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists watchlist_delete_own on public.watchlist;
create policy watchlist_delete_own on public.watchlist for delete to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists enquiries_select_own_or_staff on public.enquiries;
create policy enquiries_select_own_or_staff on public.enquiries for select to authenticated
  using (user_id = (select auth.uid()) or (select public.current_role_is_staff()));

drop policy if exists enquiry_items_select_own_or_staff on public.enquiry_items;
create policy enquiry_items_select_own_or_staff on public.enquiry_items for select to authenticated
  using (exists (select 1 from public.enquiries e
                  where e.id = enquiry_items.enquiry_id
                    and (e.user_id = (select auth.uid()) or (select public.current_role_is_staff()))));

drop policy if exists bills_select_own_or_staff on public.bills;
create policy bills_select_own_or_staff on public.bills for select to authenticated
  using (customer_id = (select auth.uid()) or (select public.current_role_is_staff()));

drop policy if exists bill_items_select_own_or_staff on public.bill_items;
create policy bill_items_select_own_or_staff on public.bill_items for select to authenticated
  using (exists (select 1 from public.bills b
                  where b.id = bill_items.bill_id
                    and (b.customer_id = (select auth.uid()) or (select public.current_role_is_staff()))));

create index if not exists enquiry_notes_updated_by_idx on public.enquiry_notes (updated_by);
