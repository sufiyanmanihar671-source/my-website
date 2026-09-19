-- ============================================================================
-- Nisha Art Jewellery — Stock Management + Colour Options
-- ----------------------------------------------------------------------------
-- Additive and idempotent. Nothing existing is dropped or rewritten except the
-- single products SELECT policy (see section 1, which fixes the public 401).
--
-- Privacy model
--   * Exact quantities live ONLY in staff-only tables (product_stock,
--     product_colors). Customers / anonymous visitors cannot read them, not
--     even through the REST API.
--   * The storefront reads status only:
--       products.stock_state          (public-safe text)
--       product_colors_public (view)  (no quantities)
--
-- Status rules (computed by triggers, single source of truth)
--   made_to_order    when explicitly selected by staff
--   out_of_stock     available = 0
--   few_pieces_left  0 < available <= low_stock_threshold
--   in_stock         available > low_stock_threshold
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Shared helpers
-- ---------------------------------------------------------------------------
create or replace function public.compute_stock_status(
  p_available integer, p_threshold integer, p_made_to_order boolean default false
) returns text
language sql immutable
set search_path = public
as $$
  select case
    when coalesce(p_made_to_order, false)      then 'made_to_order'
    when coalesce(p_available, 0) <= 0         then 'out_of_stock'
    when p_available <= coalesce(p_threshold, 0) then 'few_pieces_left'
    else 'in_stock'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 1. FIX: public catalogue read (anon got 401 "permission denied for function
--    current_role_is_staff"). The old policy called a function anon cannot
--    execute. Split into a role-scoped public policy + a staff policy so the
--    lock-down of that function is preserved.
-- ---------------------------------------------------------------------------
drop policy if exists products_public_read_active on public.products;
drop policy if exists products_staff_read_all on public.products;
drop policy if exists products_authenticated_read on public.products;

-- anonymous visitors: active products only (calls no function anon cannot execute)
create policy products_public_read_active on public.products
  for select to anon
  using (active = true);

-- signed-in users: active products, plus everything for staff (one policy, no duplicate evaluation)
create policy products_authenticated_read on public.products
  for select to authenticated
  using (active = true or (select public.current_role_is_staff()));

-- ---------------------------------------------------------------------------
-- 2. products: public-safe stock state (legacy boolean stock_status is kept,
--    and kept in sync, so nothing that already reads it breaks)
-- ---------------------------------------------------------------------------
alter table public.products
  add column if not exists stock_state text not null default 'in_stock';

-- backfill from the existing boolean BEFORE the sync trigger exists, so the
-- 40 existing products keep exactly their current in/out status
update public.products
   set stock_state = case when stock_status then 'in_stock' else 'out_of_stock' end;

alter table public.products drop constraint if exists products_stock_state_chk;
alter table public.products add constraint products_stock_state_chk
  check (stock_state in ('in_stock','few_pieces_left','made_to_order','out_of_stock'));

-- ---------------------------------------------------------------------------
-- 3. product_stock — staff-only exact quantities (1:1 with products)
-- ---------------------------------------------------------------------------
create table if not exists public.product_stock (
  product_id          uuid primary key references public.products(id) on delete cascade,
  total_stock         integer not null default 0,
  available_stock     integer not null default 0,
  reserved_stock      integer not null default 0,
  low_stock_threshold integer not null default 5,
  stock_status        text    not null default 'in_stock',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint product_stock_total_nonneg     check (total_stock >= 0),
  constraint product_stock_available_nonneg check (available_stock >= 0),
  constraint product_stock_reserved_nonneg  check (reserved_stock >= 0),
  constraint product_stock_threshold_nonneg check (low_stock_threshold >= 0),
  constraint product_stock_reserved_le_total check (reserved_stock <= total_stock),
  constraint product_stock_available_le_total check (available_stock <= total_stock),
  constraint product_stock_status_chk
    check (stock_status in ('in_stock','few_pieces_left','made_to_order','out_of_stock'))
);
comment on table public.product_stock is
  'Exact product quantities. STAFF ONLY (RLS). Customers only ever see products.stock_state.';

-- ---------------------------------------------------------------------------
-- 4. product_colors — one row per colour option of a product
-- ---------------------------------------------------------------------------
create table if not exists public.product_colors (
  id                  uuid primary key default gen_random_uuid(),
  product_id          uuid not null references public.products(id) on delete cascade,
  color_name          text not null,
  color_hex           text not null,
  image_url           text,
  stock_quantity      integer not null default 0,
  low_stock_threshold integer not null default 5,
  stock_status        text not null default 'in_stock',
  is_active           boolean not null default true,
  sort_order          integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint product_colors_name_chk
    check (char_length(btrim(color_name)) between 1 and 60),
  constraint product_colors_hex_chk
    check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  constraint product_colors_image_chk
    check (image_url is null or image_url ~ '^https?://' and char_length(image_url) <= 2048),
  constraint product_colors_qty_nonneg       check (stock_quantity >= 0),
  constraint product_colors_threshold_nonneg check (low_stock_threshold >= 0),
  constraint product_colors_status_chk
    check (stock_status in ('in_stock','few_pieces_left','made_to_order','out_of_stock'))
);
comment on table public.product_colors is
  'Colour options per product with their own stock. STAFF ONLY (RLS); storefront uses product_colors_public.';

-- one colour name per product (case-insensitive); also serves the FK lookup
create unique index if not exists product_colors_product_name_uidx
  on public.product_colors (product_id, lower(btrim(color_name)));
create index if not exists product_colors_product_sort_idx
  on public.product_colors (product_id, sort_order);
create index if not exists product_colors_product_active_idx
  on public.product_colors (product_id) where is_active;

-- ---------------------------------------------------------------------------
-- 5. Triggers (status is computed here, so admin and site can never disagree)
-- ---------------------------------------------------------------------------
create or replace function public.product_stock_before()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.stock_status is distinct from 'made_to_order' then
    new.stock_status := public.compute_stock_status(new.available_stock, new.low_stock_threshold, false);
  end if;
  new.updated_at := now();
  return new;
end $$;

create or replace function public.product_colors_before()
returns trigger language plpgsql set search_path = public as $$
begin
  new.color_name := btrim(new.color_name);
  new.color_hex  := upper(new.color_hex);
  if new.stock_status is distinct from 'made_to_order' then
    new.stock_status := public.compute_stock_status(new.stock_quantity, new.low_stock_threshold, false);
  end if;
  new.updated_at := now();
  return new;
end $$;

-- products: keep stock_state + legacy boolean consistent.
--   tracked product (has a product_stock row) -> state comes from product_stock
--   untracked (legacy) product                -> state derived from the boolean
create or replace function public.products_sync_stock_state()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  select ps.stock_status into v_status
    from public.product_stock ps where ps.product_id = new.id;
  if v_status is not null then
    new.stock_state  := v_status;
    new.stock_status := (v_status <> 'out_of_stock');
  else
    new.stock_state  := case when new.stock_status then 'in_stock' else 'out_of_stock' end;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- product_stock -> touch the product so products_sync_stock_state re-runs
create or replace function public.product_stock_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    update public.products set updated_at = now() where id = old.product_id;
    return old;
  end if;
  update public.products set updated_at = now() where id = new.product_id;
  return new;
end $$;

drop trigger if exists product_stock_before_trg on public.product_stock;
create trigger product_stock_before_trg before insert or update on public.product_stock
  for each row execute function public.product_stock_before();

drop trigger if exists product_stock_after_trg on public.product_stock;
create trigger product_stock_after_trg after insert or update or delete on public.product_stock
  for each row execute function public.product_stock_after();

drop trigger if exists product_colors_before_trg on public.product_colors;
create trigger product_colors_before_trg before insert or update on public.product_colors
  for each row execute function public.product_colors_before();

drop trigger if exists products_sync_stock_state_trg on public.products;
create trigger products_sync_stock_state_trg before insert or update on public.products
  for each row execute function public.products_sync_stock_state();

-- trigger functions are never meant to be called directly
revoke execute on function public.product_stock_before()       from public, anon, authenticated;
revoke execute on function public.product_colors_before()      from public, anon, authenticated;
revoke execute on function public.products_sync_stock_state()  from public, anon, authenticated;
revoke execute on function public.product_stock_after()        from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Row Level Security — staff only for both tables
-- ---------------------------------------------------------------------------
alter table public.product_stock  enable row level security;
alter table public.product_colors enable row level security;

revoke all on public.product_stock  from anon;
revoke all on public.product_colors from anon;

do $$
declare t text;
begin
  foreach t in array array['product_stock','product_colors'] loop
    execute format('drop policy if exists %I on public.%I', t||'_staff_select', t);
    execute format('drop policy if exists %I on public.%I', t||'_staff_insert', t);
    execute format('drop policy if exists %I on public.%I', t||'_staff_update', t);
    execute format('drop policy if exists %I on public.%I', t||'_staff_delete', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.current_role_is_staff()))', t||'_staff_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.current_role_is_staff()))', t||'_staff_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.current_role_is_staff())) with check ((select public.current_role_is_staff()))', t||'_staff_update', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.current_role_is_staff()))', t||'_staff_delete', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Storefront view: colour options WITHOUT quantities / internal fields.
--    Deliberately runs with the owner's rights (base table is staff-only);
--    it only exposes active colours of active products.
-- ---------------------------------------------------------------------------
create or replace view public.product_colors_public as
  select c.id,
         c.product_id,
         c.color_name,
         c.color_hex,
         c.image_url,
         c.stock_status,
         c.sort_order
    from public.product_colors c
   where c.is_active
     and exists (select 1 from public.products p where p.id = c.product_id and p.active);

revoke all on public.product_colors_public from public, anon, authenticated;
grant select on public.product_colors_public to anon, authenticated;
comment on view public.product_colors_public is
  'Public storefront colours. No quantities. Intentionally security-definer-style: base table is staff-only.';
