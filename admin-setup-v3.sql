-- Τρέξε το ΜΙΑ φορά: Supabase -> SQL Editor -> New query -> Paste -> Run
-- Προσθέτει «Τμήμα» (Φυσιοθεραπεία / Γυμναστήριο) στα ραντεβού.
alter table availability add column if not exists category text not null default 'physio';
alter table availability drop constraint if exists availability_category_check;
alter table availability add constraint availability_category_check check (category in ('physio','gym'));
alter table availability drop constraint if exists availability_slot_date_slot_time_key;
alter table availability drop constraint if exists availability_date_time_cat_key;
alter table availability add constraint availability_date_time_cat_key unique (slot_date, slot_time, category);
