-- PartyHub: fixes for username autofill, unique questions per conquest match, and rematch lobby.
-- Additive migration; preserves existing quiz and player data.

create table if not exists public.conquest_used_questions (
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  question_id integer not null references public.questions(id),
  used_at timestamptz not null default now(),
  primary key (game_id, question_id)
);
alter table public.conquest_used_questions enable row level security;
revoke all on public.conquest_used_questions from anon, authenticated;

-- Backfill questions already used by ongoing or completed matches before this migration.
insert into public.conquest_used_questions(game_id,question_id)
select b.game_id, qid from public.conquest_battles b
cross join lateral unnest(b.question_ids) as qid
on conflict (game_id,question_id) do nothing;

create or replace function public.start_conquest_action(p_room_id uuid,p_target_key text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
  g public.conquest_games;
  me public.room_players;
  target public.conquest_map_territories;
  owner_id uuid;
  v_type text;
  v_ids integer[];
  v_defender uuid;
  v_categories text[];
  v_question_id integer;
begin
 select * into g from public.conquest_games where room_id=p_room_id for update;
 if not found or g.status<>'playing' then raise exception 'Игра не запущена.'; end if;
 select * into me from public.room_players where room_id=p_room_id and user_id=auth.uid();
 if not found then raise exception 'Ты не участник комнаты.'; end if;
 if g.current_player_id<>me.id then raise exception 'Сейчас ход другого игрока.'; end if;
 if exists(select 1 from public.conquest_battles where game_id=g.id and status='question') then raise exception 'Сначала заверши текущий бой.'; end if;
 if not exists(select 1 from public.conquest_game_players where game_id=g.id and room_player_id=me.id and not is_eliminated) then raise exception 'Выбывший игрок не может ходить.'; end if;
 select * into target from public.conquest_map_territories where game_id=g.id and territory_key=p_target_key for update;
 if not found then raise exception 'Территория не найдена.'; end if;
 if not exists(
   select 1 from public.conquest_map_territories own
   where own.game_id=g.id and own.owner_player_id=me.id
     and exists(select 1 from public.conquest_map_edges e where e.game_id=g.id and
       ((e.territory_a=own.territory_key and e.territory_b=target.territory_key) or
        (e.territory_b=own.territory_key and e.territory_a=target.territory_key)))
 ) then raise exception 'Можно действовать только на соседней территории.'; end if;
 owner_id:=target.owner_player_id;
 if owner_id=me.id then raise exception 'Эта территория уже твоя.'; end if;
 if owner_id is null then v_type:='claim'; v_defender:=null; else v_type:='attack'; v_defender:=owner_id; end if;
 select categories into v_categories from public.rooms where id=p_room_id;

 -- First prefer the room's selected categories. If fewer than three unused questions remain,
 -- use any active unused question. Never repeat a question during this game.
 select array_agg(id) into v_ids from (
   select q.id from public.questions q
   where q.active and q.category=any(v_categories)
     and not exists(select 1 from public.conquest_used_questions u where u.game_id=g.id and u.question_id=q.id)
   order by random() limit 3
 ) s;
 if coalesce(array_length(v_ids,1),0)<3 then
   select array_agg(id) into v_ids from (
     select q.id from public.questions q
     where q.active
       and not exists(select 1 from public.conquest_used_questions u where u.game_id=g.id and u.question_id=q.id)
     order by random() limit 3
   ) s;
 end if;
 if coalesce(array_length(v_ids,1),0)<3 then
   raise exception 'В этой партии закончились неиспользованные вопросы. Начни новую игру.';
 end if;
 foreach v_question_id in array v_ids loop
   insert into public.conquest_used_questions(game_id,question_id) values(g.id,v_question_id);
 end loop;
 insert into public.conquest_battles(game_id,turn_number,attacker_player_id,defender_player_id,target_territory_key,battle_type,question_ids)
 values(g.id,g.turn_number,me.id,v_defender,p_target_key,v_type,v_ids);
 insert into public.conquest_action_log(game_id,player_id,action_type,payload)
 values(g.id,me.id,'battle_started',jsonb_build_object('target',p_target_key,'type',v_type,'defender',v_defender));
 return jsonb_build_object('status','question','type',v_type,'target',p_target_key);
end; $$;

-- Allow a finished match to be reset without removing room participants. The host triggers it;
-- all clients observe status='lobby' through the existing polling loop.
create or replace function public.reset_conquest_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; r public.rooms; v_user uuid:=auth.uid();
begin
 select * into r from public.rooms where id=p_room_id for update;
 if not found then raise exception 'Комната не найдена.'; end if;
 if r.host_id<>v_user then raise exception 'Вернуть игроков в лобби может только ведущий.'; end if;
 select * into g from public.conquest_games where room_id=p_room_id for update;
 if not found then raise exception 'Игра не найдена.'; end if;
 if g.status<>'finished' then raise exception 'Новая партия доступна после завершения текущей игры.'; end if;
 delete from public.conquest_battles where game_id=g.id;
 delete from public.conquest_used_questions where game_id=g.id;
 update public.conquest_map_territories set owner_player_id=null,is_capital=false where game_id=g.id;
 update public.conquest_game_players
   set is_eliminated=false,eliminated_at=null,disconnected_at=null,reconnect_deadline=null,surrendered_at=null,final_rank=null
   where game_id=g.id;
 update public.conquest_games set status='lobby',current_player_id=null,turn_number=1,winner_player_id=null,updated_at=now() where id=g.id;
 update public.rooms set status='lobby' where id=p_room_id;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload)
 values(g.id,(select id from public.room_players where room_id=p_room_id and user_id=v_user limit 1),'rematch_lobby',jsonb_build_object('participants_preserved',true));
 return jsonb_build_object('status','lobby','room_id',p_room_id);
end; $$;

-- Reuse existing player rows on rematches instead of violating the game/player unique constraint.
create or replace function public.start_conquest_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.rooms; g public.conquest_games; p record; v_count integer:=0; v_capitals text[]:=array['t01','t05','t11','t15','t21','t25']; v_colors text[]:=array['#8b5cf6','#f97316','#06b6d4','#ef4444','#22c55e','#eab308']; v_first uuid;
begin
 select * into r from public.rooms where id=p_room_id for update;
 select * into g from public.conquest_games where room_id=p_room_id for update;
 if not found then raise exception 'Сначала создай карту игры.'; end if;
 if r.host_id<>auth.uid() then raise exception 'Начать игру может только ведущий.'; end if;
 if g.status<>'lobby' then raise exception 'Игра уже запущена.'; end if;
 for p in select rp.* from public.room_players rp where rp.room_id=p_room_id order by rp.joined_at loop
   v_count:=v_count+1;
   if v_count>6 then raise exception 'В «Завоевателях» максимум 6 игроков.'; end if;
   insert into public.conquest_game_players(game_id,room_player_id,color)
   values(g.id,p.id,v_colors[v_count])
   on conflict (game_id,room_player_id) do update set color=excluded.color,is_eliminated=false,eliminated_at=null,disconnected_at=null,reconnect_deadline=null,surrendered_at=null,final_rank=null;
   update public.conquest_map_territories set owner_player_id=p.id,is_capital=true where game_id=g.id and territory_key=v_capitals[v_count];
   if v_first is null then v_first:=p.id; end if;
 end loop;
 if v_count<2 then raise exception 'Нужно минимум 2 игрока.'; end if;
 update public.conquest_games set status='playing',current_player_id=v_first,turn_number=1,winner_player_id=null,updated_at=now() where id=g.id;
 update public.rooms set status='playing' where id=p_room_id;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload)
 values(g.id,v_first,'game_started',jsonb_build_object('players',v_count,'map_territories',30));
 return jsonb_build_object('status','playing','players',v_count);
end; $$;

revoke all on function public.start_conquest_action(uuid,text) from public,anon;
revoke all on function public.reset_conquest_game(uuid) from public,anon;
revoke all on function public.start_conquest_game(uuid) from public,anon;
grant execute on function public.start_conquest_action(uuid,text) to authenticated;
grant execute on function public.reset_conquest_game(uuid) to authenticated;
grant execute on function public.start_conquest_game(uuid) to authenticated;
