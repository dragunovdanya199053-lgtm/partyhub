-- PartyHub feature upgrade: numeric room codes, balanced topic selection,
-- rematches, lobby settings, question reports and admin moderation.

-- Numeric six-digit room codes.
alter table public.rooms drop constraint if exists rooms_code_check;
update public.rooms set code=lpad(floor(random()*1000000)::int::text,6,'0') where code !~ '^[0-9]{6}$';
alter table public.rooms add constraint rooms_code_check check (code ~ '^[0-9]{6}$');

create or replace function public.create_room(p_display_name text, p_question_count integer default 10, p_categories text[] default array['Общие знания и логика']::text[], p_timer_seconds integer default 20)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_user uuid := auth.uid(); v_room public.rooms; v_code text; v_name text := left(trim(coalesce(p_display_name,'')),20); v_attempt integer := 0;
begin
  if v_user is null then raise exception 'Для создания комнаты нужен гостевой вход.'; end if;
  if v_name = '' then raise exception 'Укажи имя игрока.'; end if;
  if p_question_count not in (10,20,30,50,75,100) then raise exception 'Недопустимое количество вопросов.'; end if;
  if p_timer_seconds not in (10,15,20,30) then raise exception 'Недопустимое время вопроса.'; end if;
  if coalesce(array_length(p_categories,1),0) < 1 then raise exception 'Выбери хотя бы одну тему.'; end if;
  loop
    v_code := lpad(floor(random()*1000000)::int::text,6,'0');
    begin
      insert into public.rooms(code,host_id,question_count,categories,timer_seconds) values(v_code,v_user,p_question_count,p_categories,p_timer_seconds) returning * into v_room;
      exit;
    exception when unique_violation then
      v_attempt := v_attempt + 1;
      if v_attempt > 20 then raise exception 'Не удалось подобрать код комнаты. Попробуй ещё раз.'; end if;
    end;
  end loop;
  insert into public.room_players(room_id,user_id,display_name) values(v_room.id,v_user,v_name);
  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,'status',v_room.status,'host_id',v_user);
end; $$;

create or replace function public.join_room(p_room_code text, p_display_name text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_user uuid := auth.uid(); v_room public.rooms; v_name text := left(trim(coalesce(p_display_name,'')),20); v_count integer;
begin
  if v_user is null then raise exception 'Для входа нужен гостевой вход.'; end if;
  if v_name = '' then raise exception 'Укажи имя игрока.'; end if;
  if trim(coalesce(p_room_code,'')) !~ '^[0-9]{6}$' then raise exception 'Код комнаты должен состоять из шести цифр.'; end if;
  select * into v_room from public.rooms where code = trim(p_room_code) for update;
  if not found then raise exception 'Комната не найдена. Проверь код.'; end if;
  if v_room.status <> 'lobby' then raise exception 'Игра уже началась или комната закрыта.'; end if;
  if exists(select 1 from public.room_players where room_id=v_room.id and user_id=v_user) then
    return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,'status',v_room.status,'host_id',v_room.host_id);
  end if;
  select count(*) into v_count from public.room_players where room_id=v_room.id;
  if v_count >= 12 then raise exception 'В комнате уже максимальное количество игроков (12).'; end if;
  if exists(select 1 from public.room_players where room_id=v_room.id and lower(display_name)=lower(v_name)) then raise exception 'Это имя уже занято в комнате.'; end if;
  insert into public.room_players(room_id,user_id,display_name) values(v_room.id,v_user,v_name);
  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,'status',v_room.status,'host_id',v_room.host_id);
end; $$;

-- Admin accounts are normal Supabase Auth users explicitly allow-listed here by user id.
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admin_users enable row level security;
revoke all on public.admin_users from anon, authenticated;
create or replace function public.is_partyhub_admin()
returns boolean language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from public.admin_users where user_id=auth.uid());
$$;
revoke all on function public.is_partyhub_admin() from public;
grant execute on function public.is_partyhub_admin() to authenticated;

create table if not exists public.question_reports (
  id bigint generated always as identity primary key,
  question_id integer not null references public.questions(id) on delete cascade,
  room_id uuid references public.rooms(id) on delete set null,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason text not null default 'Возможная ошибка или неоднозначность',
  status text not null default 'pending' check(status in ('pending','kept','removed')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  unique(question_id,reporter_id,status)
);
alter table public.question_reports enable row level security;
revoke all on public.question_reports from anon, authenticated;
create policy "admins can read question reports" on public.question_reports for select to authenticated using (public.is_partyhub_admin());
create policy "admins can read questions" on public.questions for select to authenticated using (public.is_partyhub_admin());
grant select on public.questions to authenticated;
grant select on public.question_reports to authenticated;

create or replace function public.report_question(p_room_id uuid, p_question_id integer, p_reason text default 'Возможная ошибка или неоднозначность')
returns jsonb language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'Для отправки жалобы нужна гостевая сессия.'; end if;
  if p_room_id is not null and not public.is_room_member(p_room_id) then raise exception 'Нет доступа к этой комнате.'; end if;
  if not exists(select 1 from public.questions where id=p_question_id) then raise exception 'Вопрос не найден.'; end if;
  insert into public.question_reports(question_id,room_id,reporter_id,reason)
  values(p_question_id,p_room_id,auth.uid(),left(coalesce(nullif(trim(p_reason),''),'Возможная ошибка или неоднозначность'),500))
  on conflict do nothing;
  return jsonb_build_object('ok',true);
end; $$;

create or replace function public.update_room_settings(p_room_id uuid,p_question_count integer,p_categories text[],p_timer_seconds integer)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_available integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>auth.uid() then raise exception 'Только ведущий может менять настройки.'; end if;
  if r.status<>'lobby' then raise exception 'Настройки можно менять только в лобби.'; end if;
  if p_question_count not in (10,20,30,50,75,100) then raise exception 'Недопустимое количество вопросов.'; end if;
  if p_timer_seconds not in (10,15,20,30) then raise exception 'Недопустимое время ответа.'; end if;
  if coalesce(array_length(p_categories,1),0)<1 then raise exception 'Выбери хотя бы одну тему.'; end if;
  select count(*) into v_available from public.questions where active and category=any(p_categories);
  if v_available<p_question_count then raise exception 'В выбранных темах недостаточно активных вопросов. Доступно: %.',v_available; end if;
  update public.rooms set question_count=p_question_count,categories=p_categories,timer_seconds=p_timer_seconds,updated_at=now() where id=p_room_id;
  return jsonb_build_object('ok',true);
end; $$;

-- Rematch keeps the same room and players, resets scores, and returns everyone to lobby.
create or replace function public.rematch_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>auth.uid() then raise exception 'Только ведущий может запустить реванш.'; end if;
  if r.status<>'finished' then raise exception 'Реванш доступен после завершения матча.'; end if;
  delete from public.room_answers where room_id=p_room_id;
  update public.room_players set score=0,lives=3,streak=0,best_streak=0,correct_answers=0,wrong_answers=0,speed_bonus=0,streak_bonus=0,eliminated_at=null where room_id=p_room_id;
  update public.rooms set status='lobby',phase='question',question_ids='{}',current_index=0,question_started_at=null,revealed_at=null,updated_at=now() where id=p_room_id;
  return jsonb_build_object('status','lobby');
end; $$;

create or replace function public.admin_review_question_report(p_report_id bigint,p_action text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare rep public.question_reports;
begin
  if not public.is_partyhub_admin() then raise exception 'Доступ только для администратора.'; end if;
  if p_action not in ('remove','keep') then raise exception 'Недопустимое действие.'; end if;
  select * into rep from public.question_reports where id=p_report_id for update;
  if not found then raise exception 'Жалоба не найдена.'; end if;
  if p_action='remove' then update public.questions set active=false where id=rep.question_id; end if;
  update public.question_reports set status=case when p_action='remove' then 'removed' else 'kept' end,reviewed_at=now(),reviewed_by=auth.uid() where id=p_report_id;
  return jsonb_build_object('ok',true,'status',case when p_action='remove' then 'removed' else 'kept' end);
end; $$;

-- Balanced category distribution: take one random question per selected category per pass.
create or replace function public.start_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_user uuid := auth.uid(); v_ids integer[]; v_available integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>v_user then raise exception 'Только ведущий может начать игру.'; end if;
  if r.status<>'lobby' then raise exception 'Эта комната уже запущена.'; end if;
  select count(*) into v_available from public.questions where active and category=any(r.categories);
  if v_available<r.question_count then raise exception 'В выбранных темах недостаточно уникальных вопросов. Доступно: %.',v_available; end if;
  with chosen_categories as (
    select c.category, c.ordinality as category_order from unnest(r.categories) with ordinality as c(category,ordinality)
  ), ranked as (
    select q.id, c.category_order, row_number() over(partition by q.category order by random()) as category_rank
    from public.questions q join chosen_categories c on c.category=q.category where q.active
  ), picked as (
    select id,category_order,category_rank from ranked order by category_rank,category_order limit r.question_count
  )
  select array_agg(id order by random()) into v_ids from picked;
  update public.room_players set score=0,lives=3,streak=0,best_streak=0,correct_answers=0,wrong_answers=0,speed_bonus=0,streak_bonus=0,eliminated_at=null where room_id=r.id;
  delete from public.room_answers where room_id=r.id;
  update public.rooms set status='playing',phase='question',question_ids=v_ids,current_index=1,question_started_at=now(),revealed_at=null,updated_at=now() where id=r.id;
  return jsonb_build_object('status','playing','question_count',cardinality(v_ids));
end; $$;

grant execute on function public.create_room(text,integer,text[],integer) to authenticated;
grant execute on function public.join_room(text,text) to authenticated;
grant execute on function public.start_room(uuid) to authenticated;
grant execute on function public.report_question(uuid,integer,text) to authenticated;
grant execute on function public.update_room_settings(uuid,integer,text[],integer) to authenticated;
grant execute on function public.rematch_room(uuid) to authenticated;
grant execute on function public.admin_review_question_report(bigint,text) to authenticated;
revoke all on function public.admin_review_question_report(bigint,text) from public, anon;
revoke all on function public.report_question(uuid,integer,text) from public, anon;
revoke all on function public.update_room_settings(uuid,integer,text[],integer) from public, anon;
revoke all on function public.rematch_room(uuid) from public, anon;
