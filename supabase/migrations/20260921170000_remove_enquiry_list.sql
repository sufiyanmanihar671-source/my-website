-- Remove the "Add to Enquiry List" feature from the database.
--
-- The storefront and the admin panel no longer use any of this (see the same commit), so the
-- customer-facing RPC and the three enquiry tables go, together with their RLS policies,
-- triggers, indexes and foreign keys. Bills are kept; they just no longer point at an enquiry.
--
-- Data removed: 1 enquiry with 1 line (a test enquiry from the admin's own account) and no notes.

-- 1. bills no longer link to an enquiry
alter table public.bills drop constraint if exists bills_enquiry_id_fkey;
drop index if exists public.bills_enquiry_idx;
alter table public.bills drop column if exists enquiry_id;

-- 2. the submit function and the tables (children first)
drop function if exists public.submit_enquiry(jsonb);
drop table if exists public.enquiry_notes;
drop table if exists public.enquiry_items;
drop table if exists public.enquiries;
drop function if exists public.enquiry_notes_touch();
