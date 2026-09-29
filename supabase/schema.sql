-- Worksetu — one end-to-end booking loop, with row-level security.
--
-- This lives in its own Supabase project, separate from the production
-- database that the Express/Prisma API uses. Nothing here touches that one.
--
-- Rerunnable: every object is created if missing and every policy is dropped
-- before it is recreated, so applying this twice is not an error.

-- ---------------------------------------------------------------- types
do $$ begin
  create type public.user_role as enum ('customer', 'worker', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.booking_status as enum ('pending', 'accepted', 'started', 'completed', 'cancelled');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------- profiles
-- One row per auth user. The id IS the auth user id, so every policy below
-- can compare against auth.uid() without a join.
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       public.user_role not null default 'customer',
  name       text not null default '',
  phone      text,
  locality   text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- bookings
create table if not exists public.bookings (
  id             uuid primary key default gen_random_uuid(),
  -- Short human reference. Customers read this out on the phone; a uuid is
  -- not something anyone can say aloud.
  code           text not null unique default 'WS-' || lpad((floor(random() * 90000) + 10000)::text, 5, '0'),
  customer_id    uuid not null references public.profiles(id) on delete cascade,
  worker_id      uuid references public.profiles(id) on delete set null,
  service        text not null,
  scheduled_at   timestamptz,
  slot           text,
  status         public.booking_status not null default 'pending',
  price          numeric(10,2) not null,
  -- Stored per booking, not read from config at settlement time: changing the
  -- commission next month must not restate what this booking meant today.
  commission_pct numeric(5,2) not null default 15.00,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists bookings_customer_idx on public.bookings (customer_id, created_at desc);
create index if not exists bookings_worker_idx   on public.bookings (worker_id, created_at desc);
create index if not exists bookings_pending_idx  on public.bookings (status) where status = 'pending';

-- ------------------------------------------------------------ booking_events
-- Append-only history. Who moved the booking, to what, and when.
create table if not exists public.booking_events (
  id         bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings(id) on delete cascade,
  status     public.booking_status not null,
  actor_id   uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists booking_events_booking_idx on public.booking_events (booking_id, created_at);

-- ------------------------------------------------- new auth user -> profile
-- The role arrives in the signup metadata. Anything unrecognised becomes a
-- customer rather than failing the signup or silently granting more.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested text := coalesce(new.raw_user_meta_data ->> 'role', 'customer');
begin
  insert into public.profiles (id, role, name, phone, locality)
  values (
    new.id,
    case when requested in ('customer', 'worker', 'admin')
         then requested::public.user_role
         else 'customer'::public.user_role end,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    new.raw_user_meta_data ->> 'phone',
    new.raw_user_meta_data ->> 'locality'
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- keep updated_at honest
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists bookings_touch_updated_at on public.bookings;
create trigger bookings_touch_updated_at
  before update on public.bookings
  for each row execute function public.touch_updated_at();

-- --------------------------------------------------------------- role lookup
-- SECURITY DEFINER on purpose: a policy on profiles that reads profiles to
-- find the caller's role would recurse. This runs outside RLS and returns
-- only the caller's own role.
create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

revoke all on function public.current_user_role() from public;
grant execute on function public.current_user_role() to authenticated;

-- ------------------------------------------------------------------- RLS
alter table public.profiles       enable row level security;
alter table public.bookings       enable row level security;
alter table public.booking_events enable row level security;

-- profiles ------------------------------------------------------------
drop policy if exists profiles_select_own       on public.profiles;
drop policy if exists profiles_select_admin     on public.profiles;
drop policy if exists profiles_select_counterpart on public.profiles;
drop policy if exists profiles_update_own       on public.profiles;

create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_select_admin on public.profiles
  for select to authenticated
  using (public.current_user_role() = 'admin');

-- You can read the other party of a booking you are already allowed to see,
-- and nobody else: a customer sees the member assigned to their job, a
-- worker sees who they are going to.
create policy profiles_select_counterpart on public.profiles
  for select to authenticated
  using (exists (
    select 1 from public.bookings b
    where (b.customer_id = auth.uid() and b.worker_id = profiles.id)
       or (b.worker_id  = auth.uid() and b.customer_id = profiles.id)
  ));

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.current_user_role());

-- bookings -------------------------------------------------------------
drop policy if exists bookings_select_customer on public.bookings;
drop policy if exists bookings_select_worker   on public.bookings;
drop policy if exists bookings_select_admin    on public.bookings;
drop policy if exists bookings_insert_customer on public.bookings;
drop policy if exists bookings_update_customer on public.bookings;
drop policy if exists bookings_update_worker   on public.bookings;

-- A customer sees their own bookings. Not "their own plus anything else".
create policy bookings_select_customer on public.bookings
  for select to authenticated
  using (customer_id = auth.uid());

-- A worker sees what is assigned to them, plus the open pending pool they
-- are allowed to pick work from.
create policy bookings_select_worker on public.bookings
  for select to authenticated
  using (
    public.current_user_role() = 'worker'
    and (worker_id = auth.uid() or status = 'pending')
  );

create policy bookings_select_admin on public.bookings
  for select to authenticated
  using (public.current_user_role() = 'admin');

-- A customer can only create a booking in their own name, and only pending:
-- no inserting a row that is already accepted by somebody.
create policy bookings_insert_customer on public.bookings
  for insert to authenticated
  with check (
    customer_id = auth.uid()
    and public.current_user_role() = 'customer'
    and status = 'pending'
    and worker_id is null
  );

-- A customer may cancel their own booking. That is all they may change.
create policy bookings_update_customer on public.bookings
  for update to authenticated
  using (customer_id = auth.uid())
  with check (customer_id = auth.uid() and status = 'cancelled');

-- A worker may take a pending booking, or move one already theirs. The USING
-- clause is what stops them touching another member's job.
create policy bookings_update_worker on public.bookings
  for update to authenticated
  using (
    public.current_user_role() = 'worker'
    and (worker_id = auth.uid() or (worker_id is null and status = 'pending'))
  )
  with check (worker_id = auth.uid());

-- booking_events -------------------------------------------------------
drop policy if exists booking_events_select on public.booking_events;
drop policy if exists booking_events_insert on public.booking_events;

-- Visible exactly when the booking it belongs to is visible.
create policy booking_events_select on public.booking_events
  for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id));

-- You can only write history as yourself, and only against a booking you can
-- already see.
create policy booking_events_insert on public.booking_events
  for insert to authenticated
  with check (
    actor_id = auth.uid()
    and exists (select 1 from public.bookings b where b.id = booking_id)
  );

-- ------------------------------------------------------------- realtime
-- The worker dashboard and the customer tracking screen both subscribe.
do $$ begin
  alter publication supabase_realtime add table public.bookings;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.booking_events;
exception when duplicate_object then null; end $$;
