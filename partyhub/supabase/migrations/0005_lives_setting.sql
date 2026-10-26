-- PartyHub migration 0005: configurable multiplayer lives (1, 2, 3, or unlimited=0).
-- Safe to run on an existing deployment after migrations 0001-0004.
alter table public.rooms add column if not exists lives_limit integer not null default 3;
alter table public.rooms drop constraint if exists rooms_lives_limit_check;
alter table public.rooms add constraint rooms_lives_limit_check check (lives_limit in (0,1,2,3));

-- Replace RPC signatures to accept lives_limit.
drop function if exists public.create_room(text,integer,text[],integer);
drop function if exists public.update_room_settings(uuid,integer,text[],integer,boolean);

create or replace function public.create_room(p_display_name text, p_question_count integer default 10, p_categories text[] default array['Общие знания и логика']::text[], p_timer_seconds integer default 20, p_lives_limit integer default 3)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_user uuid := auth.uid(); v_room public.rooms; v_code text; v_name text := left(trim(coalesce(p_display_name,'')),20); v_attempt integer := 0;
begin
  if v_user is null then raise exception 'Для создания комнаты нужен гостевой вход.'; end if;
  if v_name = '' then raise exception 'Укажи имя игрока.'; end if;
  if p_question_count not in (10,20,30,50,75,100) then raise exception 'Недопустимое количество вопросов.'; end if;
  if p_timer_seconds not in (10,15,20,30) then raise exception 'Недопустимое время вопроса.'; end if;
  if p_lives_limit not in (0,1,2,3) then raise exception 'Количество жизней должно быть от 1 до 3 или 0 для безлимита.'; end if;
  if coalesce(array_length(p_categories,1),0) < 1 then raise exception 'Выбери хотя бы одну тему.'; end if;
  loop
    v_code := lpad(floor(random()*1000000)::int::text,6,'0');
    begin
      insert into public.rooms(code,host_id,question_count,categories,timer_seconds,lives_limit) values(v_code,v_user,p_question_count,p_categories,p_timer_seconds,p_lives_limit) returning * into v_room;
      exit;
    exception when unique_violation then
      v_attempt := v_attempt + 1;
      if v_attempt > 20 then raise exception 'Не удалось подобрать код комнаты. Попробуй ещё раз.'; end if;
    end;
  end loop;
  insert into public.room_players(room_id,user_id,display_name) values(v_room.id,v_user,v_name);
  return jsonb_build_object('room_id',v_room.id,'room_code',v_room.code,'status',v_room.status,'host_id',v_user);
end; $$;

create or replace function public.advance_room_if_ready(p_room_id uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_qid integer; v_active integer; v_answered integer; p record; v_elapsed integer; v_next_streak integer; v_speed integer; v_chain integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found or r.status <> 'playing' then return; end if;
  if r.phase = 'question' then
    select id into v_qid from public.questions where id = r.question_ids[r.current_index];
    select count(*) into v_active from public.room_players where room_id=r.id and (r.lives_limit=0 or lives>0);
    select count(*) into v_answered from public.room_answers where room_id=r.id and question_index=r.current_index;
    if v_answered < v_active and now() < r.question_started_at + make_interval(secs => r.timer_seconds) then return; end if;
    -- A timeout costs exactly one life and is recorded idempotently.
    for p in select rp.* from public.room_players rp where rp.room_id=r.id and (r.lives_limit=0 or rp.lives>0) and not exists(select 1 from public.room_answers a where a.room_id=r.id and a.player_id=rp.id and a.question_index=r.current_index) loop
      insert into public.room_answers(room_id,player_id,question_index,question_id,selected_index,is_correct,elapsed_ms)
      values(r.id,p.id,r.current_index,v_qid,null,false,r.timer_seconds*1000) on conflict do nothing;
      update public.room_players set lives=case when r.lives_limit=0 then lives else greatest(0,lives-1) end, streak=0, wrong_answers=wrong_answers+1,
        eliminated_at=case when r.lives_limit<>0 and lives-1<=0 then now() else eliminated_at end where id=p.id;
    end loop;
    update public.rooms set phase='reveal',revealed_at=now(),updated_at=now() where id=r.id;
    return;
  end if;
  if r.phase='reveal' and now() >= r.revealed_at + interval '3 seconds' then
    if r.current_index >= cardinality(r.question_ids) or (r.lives_limit<>0 and not exists(select 1 from public.room_players where room_id=r.id and lives>0)) then
      update public.rooms set status='finished',updated_at=now() where id=r.id;
    else
      update public.rooms set current_index=current_index+1,phase='question',question_started_at=now(),revealed_at=null,updated_at=now() where id=r.id;
    end if;
  end if;
end; $$;

create or replace function public.submit_room_answer(p_room_id uuid, p_selected_index integer)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_player public.room_players; v_q public.questions; v_elapsed integer; v_speed integer; v_correct boolean; v_streak integer; v_chain integer; v_award integer;
begin
  if p_selected_index not between 0 and 3 then raise exception 'Некорректный вариант ответа.'; end if;
  select * into r from public.rooms where id=p_room_id for update;
  if not found or r.status <> 'playing' then raise exception 'Сейчас игра не принимает ответы.'; end if;
  if not exists(select 1 from public.room_players where room_id=r.id and user_id=auth.uid()) then raise exception 'Ты не участник этой комнаты.'; end if;
  perform public.advance_room_if_ready(r.id);
  select * into r from public.rooms where id=p_room_id for update;
  if r.status <> 'playing' or r.phase <> 'question' then raise exception 'Время ответа завершено.'; end if;
  if now() >= r.question_started_at + make_interval(secs => r.timer_seconds) then
    perform public.advance_room_if_ready(r.id);
    raise exception 'Время ответа истекло.';
  end if;
  select * into v_player from public.room_players where room_id=r.id and user_id=auth.uid() for update;
  if not found then raise exception 'Ты не участник этой комнаты.'; end if;
  if r.lives_limit<>0 and v_player.lives <= 0 then raise exception 'Ты выбыл из игры и больше не можешь отвечать.'; end if;
  if exists(select 1 from public.room_answers where room_id=r.id and player_id=v_player.id and question_index=r.current_index) then raise exception 'Ответ на этот вопрос уже принят.'; end if;
  select * into v_q from public.questions where id=r.question_ids[r.current_index];
  v_elapsed := greatest(0,floor(extract(epoch from (now()-r.question_started_at))*1000)::integer);
  v_correct := p_selected_index = v_q.correct_index;
  if v_correct then
    v_speed := greatest(0,least(100,floor(100*(r.timer_seconds*1000-v_elapsed)::numeric/(r.timer_seconds*1000))::integer));
    v_streak := v_player.streak+1;
    v_chain := case when v_streak>=2 then least(v_streak,5)*10 else 0 end;
    v_award := 100+v_speed+v_chain;
    update public.room_players set score=score+v_award,streak=v_streak,best_streak=greatest(best_streak,v_streak),correct_answers=correct_answers+1,speed_bonus=speed_bonus+v_speed,streak_bonus=streak_bonus+v_chain where id=v_player.id;
  else
    v_speed := 0; v_chain := 0;
    update public.room_players set lives=case when r.lives_limit=0 then lives else greatest(0,lives-1) end,streak=0,wrong_answers=wrong_answers+1,eliminated_at=case when r.lives_limit<>0 and lives-1<=0 then now() else eliminated_at end where id=v_player.id;
  end if;
  insert into public.room_answers(room_id,player_id,question_index,question_id,selected_index,is_correct,elapsed_ms)
  values(r.id,v_player.id,r.current_index,v_q.id,p_selected_index,v_correct,v_elapsed);
  perform public.advance_room_if_ready(r.id);
  -- Do not disclose correctness or awarded points before the shared reveal phase.
  return jsonb_build_object('accepted',true);
end; $$;

create or replace function public.update_room_settings(
  p_room_id uuid, p_question_count integer, p_categories text[], p_timer_seconds integer,
  p_avoid_repeats boolean default false, p_lives_limit integer default 3
) returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_available integer;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>auth.uid() then raise exception 'Только ведущий может менять настройки.'; end if;
  if r.status<>'lobby' then raise exception 'Настройки можно менять только в лобби.'; end if;
  if p_question_count not in (10,20,30,50,75,100) then raise exception 'Недопустимое количество вопросов.'; end if;
  if p_timer_seconds not in (10,15,20,30) then raise exception 'Недопустимое время ответа.'; end if;
  if p_lives_limit not in (0,1,2,3) then raise exception 'Количество жизней должно быть от 1 до 3 или 0 для безлимита.'; end if;
  if coalesce(array_length(p_categories,1),0)<1 then raise exception 'Выбери хотя бы одну тему.'; end if;
  select count(*) into v_available from public.questions q
    where q.active and q.category=any(p_categories)
      and (not p_avoid_repeats or not exists(select 1 from public.room_question_history h where h.room_id=p_room_id and h.question_id=q.id));
  if v_available<p_question_count then
    raise exception 'Недостаточно неиспользованных вопросов для этих настроек. Доступно: %. Отключи «Повторы» или выбери другие темы.',v_available;
  end if;
  update public.rooms set question_count=p_question_count,categories=p_categories,timer_seconds=p_timer_seconds,
    avoid_repeats=coalesce(p_avoid_repeats,false),lives_limit=p_lives_limit,updated_at=now() where id=p_room_id;
  update public.room_players set lives=case when p_lives_limit=0 then 3 else p_lives_limit end, eliminated_at=null where room_id=p_room_id;
  return jsonb_build_object('ok',true,'avoid_repeats',coalesce(p_avoid_repeats,false));
end; $$;

create or replace function public.rematch_room(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms;
begin
  select * into r from public.rooms where id=p_room_id for update;
  if not found then raise exception 'Комната не найдена.'; end if;
  if r.host_id<>auth.uid() then raise exception 'Только ведущий может запустить реванш.'; end if;
  if r.status<>'finished' then raise exception 'Реванш доступен после завершения матча.'; end if;
  delete from public.room_answers where room_id=p_room_id;
  update public.room_players set score=0,lives=case when r.lives_limit=0 then 3 else r.lives_limit end,streak=0,best_streak=0,correct_answers=0,wrong_answers=0,speed_bonus=0,streak_bonus=0,eliminated_at=null where room_id=p_room_id;
  update public.rooms set status='lobby',phase='question',question_ids='{}',current_index=0,question_started_at=null,revealed_at=null,updated_at=now() where id=p_room_id;
  return jsonb_build_object('status','lobby','avoid_repeats',r.avoid_repeats);
end; $$;

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
  update public.room_players set score=0,lives=case when r.lives_limit=0 then 3 else r.lives_limit end,streak=0,best_streak=0,correct_answers=0,wrong_answers=0,speed_bonus=0,streak_bonus=0,eliminated_at=null where room_id=r.id;
  delete from public.room_answers where room_id=r.id;
  update public.rooms set status='playing',phase='question',question_ids=v_ids,current_index=1,question_started_at=now(),revealed_at=null,updated_at=now() where id=r.id;
  return jsonb_build_object('status','playing','question_count',cardinality(v_ids),'avoid_repeats',r.avoid_repeats);
end; $$;

create or replace function public.get_room_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r public.rooms; v_q public.questions; v_self public.room_players; v_answer public.room_answers; v_players jsonb; v_question jsonb;
begin
  if not public.is_room_member(p_room_id) then raise exception 'Нет доступа к этой комнате.'; end if;
  update public.room_players set is_connected=false where room_id=p_room_id and is_connected=true and last_seen_at < now()-interval '15 seconds';
  update public.room_players set is_connected=true,last_seen_at=now() where room_id=p_room_id and user_id=auth.uid() and last_seen_at < now()-interval '5 seconds';
  perform public.advance_room_if_ready(p_room_id);
  select * into r from public.rooms where id=p_room_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'user_id',p.user_id,'display_name',p.display_name,'is_connected',p.is_connected,'score',p.score,'lives',p.lives,'streak',p.streak,'best_streak',p.best_streak,'correct_answers',p.correct_answers,'wrong_answers',p.wrong_answers,'speed_bonus',p.speed_bonus,'streak_bonus',p.streak_bonus,'eliminated',(r.lives_limit<>0 and p.lives=0),'is_host',p.user_id=r.host_id) order by p.score desc,p.joined_at asc),'[]'::jsonb)
  into v_players from public.room_players p where p.room_id=r.id;
  select * into v_self from public.room_players where room_id=r.id and user_id=auth.uid();
  if r.status='playing' and r.current_index>0 and r.current_index<=cardinality(r.question_ids) then
    select * into v_q from public.questions where id=r.question_ids[r.current_index];
    select * into v_answer from public.room_answers where room_id=r.id and player_id=v_self.id and question_index=r.current_index;
    v_question := jsonb_build_object('index',r.current_index,'total',cardinality(r.question_ids),'id',v_q.id,'category',v_q.category,'difficulty',v_q.difficulty,'text',v_q.prompt,'answers',v_q.options,'started_at',r.question_started_at,'timer_seconds',r.timer_seconds,'phase',r.phase,'explanation',case when r.phase='reveal' then v_q.explanation else null end,'correct_index',case when r.phase='reveal' then v_q.correct_index else null end,'your_answer',case when v_answer.id is not null then v_answer.selected_index else null end,'answered',v_answer.id is not null);
  end if;
  return jsonb_build_object('room_id',r.id,'room_code',r.code,'status',r.status,'phase',r.phase,'host_id',r.host_id,'question_count',r.question_count,'categories',r.categories,'timer_seconds',r.timer_seconds,'lives_limit',r.lives_limit,'avoid_repeats',r.avoid_repeats,'current_index',r.current_index,'players',v_players,'question',v_question,'is_host',r.host_id=auth.uid(),'self',jsonb_build_object('id',v_self.id,'display_name',v_self.display_name,'score',v_self.score,'lives',v_self.lives,'streak',v_self.streak));
end; $$;

-- Keep server-side RPCs inaccessible to anonymous unauthenticated callers.
revoke all on function public.create_room(text,integer,text[],integer,integer) from public, anon;
revoke all on function public.update_room_settings(uuid,integer,text[],integer,boolean,integer) from public, anon;
revoke all on function public.start_room(uuid) from public, anon;
revoke all on function public.submit_room_answer(uuid,integer) from public, anon;
revoke all on function public.get_room_state(uuid) from public, anon;
revoke all on function public.rematch_room(uuid) from public, anon;
revoke all on function public.advance_room_if_ready(uuid) from public, anon;
grant execute on function public.create_room(text,integer,text[],integer,integer) to authenticated;
grant execute on function public.update_room_settings(uuid,integer,text[],integer,boolean,integer) to authenticated;
grant execute on function public.start_room(uuid) to authenticated;
grant execute on function public.submit_room_answer(uuid,integer) to authenticated;
grant execute on function public.get_room_state(uuid) to authenticated;
grant execute on function public.rematch_room(uuid) to authenticated;
