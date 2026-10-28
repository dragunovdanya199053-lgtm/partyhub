-- PartyHub «Завоеватели»: special neutral territories require 4 correct answers out of 5.
-- Ordinary neutral territories and all player-vs-player battles stay at 3 questions.
-- Apply after migrations 0001-0013.
begin;

create or replace function public.start_conquest_action(p_room_id uuid,p_target_key text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; me public.room_players; target public.conquest_map_territories; owner_id uuid; v_type text; v_ids integer[]; v_defender uuid; v_categories text[]; v_defense integer:=0; v_citadel_bonus integer:=0; v_has_port boolean:=false; v_required_questions integer:=3;
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
 if owner_id is null then
   v_type:='claim'; v_defender:=null;
   if target.special_effect in ('gold_mine','fortress','citadel','academy') then v_required_questions:=5; end if;
 else
   v_type:='attack'; v_defender:=owner_id; v_required_questions:=3;
 end if;
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
   limit v_required_questions
 ) available;

 if coalesce(array_length(v_ids,1),0)<v_required_questions then
   raise exception 'В этой партии недостаточно неиспользованных вопросов для этой схватки. Начни новую игру.';
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

create or replace function public.get_conquest_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; r public.rooms; me public.room_players; active_b public.conquest_battles; q public.questions; v_territories jsonb; v_players jsonb; v_edges jsonb; v_battle jsonb; v_user uuid:=auth.uid(); v_assist integer;
begin
 select * into r from public.rooms where id=p_room_id; if not found then raise exception 'Комната не найдена.'; end if;
 select * into me from public.room_players where room_id=p_room_id and user_id=v_user; if not found then raise exception 'Ты не участник этой комнаты.'; end if;
 update public.room_players set is_connected=false where room_id=p_room_id and id<>me.id and last_seen_at<now()-interval '15 seconds';
 update public.room_players set is_connected=true,last_seen_at=now() where id=me.id;
 select * into g from public.conquest_games where room_id=p_room_id; if not found then raise exception 'Карта ещё не создана.'; end if;
 update public.conquest_game_players set disconnected_at=null,reconnect_deadline=null where game_id=g.id and room_player_id=me.id and is_eliminated=false and reconnect_deadline>now();
 update public.conquest_game_players cgp set disconnected_at=coalesce(disconnected_at,now()),reconnect_deadline=coalesce(reconnect_deadline,now()+interval '2 minutes') from public.room_players rp where cgp.room_player_id=rp.id and cgp.game_id=g.id and rp.id<>me.id and rp.last_seen_at<now()-interval '15 seconds' and cgp.is_eliminated=false and cgp.disconnected_at is null;
 update public.conquest_game_players cgp set is_eliminated=true,eliminated_at=now(),surrendered_at=now(),final_rank=(select count(*)+1 from public.conquest_game_players x where x.game_id=g.id and x.is_eliminated=true) where cgp.game_id=g.id and cgp.is_eliminated=false and cgp.reconnect_deadline is not null and cgp.reconnect_deadline<now();
 update public.conquest_map_territories t set owner_player_id=null,is_capital=false,investment_defense=0 from public.conquest_game_players cgp where t.game_id=g.id and t.owner_player_id=cgp.room_player_id and cgp.is_eliminated=true;
 if not exists(select 1 from public.conquest_battles where game_id=g.id and status='question') and exists(select 1 from public.conquest_game_players where game_id=g.id and room_player_id=g.current_player_id and is_eliminated) then
   update public.conquest_games cg set current_player_id=coalesce((select cgp.room_player_id from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id join public.room_players oldp on oldp.id=cg.current_player_id where cgp.game_id=cg.id and not cgp.is_eliminated and rp.joined_at>oldp.joined_at order by rp.joined_at limit 1),(select cgp.room_player_id from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=cg.id and not cgp.is_eliminated order by rp.joined_at limit 1)),turn_number=turn_number+1,updated_at=now() where cg.id=g.id;
   select * into g from public.conquest_games where id=g.id;
 end if;
 if g.status='playing' and (select count(*) from public.conquest_game_players where game_id=g.id and is_eliminated=false)<=1 then
   update public.conquest_games set status='finished',winner_player_id=(select room_player_id from public.conquest_game_players where game_id=g.id and is_eliminated=false limit 1),updated_at=now() where id=g.id returning * into g;
 end if;
 select * into active_b from public.conquest_battles where game_id=g.id and status='question' order by created_at desc limit 1;
 if active_b.id is not null then select * into q from public.questions where id=active_b.question_ids[active_b.question_index+1]; select removed_option_index into v_assist from public.conquest_battle_assists where battle_id=active_b.id and player_id=me.id and question_index=active_b.question_index; end if;
 select coalesce(jsonb_agg(jsonb_build_object('key',t.territory_key,'name',t.name,'x',t.position_x,'y',t.position_y,'owner_player_id',t.owner_player_id,'is_capital',t.is_capital,'territory_type',t.territory_type,'terrain',t.terrain,'base_defense',t.base_defense,'gold_reward',t.gold_reward,'coastal',t.coastal,'special_effect',t.special_effect,'investment_defense',t.investment_defense,'neutral_reward_claimed',t.neutral_reward_claimed) order by t.territory_key),'[]'::jsonb) into v_territories from public.conquest_map_territories t where t.game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',rp.id,'name',rp.display_name,'user_id',rp.user_id,'color',cgp.color,'is_eliminated',cgp.is_eliminated,'disconnected_at',cgp.disconnected_at,'reconnect_deadline',cgp.reconnect_deadline,'surrendered_at',cgp.surrendered_at,'territories',(select count(*) from public.conquest_map_territories t where t.game_id=g.id and t.owner_player_id=rp.id),'gold',cgp.gold,'citadel_bonus_battles_remaining',cgp.citadel_bonus_battles_remaining,'academy_battles_since_use',cgp.academy_battles_since_use) order by rp.joined_at),'[]'::jsonb) into v_players from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('a',e.territory_a,'b',e.territory_b)),'[]'::jsonb) into v_edges from public.conquest_map_edges e where e.game_id=g.id;
 if active_b.id is not null then
   v_battle:=jsonb_build_object('id',active_b.id,'type',active_b.battle_type,'target',active_b.target_territory_key,'attacker',active_b.attacker_player_id,'defender',active_b.defender_player_id,'index',active_b.question_index,'total',cardinality(active_b.question_ids),'attacker_score',active_b.attacker_score,'defender_score',active_b.defender_score,'defender_defense_bonus',active_b.defender_defense_bonus,'attacker_citadel_bonus',active_b.attacker_citadel_bonus,'removed_option_index',v_assist,'question',case when q.id is null then null else jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,'index',active_b.question_index+1,'started_at',active_b.question_started_at) end,'answered',exists(select 1 from public.conquest_battle_answers a where a.battle_id=active_b.id and a.player_id=me.id and a.question_index=active_b.question_index));
 end if;
 return jsonb_build_object('game_id',g.id,'room_id',p_room_id,'room_code',r.code,'status',g.status,'is_host',r.host_id=v_user,'self_player_id',me.id,'current_player_id',g.current_player_id,'turn_number',g.turn_number,'winner_player_id',g.winner_player_id,'citadel_rounds_remaining',g.citadel_rounds_remaining,'territories',v_territories,'players',v_players,'edges',v_edges,'battle',v_battle,'player_count',(select count(*) from public.conquest_game_players where game_id=g.id));
end; $$;

create or replace function public.advance_conquest_battle(p_battle_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare b public.conquest_battles; g public.conquest_games; r public.rooms; v_needed integer; v_answered integer; v_winner uuid; v_alive integer; v_next uuid; v_next_joined timestamptz; v_current_joined timestamptz; v_target public.conquest_map_territories; v_captured boolean:=false; v_rounds integer;
begin
 select * into b from public.conquest_battles where id=p_battle_id for update; if not found or b.status<>'question' then return jsonb_build_object('status','finished'); end if;
 select * into g from public.conquest_games where id=b.game_id for update; select * into r from public.rooms where id=g.room_id;
 if not exists(select 1 from public.room_players where room_id=r.id and user_id=auth.uid()) then raise exception 'Ты не участник этой комнаты.'; end if;
 v_needed:=case when b.defender_player_id is null then 1 else 2 end;
 select count(*) into v_answered from public.conquest_battle_answers where battle_id=b.id and question_index=b.question_index;
 if v_answered<v_needed and now()<b.question_started_at+interval '20 seconds' then return jsonb_build_object('waiting',true); end if;
 if b.question_index<cardinality(b.question_ids)-1 then
   update public.conquest_battles set question_index=question_index+1,question_started_at=now() where id=b.id;
   return jsonb_build_object('status','question','index',b.question_index+2);
 end if;
 select * into v_target from public.conquest_map_territories where game_id=g.id and territory_key=b.target_territory_key for update;
 if b.battle_type='claim' then
   select count(*) into v_answered from public.conquest_battle_answers where battle_id=b.id and player_id=b.attacker_player_id and is_correct;
   if v_answered >= case when cardinality(b.question_ids)>=5 then 4 else 2 end then
     update public.conquest_map_territories set owner_player_id=b.attacker_player_id,investment_defense=0 where game_id=g.id and territory_key=b.target_territory_key;
     v_captured:=true;
   end if;
 else
   if b.attacker_score+b.attacker_citadel_bonus > b.defender_score+b.defender_defense_bonus then
     if v_target.is_capital then
       update public.conquest_game_players set is_eliminated=true,eliminated_at=now(),final_rank=(select count(*)+1 from public.conquest_game_players x where x.game_id=g.id and x.is_eliminated=true) where game_id=g.id and room_player_id=b.defender_player_id;
       update public.conquest_map_territories set owner_player_id=null,is_capital=false,investment_defense=0 from public.conquest_game_players cgp where conquest_map_territories.game_id=g.id and conquest_map_territories.owner_player_id=cgp.room_player_id and cgp.game_id=g.id and cgp.room_player_id=b.defender_player_id;
     end if;
     update public.conquest_map_territories set owner_player_id=b.attacker_player_id,is_capital=false,investment_defense=0 where game_id=g.id and territory_key=b.target_territory_key;
     v_captured:=true;
   end if;
 end if;
 if v_captured then
   if v_target.gold_reward>0 and not v_target.neutral_reward_claimed then
     update public.conquest_game_players set gold=gold+v_target.gold_reward where game_id=g.id and room_player_id=b.attacker_player_id;
     update public.conquest_map_territories set neutral_reward_claimed=true where game_id=g.id and territory_key=b.target_territory_key;
   end if;
   if v_target.special_effect='citadel' then
     update public.conquest_games set citadel_rounds_remaining=15,citadel_capture_owner=b.attacker_player_id where id=g.id;
     g.citadel_rounds_remaining:=15;
     update public.conquest_game_players set citadel_bonus_battles_remaining=5 where game_id=g.id and room_player_id=b.attacker_player_id;
   end if;
 end if;
 -- Academy recharge is personal: each completed battle counts for a participant while they own the Academy.
 update public.conquest_game_players cgp set academy_battles_since_use=least(3,academy_battles_since_use+1)
 where cgp.game_id=g.id and cgp.room_player_id in (b.attacker_player_id,b.defender_player_id)
 and exists(select 1 from public.conquest_map_territories t where t.game_id=g.id and t.owner_player_id=cgp.room_player_id and t.special_effect='academy');
 -- Every completed action ends the active player's turn: +1 per territory and +10 for the Gold Mines.
 update public.conquest_game_players cgp set gold=gold+
   (select count(*) from public.conquest_map_territories t where t.game_id=g.id and t.owner_player_id=cgp.room_player_id)
   + case when exists(select 1 from public.conquest_map_territories t where t.game_id=g.id and t.owner_player_id=cgp.room_player_id and t.special_effect='gold_mine') then 10 else 0 end
 where cgp.game_id=g.id and cgp.room_player_id=b.attacker_player_id;
 update public.conquest_battles set status='finished',finished_at=now() where id=b.id;
 select count(*) into v_alive from public.conquest_game_players where game_id=g.id and not is_eliminated;
 if v_alive<=1 then
   select room_player_id into v_winner from public.conquest_game_players where game_id=g.id and not is_eliminated limit 1;
   update public.conquest_games set status='finished',winner_player_id=v_winner,updated_at=now() where id=g.id;
 else
   select cgp.room_player_id into v_next from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id and not cgp.is_eliminated and rp.joined_at>(select joined_at from public.room_players where id=g.current_player_id) order by rp.joined_at limit 1;
   if v_next is null then select cgp.room_player_id into v_next from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id and not cgp.is_eliminated order by rp.joined_at limit 1; end if;
   select joined_at into v_current_joined from public.room_players where id=g.current_player_id;
   select joined_at into v_next_joined from public.room_players where id=v_next;
   if g.citadel_rounds_remaining>0 and v_next_joined<=v_current_joined then
     v_rounds:=g.citadel_rounds_remaining-1;
     update public.conquest_games set citadel_rounds_remaining=v_rounds,updated_at=now() where id=g.id;
     if v_rounds<=0 then
       update public.conquest_map_territories set owner_player_id=null,is_capital=false,investment_defense=0 where game_id=g.id and special_effect='citadel';
       update public.conquest_games set citadel_rounds_remaining=0,citadel_capture_owner=null,updated_at=now() where id=g.id;
       insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,null,'citadel_returned_to_neutral',jsonb_build_object('rounds',15));
     end if;
   end if;
   update public.conquest_games set current_player_id=v_next,turn_number=turn_number+1,updated_at=now() where id=g.id;
 end if;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,b.attacker_player_id,'battle_finished',jsonb_build_object('target',b.target_territory_key,'type',b.battle_type,'attacker_score',b.attacker_score,'defender_score',b.defender_score,'defender_defense_bonus',b.defender_defense_bonus,'attacker_citadel_bonus',b.attacker_citadel_bonus,'captured',v_captured));
 return jsonb_build_object('status','finished','game_status',case when v_alive<=1 then 'finished' else 'playing' end,'winner_player_id',v_winner,'captured',v_captured);
end; $$;

revoke all on function public.start_conquest_action(uuid,text) from public, anon;
grant execute on function public.start_conquest_action(uuid,text) to authenticated;
revoke all on function public.get_conquest_state(uuid) from public, anon;
grant execute on function public.get_conquest_state(uuid) to authenticated;
revoke all on function public.advance_conquest_battle(uuid) from public, anon;
grant execute on function public.advance_conquest_battle(uuid) to authenticated;

commit;
