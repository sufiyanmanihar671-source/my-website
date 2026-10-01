-- Colour options become plain text names (shown as text pills on the product page).
-- Non-destructive: no rows, columns or files are removed.
--   * color_hex is no longer required. Existing hex values stay as they are; new colours are saved
--     without one. The format check still applies whenever a value is present (NULL passes a CHECK).
--   * image_url is kept (the storefront and admin simply stop using it), so nothing already
--     uploaded is lost. The storefront view keeps the same columns for older cached pages.

alter table public.product_colors alter column color_hex drop not null;

comment on column public.product_colors.color_name is 'Colour option name shown to customers (text pill). Unique per product, case-insensitive.';
comment on column public.product_colors.color_hex  is 'Legacy swatch colour; optional and no longer used by the site.';
comment on column public.product_colors.image_url  is 'Legacy per-colour photo; kept for existing rows, no longer used by the site.';
