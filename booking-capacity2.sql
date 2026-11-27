-- Τρέξε ΜΙΑ φορά: Supabase (project SportsRehub-booking) -> SQL Editor -> New query -> Paste -> Run
-- Κανόνες: Φυσιοθεραπεία = 1 άτομο τη φορά (σκληρό όριο). Γυμναστήριο = μέχρι 4 (το 3 είναι ο κανονικός στόχος, το 4 το επιτρέπεις εσύ).
-- Διάρκεια ραντεβού (60΄/90΄ κ.λπ.): ένα ραντεβού 90΄ δεσμεύει και την επόμενη ώρα. Ασφαλές να ξανατρέξει.

alter table bookings add column if not exists duration int not null default 60;
alter table bookings drop constraint if exists bookings_duration_check;
alter table bookings add constraint bookings_duration_check check (duration between 15 and 240);

-- Φυσιοθεραπεία: πάντα 1. Γυμναστήριο: 1..4.
update availability set capacity = 1 where coalesce(category, 'physio') <> 'gym' and capacity <> 1;
alter table availability drop constraint if exists availability_capacity_check;
alter table availability add constraint availability_capacity_check
  check ((coalesce(category, 'physio') = 'gym' and capacity between 1 and 4) or (coalesce(category, 'physio') <> 'gym' and capacity = 1));

drop policy if exists "Admin manages availability" on availability;
create policy "Admin manages availability" on availability for all to authenticated using (true) with check (true);

-- 1) Φρουρός: ελέγχει ΟΛΗ τη διάρκεια του ραντεβού (όχι μόνο την ώρα έναρξης)
create or replace function bk_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; dur int; isgym boolean; lim int; p time; n int;
begin
  if coalesce(new.status, 'new') = 'cancelled' then return new; end if;
  select * into s from availability where id = new.slot_id;
  if not found then return new; end if;
  isgym := coalesce(s.category, 'physio') = 'gym';
  lim := case when isgym then 4 else 1 end;
  dur := coalesce(new.duration, 60);
  -- σειριοποίηση ανά ημέρα και τμήμα (δύο ταυτόχρονες κρατήσεις δεν περνάνε και οι δύο)
  perform a.id from availability a where a.slot_date = s.slot_date and (coalesce(a.category, 'physio') = 'gym') = isgym order by a.id for update;
  for p in
    select s.slot_time as t
    union
    select sb.slot_time from bookings b join availability sb on sb.id = b.slot_id
     where b.id <> new.id and coalesce(b.status, 'new') <> 'cancelled'
       and sb.slot_date = s.slot_date and (coalesce(sb.category, 'physio') = 'gym') = isgym
       and sb.slot_time > s.slot_time and sb.slot_time < s.slot_time + dur * interval '1 minute'
  loop
    select count(*) into n from bookings b join availability sb on sb.id = b.slot_id
     where b.id <> new.id and coalesce(b.status, 'new') <> 'cancelled'
       and sb.slot_date = s.slot_date and (coalesce(sb.category, 'physio') = 'gym') = isgym
       and sb.slot_time <= p and p < sb.slot_time + coalesce(b.duration, 60) * interval '1 minute';
    if n + 1 > lim then raise exception 'slot_full'; end if;
  end loop;
  return new;
end $$;
drop trigger if exists bk_guard on bookings;
create trigger bk_guard before insert or update of slot_id, status, duration on bookings
  for each row execute function bk_guard();

-- 2) Συγχρονισμός: οι ώρες της φυσιοθεραπείας που καλύπτονται από ραντεβού (και 90΄) κρύβονται από τη δημόσια σελίδα
create or replace function bk_refresh_day(d date) returns void
language plpgsql security definer set search_path = public as $$
begin
  update availability a set is_booked = exists (
    select 1 from bookings b join availability sb on sb.id = b.slot_id
     where coalesce(b.status, 'new') <> 'cancelled' and sb.slot_date = a.slot_date
       and coalesce(sb.category, 'physio') <> 'gym'
       and sb.slot_time <= a.slot_time and a.slot_time < sb.slot_time + coalesce(b.duration, 60) * interval '1 minute')
  where a.slot_date = d and coalesce(a.category, 'physio') <> 'gym';
  update availability a set is_booked =
    (select count(*) from bookings b where b.slot_id = a.id and coalesce(b.status, 'new') <> 'cancelled') >= a.capacity
  where a.slot_date = d and coalesce(a.category, 'physio') = 'gym';
end $$;

create or replace function bk_sync() returns trigger
language plpgsql security definer set search_path = public as $$
declare d date;
begin
  for d in
    select distinct a.slot_date from availability a
     where a.id in (case when tg_op <> 'INSERT' then old.slot_id end, case when tg_op <> 'DELETE' then new.slot_id end)
  loop
    perform bk_refresh_day(d);
  end loop;
  return null;
end $$;
drop trigger if exists bk_sync on bookings;
create trigger bk_sync after insert or update or delete on bookings
  for each row execute function bk_sync();

-- 3) Αν αλλάξει η χωρητικότητα ενός slot, ξαναϋπολογίζεται το «πλήρες»
create or replace function bk_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.category, 'physio') = 'gym' then
    new.is_booked := (select count(*) from bookings b where b.slot_id = new.id and coalesce(b.status, 'new') <> 'cancelled') >= new.capacity
                     and exists (select 1 from bookings b where b.slot_id = new.id);
  end if;
  return new;
end $$;
drop trigger if exists bk_cap on availability;
create trigger bk_cap before update of capacity on availability
  for each row execute function bk_cap();

-- Ένα μόνο ακόμη: κάθε ημέρα που έχει ήδη ραντεβού ξαναϋπολογίζεται τώρα
select bk_refresh_day(d) from (select distinct slot_date d from availability) x;
