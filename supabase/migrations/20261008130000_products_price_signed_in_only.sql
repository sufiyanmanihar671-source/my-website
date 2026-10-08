-- Wholesale prices are for signed-in accounts only.
-- Before: anon could SELECT every products column, so `price` was readable by anyone through the API
-- even though the website shows "Login to See Price". After: anon may read every catalogue column
-- EXCEPT price; signed-in users (customers and staff) keep full access exactly as before.
--
-- Deploy order: the storefront must already request price only when signed in (index.html loadPrices),
-- otherwise anonymous catalogue reads that include `price` fail.
-- Rollback (if ever needed): grant select on public.products to anon;

revoke select on public.products from anon;
grant select (id, code, name, category_id, subcategory_id, material, description,
              stock_status, stock_state, motif, tint, active, created_at, updated_at)
  on public.products to anon;
