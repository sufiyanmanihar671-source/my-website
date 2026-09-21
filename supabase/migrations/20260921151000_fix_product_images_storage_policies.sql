-- Storage/RLS fix: the product-images staff policies were granted to the `public` role, so an anonymous
-- request had to evaluate current_role_is_staff() (which anon may not execute) and failed with
-- "permission denied for function" instead of being cleanly denied. Scope them to `authenticated`
-- (the only role that can be staff) and wrap the check in a sub-select so it is evaluated once per query.
-- Staff behaviour is unchanged; the public read policy is untouched, so product photos still display.
drop policy if exists product_images_bucket_staff_insert on storage.objects;
drop policy if exists product_images_bucket_staff_update on storage.objects;
drop policy if exists product_images_bucket_staff_delete on storage.objects;

create policy product_images_bucket_staff_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and (select public.current_role_is_staff()));
create policy product_images_bucket_staff_update on storage.objects for update to authenticated
  using      (bucket_id = 'product-images' and (select public.current_role_is_staff()))
  with check (bucket_id = 'product-images' and (select public.current_role_is_staff()));
create policy product_images_bucket_staff_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and (select public.current_role_is_staff()));
