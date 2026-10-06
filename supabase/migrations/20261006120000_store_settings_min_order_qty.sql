-- MOQ (Minimum Order Quantity) for the site-wide B2B order policy.
-- Like the Minimum Order Value it is for the WHOLE order (mix & match), never per product.
-- Optional: NULL = not set, and the storefront hides the MOQ row until a real value is entered in Admin → Order Policy.
-- Non-destructive: one nullable column, no existing data changes.

alter table public.store_settings
  add column if not exists min_order_qty integer
  check (min_order_qty is null or (min_order_qty >= 1 and min_order_qty <= 100000));

comment on column public.store_settings.min_order_qty is
  'MOQ: minimum number of pieces in a complete order (mix & match). NULL = not set (hidden on the website).';

grant select (min_order_qty) on public.store_settings to anon, authenticated;
grant update (min_order_qty) on public.store_settings to authenticated;
