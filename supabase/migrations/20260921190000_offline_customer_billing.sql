-- Billing for offline customers.
--
-- Until now every bill pointed at a registered profile (bills.customer_id NOT NULL), so a customer who
-- buys directly from the shop and has no website account could not be billed. Now:
--
--   customer_type = 'registered'  customer_id is set (a website customer)
--   customer_type = 'offline'     customer_id is NULL; the customer's details are typed in by the admin
--
-- Either way the customer's details are copied onto the bill (customer_name, customer_phone, ...) so an
-- invoice keeps showing what it showed when it was issued, even if a profile is edited later.
-- bill_items already snapshot the product (name, code, quantity, unit price, line total).
--
-- No existing bill is affected (there are none yet); nothing else in the schema changes.

-- ---------------------------------------------------------------------------
-- 1. bills: customer snapshot + optional customer_id
-- ---------------------------------------------------------------------------
alter table public.bills alter column customer_id drop not null;

alter table public.bills
  add column if not exists customer_type   text not null default 'registered',
  add column if not exists customer_name   text,
  add column if not exists customer_phone  text,
  add column if not exists customer_email  text,
  add column if not exists business_name   text,
  add column if not exists billing_address text,
  add column if not exists city            text,
  add column if not exists state           text,
  add column if not exists pincode         text,
  add column if not exists gst_number      text;

alter table public.bills drop constraint if exists bills_customer_type_chk;
alter table public.bills drop constraint if exists bills_customer_chk;
alter table public.bills drop constraint if exists bills_customer_fields_chk;
alter table public.bills drop constraint if exists bills_totals_chk;
alter table public.bill_items drop constraint if exists bill_items_total_chk;

alter table public.bills add constraint bills_customer_type_chk check (customer_type in ('registered','offline'));
-- a registered bill needs its customer; an offline bill has no account but needs a name and a mobile number
alter table public.bills add constraint bills_customer_chk check (
  (customer_type = 'registered' and customer_id is not null)
  or
  (customer_type = 'offline' and customer_id is null
     and char_length(btrim(coalesce(customer_name, ''))) >= 1
     and char_length(btrim(coalesce(customer_phone, ''))) >= 1)
);
-- formats and lengths of the typed-in details (all optional except where the rule above says otherwise)
alter table public.bills add constraint bills_customer_fields_chk check (
  (customer_name   is null or char_length(customer_name)   <= 120)
  and (business_name   is null or char_length(business_name)   <= 120)
  and (customer_email  is null or (char_length(customer_email) <= 120 and customer_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'))
  and (customer_phone  is null or customer_phone ~ '^\+[0-9]{8,15}$')
  and (billing_address is null or char_length(billing_address) <= 300)
  and (city            is null or char_length(city)  <= 60)
  and (state           is null or char_length(state) <= 60)
  and (pincode         is null or pincode ~ '^[0-9]{6}$')
  and (gst_number      is null or gst_number ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$')
);

-- the money on a bill always adds up (0.01 tolerance for rounding)
alter table public.bills      add constraint bills_totals_chk     check (abs(grand_total - (subtotal - discount + tax)) < 0.01);
alter table public.bill_items add constraint bill_items_total_chk check (abs(total - quantity * unit_price) < 0.01);

-- ---------------------------------------------------------------------------
-- 2. RLS: staff policies were granted to the `public` role, so an anonymous request had to run
--    current_role_is_staff() (which anon may not execute) and failed with "permission denied for function"
--    instead of being cleanly denied. Scope them to `authenticated`; behaviour for staff is unchanged.
--    (Customers still read only their own bills; offline bills have no customer_id, so only staff see them.)
-- ---------------------------------------------------------------------------
drop policy if exists bills_staff_write       on public.bills;
drop policy if exists bills_staff_update      on public.bills;
drop policy if exists bills_staff_delete      on public.bills;
drop policy if exists bill_items_staff_write  on public.bill_items;
drop policy if exists bill_items_staff_update on public.bill_items;
drop policy if exists bill_items_staff_delete on public.bill_items;

create policy bills_staff_write  on public.bills for insert to authenticated with check ((select public.current_role_is_staff()));
create policy bills_staff_update on public.bills for update to authenticated using ((select public.current_role_is_staff())) with check ((select public.current_role_is_staff()));
create policy bills_staff_delete on public.bills for delete to authenticated using ((select public.current_role_is_staff()));
create policy bill_items_staff_write  on public.bill_items for insert to authenticated with check ((select public.current_role_is_staff()));
create policy bill_items_staff_update on public.bill_items for update to authenticated using ((select public.current_role_is_staff())) with check ((select public.current_role_is_staff()));
create policy bill_items_staff_delete on public.bill_items for delete to authenticated using ((select public.current_role_is_staff()));
