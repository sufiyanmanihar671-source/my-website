-- Category images, managed from the admin panel.
--
--   categories.image_url   public https URL the storefront shows (NULL = no image -> neutral placeholder)
--   categories.image_path  object path inside the 'category-images' bucket, set only for files the admin
--                          uploaded (NULL for the seeded external photos). Used to delete the old file
--                          when the image is replaced/removed, so nothing accumulates in storage.
--
-- Subcategories have no image on the storefront (they are text filter chips), so they get no image column.

-- ---------------------------------------------------------------------------
-- 1. columns + integrity
-- ---------------------------------------------------------------------------
alter table public.categories
  add column if not exists image_url  text,
  add column if not exists image_path text;

alter table public.categories drop constraint if exists categories_image_url_chk;
alter table public.categories drop constraint if exists categories_image_path_chk;
alter table public.categories add constraint categories_image_url_chk
  check (image_url is null or (image_url ~ '^https://' and char_length(image_url) <= 1000));
-- a category can only point at a file inside ITS OWN folder, so replacing/removing one category's
-- image can never delete another category's file
alter table public.categories add constraint categories_image_path_chk
  check (image_path is null or (image_url is not null and image_path like ('categories/' || id || '/%') and char_length(image_path) <= 200));

-- ---------------------------------------------------------------------------
-- 2. keep the storefront looking exactly as it does today: seed every category with the photo
--    the site currently shows for it (admins can replace or remove any of them)
-- ---------------------------------------------------------------------------
update public.categories c set image_url = v.url
from (values
  ('ad-cz', 'https://images.unsplash.com/photo-1708220040828-9ab1673681d3?auto=format&fit=crop&w=600&q=80'),
  ('antique', 'https://images.unsplash.com/photo-1621274999488-c05dbc5a0f64?auto=format&fit=crop&w=600&q=80'),
  ('bangles', 'https://images.unsplash.com/photo-1679156271456-d6068c543ee7?auto=format&fit=crop&w=600&q=80'),
  ('bracelets', 'https://images.unsplash.com/photo-1679156272446-30738eb5c4e7?auto=format&fit=crop&w=600&q=80'),
  ('bridal-jewellery', 'https://images.unsplash.com/photo-1621274999488-c05dbc5a0f64?auto=format&fit=crop&w=600&q=80'),
  ('daily-wear', 'https://images.unsplash.com/photo-1611598935678-c88dca238fce?auto=format&fit=crop&w=600&q=80'),
  ('earrings', 'https://images.unsplash.com/photo-1727990865600-91f8cb8b0168?auto=format&fit=crop&w=600&q=80'),
  ('hair-accessories', 'https://images.unsplash.com/photo-1569397288884-4d43d6738fbd?auto=format&fit=crop&w=600&q=80'),
  ('jewellery-sets', 'https://images.unsplash.com/photo-1601121141499-17ae80afc03a?auto=format&fit=crop&w=600&q=80'),
  ('kemp', 'https://images.unsplash.com/photo-1621274999488-c05dbc5a0f64?auto=format&fit=crop&w=600&q=80'),
  ('kundan', 'https://images.unsplash.com/photo-1601121141499-17ae80afc03a?auto=format&fit=crop&w=600&q=80'),
  ('necklace-sets', 'https://images.unsplash.com/photo-1611107683227-e9060eccd846?auto=format&fit=crop&w=600&q=80'),
  ('necklaces', 'https://images.unsplash.com/photo-1601121141499-17ae80afc03a?auto=format&fit=crop&w=600&q=80'),
  ('party-wear', 'https://images.unsplash.com/photo-1701777892740-88419a701472?auto=format&fit=crop&w=600&q=80'),
  ('pendant-sets', 'https://images.unsplash.com/photo-1761211106346-939cb32005d7?auto=format&fit=crop&w=600&q=80'),
  ('polki', 'https://images.unsplash.com/photo-1723802205505-2f88b2227718?auto=format&fit=crop&w=600&q=80'),
  ('rings', 'https://images.unsplash.com/photo-1626784215021-2e39ccf971cd?auto=format&fit=crop&w=600&q=80'),
  ('temple-jewellery', 'https://images.unsplash.com/photo-1721103418312-b0057a8c31c2?auto=format&fit=crop&w=600&q=80')
) as v(id, url)
where c.id = v.id and c.image_url is null;

-- ---------------------------------------------------------------------------
-- 3. storage bucket: public READ of files (via their URL), staff-only WRITE
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('category-images', 'category-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists category_images_staff_select on storage.objects;
drop policy if exists category_images_staff_insert on storage.objects;
drop policy if exists category_images_staff_update on storage.objects;
drop policy if exists category_images_staff_delete on storage.objects;

-- No anon SELECT policy on purpose: a public bucket already serves files by URL, and without a
-- SELECT policy visitors cannot list or enumerate the bucket through the API.
create policy category_images_staff_select on storage.objects for select to authenticated
  using (bucket_id = 'category-images' and (select public.current_role_is_staff()));
create policy category_images_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'category-images' and name like 'categories/%' and (select public.current_role_is_staff()));
create policy category_images_staff_update on storage.objects for update to authenticated
  using      (bucket_id = 'category-images' and (select public.current_role_is_staff()))
  with check (bucket_id = 'category-images' and name like 'categories/%' and (select public.current_role_is_staff()));
create policy category_images_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'category-images' and (select public.current_role_is_staff()));
