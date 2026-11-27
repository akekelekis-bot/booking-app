-- Τρέξε ΜΙΑ φορά: Supabase (project SportsRehub-booking) -> SQL Editor -> New query -> Paste -> Run
-- 1) Αριθμός συνεδρίας στα ραντεβού  2) Μηνιαίες χρεώσεις (ημερολογιακός μήνας)  Ασφαλές να ξανατρέξει.

alter table bookings add column if not exists session_no int;

create table if not exists billing_plans (
  id uuid primary key default gen_random_uuid(),
  patient_key text not null,
  name text not null,
  cat text not null check (cat in ('physio','gym')),
  price numeric(10,2) not null default 0,
  mode text not null default 'monthly' check (mode in ('monthly','visit')),
  per_week int,
  term_months int not null default 1,
  term_total numeric(10,2),
  term_start date,
  start_date date not null,
  end_date date,
  created_at timestamptz not null default now(),
  unique (patient_key, cat)
);

create table if not exists month_payments (
  patient_key text not null,
  cat text not null check (cat in ('physio','gym')),
  month text not null,                 -- 'YYYY-MM'
  amount_due numeric(10,2),
  amount numeric(10,2) not null default 0,
  paid_at date,
  method text check (method in ('cash','card','bank')),
  receipt boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (patient_key, cat, month)
);

alter table billing_plans enable row level security;
alter table month_payments enable row level security;
drop policy if exists "Admin manages billing_plans" on billing_plans;
create policy "Admin manages billing_plans" on billing_plans for all to authenticated using (true) with check (true);
drop policy if exists "Admin manages month_payments" on month_payments;
create policy "Admin manages month_payments" on month_payments for all to authenticated using (true) with check (true);

-- αν ο πίνακας billing_plans υπήρχε ήδη από προηγούμενο τρέξιμο:
alter table billing_plans add column if not exists mode text not null default 'monthly';
alter table billing_plans add column if not exists per_week int;
alter table billing_plans add column if not exists term_months int not null default 1;
alter table billing_plans add column if not exists term_total numeric(10,2);
alter table billing_plans add column if not exists term_start date;

-- Ανενεργοί ασθενείς (ολοκλήρωσαν τη θεραπεία)
create table if not exists patient_status (
  patient_key text primary key,
  name text,
  inactive_since date not null default current_date,
  created_at timestamptz not null default now()
);
alter table patient_status enable row level security;
drop policy if exists "Admin manages patient_status" on patient_status;
create policy "Admin manages patient_status" on patient_status for all to authenticated using (true) with check (true);

-- Παραπεμπτικό (για τις συνεδρίες των 20 €): σημάδι ότι το παρέλαβες
do $$ begin
  alter table payments add column if not exists referral boolean not null default false;
exception when undefined_table then null; end $$;
