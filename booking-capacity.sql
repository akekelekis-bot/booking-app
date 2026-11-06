-- Τρέξε ΜΙΑ φορά: Supabase (project του booking) -> SQL Editor -> New query -> Paste -> Run
-- Πολλαπλές κρατήσεις ανά slot (1-4 άτομα). Ασφαλές να ξανατρέξει.

alter table availability add column if not exists capacity int not null default 1;
alter table availability drop constraint if exists availability_capacity_check;
alter table availability add constraint availability_capacity_check check (capacity between 1 and 4);

-- ο διαχειριστής (συνδεδεμένος) διαχειρίζεται τα slots
drop policy if exists "Admin manages availability" on availability;
create policy "Admin manages availability" on availability
  for all to authenticated using (true) with check (true);

-- 1) Φρουρός: δεν επιτρέπει περισσότερες κρατήσεις από τη χωρητικότητα (ατομικά, κλειδώνει το slot)
create or replace function bk_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cap int; used int;
begin
  if coalesce(new.status, 'new') = 'cancelled' then return new; end if;
  select capacity into cap from availability where id = new.slot_id for update;
  select count(*) into used from bookings
   where slot_id = new.slot_id and coalesce(status, 'new') <> 'cancelled' and id <> new.id;
  if used >= coalesce(cap, 1) then raise exception 'slot_full'; end if;
  return new;
end $$;
drop trigger if exists bk_guard on bookings;
create trigger bk_guard before insert or update of slot_id, status on bookings
  for each row execute function bk_guard();

-- 2) Συγχρονισμός: is_booked = true μόνο όταν το slot είναι πλήρες (έτσι η σελίδα κρατήσεων κρύβει μόνο τα πλήρη)
create or replace function bk_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  for sid in
    select distinct x from unnest(array[
      case when tg_op <> 'INSERT' then old.slot_id end,
      case when tg_op <> 'DELETE' then new.slot_id end]) x
    where x is not null
  loop
    update availability a set is_booked =
      (select count(*) from bookings b where b.slot_id = a.id and coalesce(b.status, 'new') <> 'cancelled') >= a.capacity
    where a.id = sid;
  end loop;
  return null;
end $$;
drop trigger if exists bk_sync on bookings;
create trigger bk_sync after insert or update or delete on bookings
  for each row execute function bk_sync();

-- 3) Αν αλλάξει η χωρητικότητα, ξαναϋπολογίζεται το «πλήρες»
create or replace function bk_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.is_booked := (select count(*) from bookings b where b.slot_id = new.id and coalesce(b.status, 'new') <> 'cancelled') >= new.capacity
                   and exists (select 1 from bookings b where b.slot_id = new.id);
  return new;
end $$;
drop trigger if exists bk_cap on availability;
create trigger bk_cap before update of capacity on availability
  for each row execute function bk_cap();
