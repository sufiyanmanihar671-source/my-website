-- ============================================================================
-- Nisha Art Jewellery — data integrity, safe deletes and enquiry / video-call workflow
-- ----------------------------------------------------------------------------
-- Found in the backend audit:
--   * no CHECK constraints (negative price, blank name/code, currency rate 0
--     would make every price 0)
--   * deleting a category/subcategory silently un-categorised products
--   * a product could point at a subcategory of a different category
--   * enquiries had no workflow statuses / notes and customers could edit them
--   * video-call requests had no validation, no admin notes
--   * 15 foreign keys without an index
--   * image bucket had no size / type limit
--   * the enquiry insert was two separate client calls (could leave an empty
--     enquiry behind) and trusted client-supplied product names
-- Existing data was checked first: zero violations, nothing is rewritten.
-- RLS stays enabled everywhere.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. products
-- ---------------------------------------------------------------------------
alter table public.products alter column category_id set not null;

alter table public.products drop constraint if exists products_name_chk;
alter table public.products drop constraint if exists products_code_chk;
alter table public.products drop constraint if exists products_price_chk;
alter table public.products add constraint products_name_chk  check (char_length(btrim(name)) between 1 and 200);
alter table public.products add constraint products_code_chk  check (char_length(btrim(code)) between 1 and 60);
alter table public.products add constraint products_price_chk check (price >= 0);

-- product code is unique regardless of case / surrounding spaces ("NAJ-1" = "naj-1 ")
create unique index if not exists products_code_lower_uidx on public.products (lower(btrim(code)));

-- deleting a category / subcategory that products use is refused (not silently un-categorised)
alter table public.products drop constraint if exists products_category_id_fkey;
alter table public.products add  constraint products_category_id_fkey
  foreign key (category_id) references public.categories(id) on delete restrict;
alter table public.products drop constraint if exists products_subcategory_id_fkey;
alter table public.products add  constraint products_subcategory_id_fkey
  foreign key (subcategory_id) references public.subcategories(id) on delete restrict;

-- a product's subcategory must belong to its category
create or replace function public.products_validate_taxonomy()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.subcategory_id is not null and not exists (
       select 1 from public.subcategories s
        where s.id = new.subcategory_id and s.category_id = new.category_id) then
    raise exception 'Subcategory does not belong to the selected category' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists products_validate_taxonomy_trg on public.products;
create trigger products_validate_taxonomy_trg
  before insert or update of category_id, subcategory_id on public.products
  for each row execute function public.products_validate_taxonomy();
revoke execute on function public.products_validate_taxonomy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. categories / subcategories
-- ---------------------------------------------------------------------------
alter table public.categories drop constraint if exists categories_id_slug_chk;
alter table public.categories drop constraint if exists categories_name_chk;
alter table public.categories add constraint categories_id_slug_chk check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(id) <= 60);
alter table public.categories add constraint categories_name_chk    check (char_length(btrim(name)) between 1 and 80);

alter table public.subcategories drop constraint if exists subcategories_name_chk;
alter table public.subcategories add constraint subcategories_name_chk check (char_length(btrim(name)) between 1 and 80);
create unique index if not exists subcategories_cat_lower_name_uidx on public.subcategories (category_id, lower(btrim(name)));

-- ---------------------------------------------------------------------------
-- 3. currencies (a rate of 0 would turn every price to zero)
-- ---------------------------------------------------------------------------
alter table public.currencies drop constraint if exists currencies_code_chk;
alter table public.currencies drop constraint if exists currencies_rate_chk;
alter table public.currencies drop constraint if exists currencies_name_chk;
alter table public.currencies drop constraint if exists currencies_symbol_chk;
alter table public.currencies add constraint currencies_code_chk   check (code ~ '^[A-Z]{3}$');
alter table public.currencies add constraint currencies_rate_chk   check (rate > 0);
alter table public.currencies add constraint currencies_name_chk   check (char_length(btrim(name)) between 1 and 60);
alter table public.currencies add constraint currencies_symbol_chk check (char_length(btrim(symbol)) between 1 and 8);

-- prices are stored in INR: the base currency can't be deleted, deactivated or re-rated
create or replace function public.currencies_protect_base()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.code = 'INR' then
    if tg_op = 'DELETE' then
      raise exception 'INR is the base currency and cannot be deleted' using errcode = '23514';
    end if;
    if new.code <> 'INR' or new.rate <> 1 or not new.active then
      raise exception 'INR is the base currency: rate must stay 1 and it must stay active' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
drop trigger if exists currencies_protect_base_trg on public.currencies;
create trigger currencies_protect_base_trg before update or delete on public.currencies
  for each row execute function public.currencies_protect_base();
revoke execute on function public.currencies_protect_base() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. bills: no negative money, no zero-quantity lines
-- ---------------------------------------------------------------------------
alter table public.bills      drop constraint if exists bills_money_chk;
alter table public.bill_items drop constraint if exists bill_items_chk;
alter table public.bills      add constraint bills_money_chk check (subtotal >= 0 and discount >= 0 and tax >= 0 and grand_total >= 0);
alter table public.bill_items add constraint bill_items_chk  check (quantity > 0 and unit_price >= 0 and total >= 0 and char_length(btrim(product_name)) >= 1);

-- ---------------------------------------------------------------------------
-- 5. profiles: lenient format checks (blank allowed)
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_email_chk;
alter table public.profiles drop constraint if exists profiles_phone_chk;
alter table public.profiles add constraint profiles_email_chk check (email is null or email = '' or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$');
alter table public.profiles add constraint profiles_phone_chk check (phone is null or phone = '' or phone ~ '^\+?[0-9 ()-]{6,20}$');

-- ---------------------------------------------------------------------------
-- 6. enquiries: workflow statuses, private staff notes, staff-only edits
-- ---------------------------------------------------------------------------
alter table public.enquiries drop constraint if exists enquiries_status_check;
alter table public.enquiries add  constraint enquiries_status_check
  check (status in ('draft','submitted','contacted','quoted','completed','cancelled'));

-- private notes: separate staff-only table (customers can read their own enquiry rows)
create table if not exists public.enquiry_notes (
  enquiry_id uuid primary key references public.enquiries(id) on delete cascade,
  notes      text not null default '' check (char_length(notes) <= 4000),
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.enquiry_notes enable row level security;
revoke all on public.enquiry_notes from anon;
drop policy if exists enquiry_notes_staff_select on public.enquiry_notes;
drop policy if exists enquiry_notes_staff_insert on public.enquiry_notes;
drop policy if exists enquiry_notes_staff_update on public.enquiry_notes;
drop policy if exists enquiry_notes_staff_delete on public.enquiry_notes;
create policy enquiry_notes_staff_select on public.enquiry_notes for select to authenticated using ((select public.current_role_is_staff()));
create policy enquiry_notes_staff_insert on public.enquiry_notes for insert to authenticated with check ((select public.current_role_is_staff()));
create policy enquiry_notes_staff_update on public.enquiry_notes for update to authenticated using ((select public.current_role_is_staff())) with check ((select public.current_role_is_staff()));
create policy enquiry_notes_staff_delete on public.enquiry_notes for delete to authenticated using ((select public.current_role_is_staff()));

create or replace function public.enquiry_notes_touch()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists enquiry_notes_touch_trg on public.enquiry_notes;
create trigger enquiry_notes_touch_trg before insert or update on public.enquiry_notes
  for each row execute function public.enquiry_notes_touch();
revoke execute on function public.enquiry_notes_touch() from public, anon, authenticated;

-- the colour the customer asked about, and no duplicate lines in one enquiry
alter table public.enquiry_items add column if not exists color_name text;
alter table public.enquiry_items drop constraint if exists enquiry_items_color_chk;
alter table public.enquiry_items drop constraint if exists enquiry_items_text_chk;
alter table public.enquiry_items add constraint enquiry_items_color_chk check (color_name is null or char_length(btrim(color_name)) between 1 and 60);
alter table public.enquiry_items add constraint enquiry_items_text_chk  check (coalesce(char_length(product_name),0) <= 200 and coalesce(char_length(product_code),0) <= 60);
create unique index if not exists enquiry_items_no_dupes_uidx
  on public.enquiry_items (enquiry_id, product_id, coalesce(lower(color_name), '')) where product_id is not null;

-- customers can no longer insert / change / delete enquiries directly: they call submit_enquiry()
drop policy if exists enquiries_insert_own            on public.enquiries;
drop policy if exists enquiries_update_own_or_staff   on public.enquiries;
drop policy if exists enquiries_staff_update          on public.enquiries;
drop policy if exists enquiry_items_insert_own        on public.enquiry_items;
drop policy if exists enquiry_items_delete_own_or_staff on public.enquiry_items;
drop policy if exists enquiry_items_staff_delete      on public.enquiry_items;
create policy enquiries_staff_update on public.enquiries for update to authenticated
  using ((select public.current_role_is_staff())) with check ((select public.current_role_is_staff()));
create policy enquiry_items_staff_delete on public.enquiry_items for delete to authenticated
  using ((select public.current_role_is_staff()));

-- Atomic, validated enquiry submission (one transaction; product names come from the catalogue, not the client)
create or replace function public.submit_enquiry(p_items jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
  it    jsonb;
  v_p   record;
  v_col text;
  v_n   int;
begin
  if v_uid is null then
    raise exception 'Please sign in to submit an enquiry' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = v_uid and is_active) then
    raise exception 'Your account is not active' using errcode = '42501';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Invalid enquiry' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_items);
  if v_n < 1 or v_n > 50 then
    raise exception 'An enquiry must contain between 1 and 50 products' using errcode = '22023';
  end if;
  if exists (select 1 from public.enquiries where user_id = v_uid and created_at > now() - interval '20 seconds') then
    raise exception 'Please wait a few seconds before sending another enquiry' using errcode = '54000';
  end if;

  insert into public.enquiries(user_id, status) values (v_uid, 'submitted') returning id into v_id;

  for it in select * from jsonb_array_elements(p_items) loop
    begin
      select p.id, p.name, p.code into v_p from public.products p
       where p.id = (it->>'product_id')::uuid and p.active;
    exception when invalid_text_representation then
      raise exception 'Invalid product in enquiry' using errcode = '22023';
    end;
    if not found then
      raise exception 'A product in your enquiry is no longer available' using errcode = '23503';
    end if;
    v_col := nullif(btrim(coalesce(it->>'color_name','')), '');
    if v_col is not null and not exists (
         select 1 from public.product_colors c
          where c.product_id = v_p.id and c.is_active and lower(c.color_name) = lower(v_col)) then
      raise exception 'The selected colour is no longer available for %', v_p.name using errcode = '23503';
    end if;
    insert into public.enquiry_items(enquiry_id, product_id, product_name, product_code, color_name)
    values (v_id, v_p.id, v_p.name, v_p.code, v_col);
  end loop;
  return v_id;
end $$;
revoke all on function public.submit_enquiry(jsonb) from public, anon;
grant execute on function public.submit_enquiry(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. video-call requests: validation, private admin notes, staff-only reads
-- ---------------------------------------------------------------------------
alter table public.video_call_requests add column if not exists admin_notes text;
alter table public.video_call_requests drop constraint if exists video_call_valid_chk;
alter table public.video_call_requests add  constraint video_call_valid_chk check (
      char_length(btrim(full_name)) between 1 and 120
  and (business_name   is null or char_length(business_name)   <= 160)
  and (collection      is null or char_length(collection)      <= 200)
  and (message         is null or char_length(message)         <= 2000)
  and (admin_notes     is null or char_length(admin_notes)     <= 4000)
  and (email           is null or email = '' or email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
  and (whatsapp_number is null or whatsapp_number = '' or whatsapp_number ~ '^\+?[0-9 ()-]{6,20}$')
  and (preferred_time  is null or preferred_time  = '' or preferred_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')
);

-- a date in the past / far future is refused at creation (checked on insert only, so later status updates still work)
create or replace function public.video_call_validate_insert()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.preferred_date is not null and (new.preferred_date < current_date - 1 or new.preferred_date > current_date + 365) then
    raise exception 'Preferred date must be within the next year' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists video_call_validate_insert_trg on public.video_call_requests;
create trigger video_call_validate_insert_trg before insert on public.video_call_requests
  for each row execute function public.video_call_validate_insert();
revoke execute on function public.video_call_validate_insert() from public, anon, authenticated;

drop policy if exists video_call_insert_any          on public.video_call_requests;
drop policy if exists video_call_insert_public       on public.video_call_requests;
drop policy if exists video_call_select_own_or_staff on public.video_call_requests;
drop policy if exists video_call_select_staff        on public.video_call_requests;
create policy video_call_insert_public on public.video_call_requests for insert to anon, authenticated
  with check (status = 'pending' and admin_notes is null and (user_id is null or user_id = (select auth.uid())));
create policy video_call_select_staff on public.video_call_requests for select to authenticated
  using ((select public.current_role_is_staff()));

-- ---------------------------------------------------------------------------
-- 8. indexes on foreign keys / common filters
-- ---------------------------------------------------------------------------
create index if not exists products_category_idx        on public.products (category_id);
create index if not exists products_subcategory_idx     on public.products (subcategory_id);
create index if not exists products_active_created_idx  on public.products (active, created_at desc);
create index if not exists products_stock_state_idx     on public.products (stock_state);
create index if not exists product_images_product_idx   on public.product_images (product_id, sort_order);
create index if not exists enquiries_user_idx           on public.enquiries (user_id);
create index if not exists enquiries_status_created_idx on public.enquiries (status, created_at desc);
create index if not exists enquiry_items_enquiry_idx    on public.enquiry_items (enquiry_id);
create index if not exists enquiry_items_product_idx    on public.enquiry_items (product_id);
create index if not exists bills_customer_idx           on public.bills (customer_id);
create index if not exists bills_enquiry_idx            on public.bills (enquiry_id);
create index if not exists bills_created_by_idx         on public.bills (created_by);
create index if not exists bill_items_bill_idx          on public.bill_items (bill_id);
create index if not exists bill_items_product_idx       on public.bill_items (product_id);
create index if not exists video_call_user_idx          on public.video_call_requests (user_id);
create index if not exists video_call_status_created_idx on public.video_call_requests (status, created_at desc);
create index if not exists watchlist_product_idx        on public.watchlist (product_id);

-- ---------------------------------------------------------------------------
-- 9. storage: only real images, max 5 MB (enforced by Storage itself, not just the admin UI)
-- ---------------------------------------------------------------------------
update storage.buckets
   set file_size_limit    = 5242880,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','image/avif']
 where id = 'product-images';
