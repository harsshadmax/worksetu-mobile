-- Demo accounts and a little history for the Worksetu booking loop.
--
-- Rerunnable: accounts are upserted by a fixed id, and the booking history is
-- cleared for those accounts before it is rewritten, so running this twice
-- leaves the same state rather than doubling it.
--
-- Passwords are set here because these are demo members on a throwaway
-- project, not real people. Sign-in works immediately: email_confirmed_at is
-- set, so nothing depends on a confirmation mail being delivered.
--
--   deepika.demo@worksetu.test  / Customer@123   customer, Adyar
--   arun.demo@worksetu.test     / Customer@123   customer, Velachery
--   ravi.demo@worksetu.test     / Worker@123     worker,   Adyar
--   registrar.demo@worksetu.test/ AdminPass@123  admin

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- accounts
-- The on_auth_user_created trigger turns each of these into a profile row,
-- taking the role from raw_user_meta_data.
-- GoTrue reads several token columns as text and fails the whole sign-in with
-- "Database error querying schema" if they are NULL, which is what a manual
-- insert leaves them as. They are set to empty strings below for that reason.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data,
  confirmation_token, recovery_token, email_change,
  email_change_token_new, email_change_token_current,
  phone_change, phone_change_token, reauthentication_token
) values
 ('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111','authenticated','authenticated',
  'deepika.demo@worksetu.test', crypt('Customer@123', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}',
  '{"role":"customer","name":"Deepika Ramaswamy","phone":"8765432109","locality":"Adyar, Chennai"}', '', '', '', '', '', '', '', ''),

 ('00000000-0000-0000-0000-000000000000','22222222-2222-2222-2222-222222222222','authenticated','authenticated',
  'arun.demo@worksetu.test', crypt('Customer@123', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}',
  '{"role":"customer","name":"Arun Prakash","phone":"9840112233","locality":"Velachery, Chennai"}', '', '', '', '', '', '', '', ''),

 ('00000000-0000-0000-0000-000000000000','33333333-3333-3333-3333-333333333333','authenticated','authenticated',
  'ravi.demo@worksetu.test', crypt('Worker@123', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}',
  '{"role":"worker","name":"Ravi Kumar","phone":"9876543211","locality":"Adyar, Chennai"}', '', '', '', '', '', '', '', ''),

 ('00000000-0000-0000-0000-000000000000','44444444-4444-4444-4444-444444444444','authenticated','authenticated',
  'registrar.demo@worksetu.test', crypt('AdminPass@123', gen_salt('bf')), now(), now(), now(),
  '{"provider":"email","providers":["email"]}',
  '{"role":"admin","name":"Cooperative Registrar","phone":"9840000001","locality":"Chennai"}', '', '', '', '', '', '', '', '')
on conflict (id) do update
  set encrypted_password = excluded.encrypted_password,
      email_confirmed_at = excluded.email_confirmed_at,
      raw_user_meta_data = excluded.raw_user_meta_data;

-- Existing installs predate the trigger for these ids, so make sure the
-- profile matches the metadata either way.
insert into public.profiles (id, role, name, phone, locality)
select u.id,
       (u.raw_user_meta_data ->> 'role')::public.user_role,
       u.raw_user_meta_data ->> 'name',
       u.raw_user_meta_data ->> 'phone',
       u.raw_user_meta_data ->> 'locality'
from auth.users u
where u.id in (
  '11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222',
  '33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444444')
on conflict (id) do update
  set role = excluded.role, name = excluded.name,
      phone = excluded.phone, locality = excluded.locality;

-- ---------------------------------------------------------------- history
-- Cleared first so this file is rerunnable.
delete from public.booking_events
 where booking_id in (select id from public.bookings
                      where customer_id in ('11111111-1111-1111-1111-111111111111',
                                            '22222222-2222-2222-2222-222222222222'));
delete from public.bookings
 where customer_id in ('11111111-1111-1111-1111-111111111111',
                       '22222222-2222-2222-2222-222222222222');

-- One finished job, so the screens have something behind them, and one open
-- request for the worker's pending pool.
insert into public.bookings (id, code, customer_id, worker_id, service, scheduled_at, slot, status, price, commission_pct, created_at)
values
 ('aaaaaaaa-0000-4000-8000-000000000001','WS-10241','11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333',
  'plumbing',   now() - interval '6 days', '11:00 AM', 'completed', 400, 15.00, now() - interval '6 days'),
 ('aaaaaaaa-0000-4000-8000-000000000002','WS-10242','22222222-2222-2222-2222-222222222222', null,
  'electrical', now() + interval '1 day',  '3:00 PM',  'pending',   500, 15.00, now() - interval '20 minutes');

insert into public.booking_events (booking_id, status, actor_id) values
 ('aaaaaaaa-0000-4000-8000-000000000001','pending',   '11111111-1111-1111-1111-111111111111'),
 ('aaaaaaaa-0000-4000-8000-000000000001','accepted',  '33333333-3333-3333-3333-333333333333'),
 ('aaaaaaaa-0000-4000-8000-000000000001','started',   '33333333-3333-3333-3333-333333333333'),
 ('aaaaaaaa-0000-4000-8000-000000000001','completed', '33333333-3333-3333-3333-333333333333'),
 ('aaaaaaaa-0000-4000-8000-000000000002','pending',   '22222222-2222-2222-2222-222222222222');
