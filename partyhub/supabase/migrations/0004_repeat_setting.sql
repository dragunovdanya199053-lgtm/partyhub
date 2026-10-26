-- PartyHub: repeat-question setting and persistent history across rematches.
alter table public.rooms add column if not exists avoid_repeats boolean not null default false;
create table if not exists public.room_question_history (
  room_id uuid not null references public.rooms(id) on delete cascade,
  question_id integer not null references public.questions(id),
  first_used_at timestamptz not null default now(),
  primary key (room_id, question_id)
);
alter table public.room_question_history enable row level security;
revoke all on public.room_question_history from anon, authenticated;

-- Replace settings RPC with an additional avoid-repeats option.
drop function if exists public.update_room_settings(uuid,integer,text[],integer);
create or replace function public.update_room_settings(
  p_room_id uuid, p_question_count integer, p_categories text[], p_timer_seconds integer,
  p_avoid_repeats boolean default false
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_available integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>auth.uid() then raise exception 'Только ведущий может менять настройки.'; end if;
  if r.status<>'lobby' then raise exception 'Настройки можно менять только в лобби.'; end if;
  if p_question_count not in (10,20,30,50,75,100) then raise exception 'Недопустимое количество вопросов.'; end if;
  if p_timer_seconds not in (10,15,20,30) then raise exception 'Недопустимое время ответа.'; end if;
  if coalesce(array_length(p_categories,1),0)<1 then raise exception 'Выбери хотя бы одну тему.'; end if;
  select count(*) into v_available from public.questions q
    where q.active and q.category=any(p_categories)
      and (not p_avoid_repeats or not exists(select 1 from public.room_question_history h where h.room_id=p_room_id and h.question_id=q.id));
  if v_available<p_question_count then
    raise exception 'Недостаточно неиспользованных вопросов для этих настроек. Доступно: %. Отключи «Повторы» или выбери другие темы.',v_available;
  end if;
  update public.rooms set question_count=p_question_count,categories=p_categories,timer_seconds=p_timer_seconds,
    avoid_repeats=coalesce(p_avoid_repeats,false),updated_at=now() where id=p_room_id;
  return jsonb_build_object('ok',true,'avoid_repeats',coalesce(p_avoid_repeats,false));
end; $$;

-- Rematch does not delete room_question_history, so questions already played can be excluded.
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
  return jsonb_build_object('status','lobby','avoid_repeats',r.avoid_repeats);
end; $$;

-- Balanced category selection and persistent used-question history.
create or replace function public.start_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_user uuid := auth.uid(); v_ids integer[]; v_available integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>v_user then raise exception 'Только ведущий может начать игру.'; end if;
  if r.status<>'lobby' then raise exception 'Эта комната уже запущена.'; end if;
  select count(*) into v_available from public.questions q where q.active and q.category=any(r.categories)
    and (not r.avoid_repeats or not exists(select 1 from public.room_question_history h where h.room_id=r.id and h.question_id=q.id));
  if v_available<r.question_count then
    raise exception 'В выбранных темах недостаточно доступных вопросов. Доступно: %. Отключи «Повторы» или выбери другие темы.',v_available;
  end if;
  with chosen_categories as (
    select c.category, c.ordinality as category_order from unnest(r.categories) with ordinality as c(category,ordinality)
  ), ranked as (
    select q.id,q.category,c.category_order,row_number() over(partition by q.category order by random()) as category_rank
    from public.questions q join chosen_categories c on c.category=q.category
    where q.active and (not r.avoid_repeats or not exists(select 1 from public.room_question_history h where h.room_id=r.id and h.question_id=q.id))
  ), picked as (
    select id,category_order,category_rank from ranked order by category_rank,random(),category_order limit r.question_count
  )
  select array_agg(id order by random()) into v_ids from picked;
  if cardinality(v_ids)<>r.question_count then raise exception 'Не удалось подобрать достаточно вопросов. Попробуй отключить повторы.'; end if;
  insert into public.room_question_history(room_id,question_id)
    select r.id, unnest(v_ids) on conflict do nothing;
  update public.room_players set score=0,lives=3,streak=0,best_streak=0,correct_answers=0,wrong_answers=0,speed_bonus=0,streak_bonus=0,eliminated_at=null where room_id=r.id;
  delete from public.room_answers where room_id=r.id;
  update public.rooms set status='playing',phase='question',question_ids=v_ids,current_index=1,question_started_at=now(),revealed_at=null,updated_at=now() where id=r.id;
  return jsonb_build_object('status','playing','question_count',cardinality(v_ids),'avoid_repeats',r.avoid_repeats);
end; $$;

-- Expose the setting to the lobby UI without exposing the answer key before reveal.
create or replace function public.get_room_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_q public.questions; v_self public.room_players; v_answer public.room_answers; v_players jsonb; v_question jsonb;
begin
  if not public.is_room_member(p_room_id) then raise exception 'Нет доступа к этой комнате.'; end if;
  update public.room_players set is_connected=false where room_id=p_room_id and is_connected=true and last_seen_at < now()-interval '15 seconds';
  update public.room_players set is_connected=true,last_seen_at=now() where room_id=p_room_id and user_id=auth.uid() and last_seen_at < now()-interval '5 seconds';
  perform public.advance_room_if_ready(p_room_id);
  select * into r from public.rooms where id=p_room_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'user_id',p.user_id,'display_name',p.display_name,'is_connected',p.is_connected,'score',p.score,'lives',p.lives,'streak',p.streak,'best_streak',p.best_streak,'correct_answers',p.correct_answers,'wrong_answers',p.wrong_answers,'speed_bonus',p.speed_bonus,'streak_bonus',p.streak_bonus,'eliminated',p.lives=0,'is_host',p.user_id=r.host_id) order by p.score desc,p.joined_at asc),'[]'::jsonb)
  into v_players from public.room_players p where p.room_id=r.id;
  select * into v_self from public.room_players where room_id=r.id and user_id=auth.uid();
  if r.status='playing' and r.current_index>0 and r.current_index<=cardinality(r.question_ids) then
    select * into v_q from public.questions where id=r.question_ids[r.current_index];
    select * into v_answer from public.room_answers where room_id=r.id and player_id=v_self.id and question_index=r.current_index;
    v_question := jsonb_build_object('index',r.current_index,'total',cardinality(r.question_ids),'id',v_q.id,'category',v_q.category,'difficulty',v_q.difficulty,'text',v_q.prompt,'answers',v_q.options,'started_at',r.question_started_at,'timer_seconds',r.timer_seconds,'phase',r.phase,'explanation',case when r.phase='reveal' then v_q.explanation else null end,'correct_index',case when r.phase='reveal' then v_q.correct_index else null end,'your_answer',case when v_answer.id is not null then v_answer.selected_index else null end,'answered',v_answer.id is not null);
  end if;
  return jsonb_build_object('room_id',r.id,'room_code',r.code,'status',r.status,'phase',r.phase,'host_id',r.host_id,'question_count',r.question_count,'categories',r.categories,'timer_seconds',r.timer_seconds,'avoid_repeats',r.avoid_repeats,'current_index',r.current_index,'players',v_players,'question',v_question,'is_host',r.host_id=auth.uid(),'self',jsonb_build_object('id',v_self.id,'display_name',v_self.display_name,'score',v_self.score,'lives',v_self.lives,'streak',v_self.streak));
end; $$;

revoke all on function public.start_room(uuid) from public, anon;
revoke all on function public.get_room_state(uuid) from public, anon;
revoke all on function public.rematch_room(uuid) from public, anon;
revoke all on function public.update_room_settings(uuid,integer,text[],integer,boolean) from public, anon;
grant execute on function public.start_room(uuid) to authenticated;
grant execute on function public.get_room_state(uuid) to authenticated;
grant execute on function public.rematch_room(uuid) to authenticated;
grant execute on function public.update_room_settings(uuid,integer,text[],integer,boolean) to authenticated;
