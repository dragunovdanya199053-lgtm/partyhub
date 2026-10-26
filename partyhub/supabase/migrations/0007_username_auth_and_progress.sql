-- Username/password accounts and saved solo quiz progress.
-- Apply after migrations 0001–0006.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  username_lower text generated always as (lower(username)) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[A-Za-zА-Яа-яЁё0-9_-]{3,20}$')
);
create unique index if not exists profiles_username_lower_unique on public.profiles(username_lower);

create or replace function public.handle_new_partyhub_user()
returns trigger language plpgsql security definer set search_path = public, auth as $$
declare v_username text;
begin
  v_username := trim(coalesce(new.raw_user_meta_data->>'username', ''));
  if v_username = '' then
    -- Preserve existing anonymous users and any other auth flow without exposing their synthetic email.
    v_username := 'guest_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  insert into public.profiles(id, username)
  values (new.id, v_username)
  on conflict (id) do update set username = excluded.username, updated_at = now();
  return new;
end; $$;

drop trigger if exists on_partyhub_user_created on auth.users;
create trigger on_partyhub_user_created
after insert or update of raw_user_meta_data on auth.users
for each row execute function public.handle_new_partyhub_user();

-- Backfill current auth users (including anonymous sessions) without changing their auth identities.
insert into public.profiles(id, username)
select u.id,
  case when trim(coalesce(u.raw_user_meta_data->>'username','')) <> ''
       then trim(u.raw_user_meta_data->>'username')
       else 'guest_' || substr(replace(u.id::text, '-', ''), 1, 12) end
from auth.users u
on conflict (id) do nothing;

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
create policy "users can read own profile" on public.profiles
  for select to authenticated using (id = auth.uid());

create table if not exists public.solo_game_progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  status text not null default 'in_progress' check (status in ('in_progress','completed')),
  updated_at timestamptz not null default now()
);
alter table public.solo_game_progress enable row level security;
revoke all on public.solo_game_progress from anon, authenticated;
grant select, insert, update, delete on public.solo_game_progress to authenticated;
create policy "users manage own solo progress" on public.solo_game_progress
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Allows username lookup to be handled by Supabase Auth using a non-deliverable synthetic address.
-- In Supabase Dashboard, disable Authentication > Providers > Email > Confirm email.
-- Synthetic address convention used by the app: a deterministic base64url alias at users.partyhub.invalid
