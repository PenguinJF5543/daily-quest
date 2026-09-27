-- =============================================================
-- Daily Quest — initial migration
-- Tables, RLS, explicit grants, triggers and seed data.
-- =============================================================

-- -------------------------------------------------------------
-- Utilities
-- -------------------------------------------------------------

-- Keeps updated_at current on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Current date in ECT (UTC-5). The whole MVP uses this time zone.
create or replace function public.today_ect()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'America/Guayaquil')::date;
$$;

-- -------------------------------------------------------------
-- Catalogs (defined by the app)
-- -------------------------------------------------------------

create table public.categories (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  icon        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.quest_templates (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null unique,
  type                  text not null check (type in ('check', 'quantity')),
  unit                  text check (unit in ('ml', 'min', 'hours', 'times')),
  category_id           uuid not null references public.categories (id),
  icon                  text,
  default_target_min    numeric,
  default_target_ideal  numeric,
  -- Bitmask: bit 0 = Sunday ... bit 6 = Saturday (same as extract(dow)). 127 = daily.
  default_days_of_week  smallint not null default 127 check (default_days_of_week between 1 and 127),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint quest_templates_targets_check check (
    (type = 'check' and unit is null and default_target_min is null and default_target_ideal is null)
    or
    (type = 'quantity' and unit is not null and default_target_min > 0 and default_target_ideal >= default_target_min)
  )
);

-- -------------------------------------------------------------
-- User data
-- -------------------------------------------------------------

-- 1:1 profile with auth.users.
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text,
  xp_total    integer not null default 0 check (xp_total >= 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.quests (
  id                   uuid primary key default gen_random_uuid(), -- the client sends a UUID v7
  user_id              uuid not null references public.profiles (id) on delete cascade,
  template_id          uuid references public.quest_templates (id),
  category_id          uuid not null references public.categories (id),
  title                text not null check (char_length(title) between 1 and 80),
  type                 text not null check (type in ('check', 'quantity')),
  unit                 text check (unit in ('ml', 'min', 'hours', 'times')),
  target_min           numeric,
  target_ideal         numeric,
  days_of_week         smallint not null default 127 check (days_of_week between 1 and 127),
  current_streak       integer not null default 0 check (current_streak >= 0),
  best_streak          integer not null default 0 check (best_streak >= 0),
  last_completed_date  date,
  archived_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint quests_targets_check check (
    (type = 'check' and unit is null and target_min is null and target_ideal is null)
    or
    (type = 'quantity' and unit is not null and target_min > 0 and target_ideal >= target_min)
  ),
  -- In the MVP users only create check quests; quantity quests come from templates.
  constraint quests_quantity_from_template check (type = 'check' or template_id is not null)
);

create index quests_user_id_idx on public.quests (user_id) where archived_at is null;

-- Contributions to quantity quests (+250 ml, +15 min...).
create table public.quest_logs (
  id          uuid primary key default gen_random_uuid(),
  quest_id    uuid not null references public.quests (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  date        date not null default public.today_ect(),
  amount      numeric not null check (amount > 0),
  logged_at   timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index quest_logs_user_date_idx on public.quest_logs (user_id, date);

create table public.quest_completions (
  id             uuid primary key default gen_random_uuid(),
  quest_id       uuid not null references public.quests (id) on delete cascade,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  date           date not null default public.today_ect(),
  completed_at   timestamptz not null default now(),
  -- 10 base × multiplier (1.0–1.5) => 10–15. The check blocks inflated points from the client.
  multiplier     numeric(3, 2) not null default 1.00 check (multiplier between 1.00 and 1.50),
  points_earned  integer not null check (points_earned between 10 and 15),
  updated_at     timestamptz not null default now(),
  unique (quest_id, date)
);

create index quest_completions_user_date_idx on public.quest_completions (user_id, date);

-- Server only (service role). No grants for the client.
create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index push_subscriptions_user_id_idx on public.push_subscriptions (user_id);

-- -------------------------------------------------------------
-- updated_at triggers
-- -------------------------------------------------------------

create trigger set_updated_at before update on public.categories         for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.quest_templates    for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.profiles           for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.quests             for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.quest_logs         for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.quest_completions  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.push_subscriptions for each row execute function public.set_updated_at();

-- -------------------------------------------------------------
-- Sign-up: create the profile and copy templates into the user's quests
-- -------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, name)
  values (new.id, new.raw_user_meta_data ->> 'name');

  insert into public.quests (
    user_id, template_id, category_id, title, type, unit,
    target_min, target_ideal, days_of_week
  )
  select
    new.id, t.id, t.category_id, t.name, t.type, t.unit,
    t.default_target_min, t.default_target_ideal, t.default_days_of_week
  from public.quest_templates t;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -------------------------------------------------------------
-- xp_total is maintained by the database only (the client cannot edit it)
-- -------------------------------------------------------------

create or replace function public.apply_completion_points()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    update public.profiles set xp_total = xp_total + new.points_earned where id = new.user_id;
    return new;
  elsif tg_op = 'DELETE' then
    update public.profiles set xp_total = greatest(xp_total - old.points_earned, 0) where id = old.user_id;
    return old;
  end if;
  return null;
end;
$$;

create trigger on_completion_change
  after insert or delete on public.quest_completions
  for each row execute function public.apply_completion_points();

-- -------------------------------------------------------------
-- Row Level Security
-- -------------------------------------------------------------

alter table public.categories         enable row level security;
alter table public.quest_templates    enable row level security;
alter table public.profiles           enable row level security;
alter table public.quests             enable row level security;
alter table public.quest_logs         enable row level security;
alter table public.quest_completions  enable row level security;
alter table public.push_subscriptions enable row level security;

-- Catalogs: readable by authenticated users.
create policy "categories_read" on public.categories
  for select to authenticated using (true);

create policy "quest_templates_read" on public.quest_templates
  for select to authenticated using (true);

-- Profile: own row only.
create policy "profiles_select_own" on public.profiles
  for select to authenticated using (id = (select auth.uid()));

create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Quests: own rows only. No DELETE: quests are archived.
create policy "quests_select_own" on public.quests
  for select to authenticated using (user_id = (select auth.uid()));

create policy "quests_insert_own" on public.quests
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy "quests_update_own" on public.quests
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Logs: own rows, on own quests.
create policy "quest_logs_select_own" on public.quest_logs
  for select to authenticated using (user_id = (select auth.uid()));

create policy "quest_logs_insert_own" on public.quest_logs
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and exists (select 1 from public.quests q where q.id = quest_id and q.user_id = (select auth.uid()))
  );

create policy "quest_logs_delete_own" on public.quest_logs
  for delete to authenticated using (user_id = (select auth.uid()));

-- Completions: own rows, on own quests, current day only.
create policy "quest_completions_select_own" on public.quest_completions
  for select to authenticated using (user_id = (select auth.uid()));

create policy "quest_completions_insert_own" on public.quest_completions
  for insert to authenticated with check (
    user_id = (select auth.uid())
    and date = public.today_ect()
    and exists (select 1 from public.quests q where q.id = quest_id and q.user_id = (select auth.uid()))
  );

create policy "quest_completions_delete_own_today" on public.quest_completions
  for delete to authenticated using (
    user_id = (select auth.uid()) and date = public.today_ect()
  );

-- push_subscriptions: no policies => service role only.

-- -------------------------------------------------------------
-- Explicit grants ("Automatically expose new tables" is disabled)
-- -------------------------------------------------------------

grant usage on schema public to authenticated;

grant select on public.categories      to authenticated;
grant select on public.quest_templates to authenticated;

grant select on public.profiles to authenticated;
grant update (name) on public.profiles to authenticated; -- xp_total is not editable

grant select, insert, update on public.quests to authenticated;
grant select, insert, delete on public.quest_logs to authenticated;
grant select, insert, delete on public.quest_completions to authenticated;

-- -------------------------------------------------------------
-- Seed: categories and standard meters
-- -------------------------------------------------------------

insert into public.categories (name, icon) values
  ('Health',   'heart'),
  ('Focus',    'target'),
  ('Exercise', 'dumbbell'),
  ('Home',     'home');

insert into public.quest_templates
  (name, type, unit, category_id, icon, default_target_min, default_target_ideal, default_days_of_week)
values
  ('Drink water', 'quantity', 'ml',    (select id from public.categories where name = 'Health'),   'droplet',  2000, 2500, 127),
  ('Exercise',    'quantity', 'min',   (select id from public.categories where name = 'Exercise'), 'activity', 15,   60,   127),
  ('Sleep well',  'quantity', 'hours', (select id from public.categories where name = 'Health'),   'moon',     7,    8,    127);