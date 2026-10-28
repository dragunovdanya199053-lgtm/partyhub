-- PartyHub «Завоеватели»: guarantee no question repeats during a match.
-- Apply after migrations 0001-0012.
begin;

create table if not exists public.conquest_used_questions (
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  question_id integer not null references public.questions(id),
  used_at timestamptz not null default now(),
  primary key (game_id, question_id)
);

alter table public.conquest_used_questions enable row level security;
revoke all on public.conquest_used_questions from anon, authenticated;

-- Backfill every question that was already dealt in any existing battle.
insert into public.conquest_used_questions(game_id, question_id)
select b.game_id, used_question.question_id
from public.conquest_battles b
cross join lateral unnest(b.question_ids) as used_question(question_id)
on conflict (game_id, question_id) do nothing;

create or replace function public.start_conquest_action(p_room_id uuid,p_target_key text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; me public.room_players; target public.conquest_map_territories; owner_id uuid; v_type text; v_ids integer[]; v_defender uuid; v_categories text[]; v_defense integer:=0; v_citadel_bonus integer:=0; v_has_port boolean:=false;
begin
 select * into g from public.conquest_games where room_id=p_room_id for update; if not found or g.status<>'playing' then raise exception 'Игра не запущена.'; end if;
 select * into me from public.room_players where room_id=p_room_id and user_id=auth.uid(); if not found then raise exception 'Ты не участник комнаты.'; end if;
 if g.current_player_id<>me.id then raise exception 'Сейчас ход другого игрока.'; end if;
 if exists(select 1 from public.conquest_battles where game_id=g.id and status='question') then raise exception 'Сначала заверши текущий бой.'; end if;
 if not exists(select 1 from public.conquest_game_players where game_id=g.id and room_player_id=me.id and not is_eliminated) then raise exception 'Выбывший игрок не может ходить.'; end if;
 select * into target from public.conquest_map_territories where game_id=g.id and territory_key=p_target_key for update; if not found then raise exception 'Территория не найдена.'; end if;
 select exists(select 1 from public.conquest_map_territories where game_id=g.id and owner_player_id=me.id and special_effect='free_port') into v_has_port;
 if not exists(select 1 from public.conquest_map_territories own where own.game_id=g.id and own.owner_player_id=me.id and (
   exists(select 1 from public.conquest_map_edges e where e.game_id=g.id and ((e.territory_a=own.territory_key and e.territory_b=target.territory_key) or (e.territory_b=own.territory_key and e.territory_a=target.territory_key)))
   or (v_has_port and target.coastal and own.special_effect='free_port')
 )) then raise exception 'Можно действовать только на соседней территории или атаковать побережье через Свободный порт.'; end if;
 owner_id:=target.owner_player_id; if owner_id=me.id then raise exception 'Эта территория уже твоя.'; end if;
 if owner_id is null then v_type:='claim'; v_defender:=null; else v_type:='attack'; v_defender:=owner_id; end if;
 if v_defender is not null then
   v_defense:=greatest(target.base_defense,0)+target.investment_defense;
   select citadel_bonus_battles_remaining into v_citadel_bonus from public.conquest_game_players where game_id=g.id and room_player_id=me.id;
   if coalesce(v_citadel_bonus,0)>0 then v_citadel_bonus:=500; else v_citadel_bonus:=0; end if;
 end if;
 select categories into v_categories from public.rooms where id=p_room_id;

 -- Every question is reserved for the whole match as soon as it is dealt.
 -- The game row is locked above, so concurrent actions in this match cannot reserve
 -- the same question at the same time. Prefer room categories, then fill from any
 -- other active, unused questions.
 select array_agg(id) into v_ids
 from (
   select q.id
   from public.questions q
   where q.active
     and not exists (
       select 1
       from public.conquest_used_questions u
       where u.game_id=g.id and u.question_id=q.id
     )
   order by (q.category = any(coalesce(v_categories, array[]::text[]))) desc, random()
   limit 3
 ) available;

 if coalesce(array_length(v_ids,1),0)<3 then
   raise exception 'В этой партии закончились неиспользованные вопросы. Начни новую игру.';
 end if;

 -- Reserve these IDs before creating the battle. This also protects joint fights:
 -- attacker and defender share this battle's questions, and none can be dealt again
 -- later in the same game.
 insert into public.conquest_used_questions(game_id,question_id)
 select g.id, picked.question_id
 from unnest(v_ids) as picked(question_id)
 on conflict (game_id, question_id) do nothing;

 insert into public.conquest_battles(game_id,turn_number,attacker_player_id,defender_player_id,target_territory_key,battle_type,question_ids,defender_defense_bonus,attacker_citadel_bonus)
 values(g.id,g.turn_number,me.id,v_defender,p_target_key,v_type,v_ids,v_defense,v_citadel_bonus);
 if v_citadel_bonus>0 then update public.conquest_game_players set citadel_bonus_battles_remaining=citadel_bonus_battles_remaining-1 where game_id=g.id and room_player_id=me.id; end if;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,me.id,'battle_started',jsonb_build_object('target',p_target_key,'type',v_type,'defender',v_defender));
 return jsonb_build_object('status','question','type',v_type,'target',p_target_key);
end; $$;


revoke all on function public.start_conquest_action(uuid,text) from public, anon;
grant execute on function public.start_conquest_action(uuid,text) to authenticated;

commit;
