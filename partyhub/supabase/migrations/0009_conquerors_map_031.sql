-- PartyHub «Завоеватели» 0.3.1: map, economy, terrain, special sites and combat modifiers.
-- Additive migration; preserves classic quiz and existing question data.

alter table public.conquest_map_territories
  add column if not exists territory_type text not null default 'ordinary' check (territory_type in ('capital','ordinary','special','neutral')),
  add column if not exists terrain text not null default 'plain' check (terrain in ('plain','forest','mountain','coast')),
  add column if not exists base_defense integer not null default 0 check (base_defense >= 0),
  add column if not exists gold_reward integer not null default 0 check (gold_reward >= 0),
  add column if not exists coastal boolean not null default false,
  add column if not exists special_effect text,
  add column if not exists investment_defense integer not null default 0 check (investment_defense between 0 and 500),
  add column if not exists neutral_reward_claimed boolean not null default false;

alter table public.conquest_game_players
  add column if not exists gold integer not null default 0 check (gold >= 0),
  add column if not exists citadel_bonus_battles_remaining integer not null default 0 check (citadel_bonus_battles_remaining between 0 and 5),
  add column if not exists academy_battles_since_use integer not null default 0 check (academy_battles_since_use between 0 and 3);

alter table public.conquest_games
  add column if not exists citadel_rounds_remaining integer not null default 0 check (citadel_rounds_remaining between 0 and 15),
  add column if not exists citadel_capture_owner uuid references public.room_players(id) on delete set null;

alter table public.conquest_battles
  add column if not exists defender_defense_bonus integer not null default 0,
  add column if not exists attacker_citadel_bonus integer not null default 0;

create table if not exists public.conquest_battle_assists (
  id uuid primary key default gen_random_uuid(),
  battle_id uuid not null references public.conquest_battles(id) on delete cascade,
  player_id uuid not null references public.room_players(id) on delete cascade,
  question_index integer not null,
  removed_option_index integer not null check (removed_option_index between 0 and 3),
  created_at timestamptz not null default now(),
  unique(battle_id, player_id, question_index)
);
alter table public.conquest_battle_assists enable row level security;
revoke all on public.conquest_battle_assists from anon, authenticated;

create or replace function public.init_conquest_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.rooms; v_game public.conquest_games; v_user uuid:=auth.uid();
begin
 select * into r from public.rooms where id=p_room_id for update;
 if not found then raise exception 'Комната не найдена.'; end if;
 if r.host_id<>v_user then raise exception 'Создать карту может только ведущий.'; end if;
 if exists(select 1 from public.conquest_games where room_id=p_room_id) then
   select * into v_game from public.conquest_games where room_id=p_room_id;
   return jsonb_build_object('game_id',v_game.id,'room_id',p_room_id,'status',v_game.status);
 end if;
 update public.rooms set game_type='conquest' where id=p_room_id;
 insert into public.conquest_games(room_id) values(p_room_id) returning * into v_game;
 insert into public.conquest_map_territories(game_id,territory_key,name,position_x,position_y,territory_type,terrain,base_defense,gold_reward,coastal,special_effect) values
 (v_game.id,'t01','Западная столица',10,50,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t02','Западные низины',23,50,'ordinary','plain',0,0,false,null),
 (v_game.id,'t03','Перевал Чёрного хребта',35,35,'special','mountain',100,0,false,'pass'),
 (v_game.id,'t04','Сосновые окраины',18,66,'ordinary','forest',100,0,false,null),
 (v_game.id,'t05','Западное побережье',12,80,'ordinary','coast',0,0,true,null),
 (v_game.id,'t06','Северная столица',18,15,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t07','Северные равнины',30,15,'ordinary','plain',0,0,false,null),
 (v_game.id,'t08','Крепость Железная Стража',35,25,'special','mountain',500,0,false,'fortress'),
 (v_game.id,'t09','Сосновые холмы',44,12,'ordinary','forest',100,0,false,null),
 (v_game.id,'t10','Северный мыс',55,10,'ordinary','coast',0,0,true,null),
 (v_game.id,'t11','Восточная столица',72,15,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t12','Торговая долина',48,30,'ordinary','plain',0,0,false,null),
 (v_game.id,'t13','Золотые копи',55,42,'special','mountain',100,0,false,'gold_mine'),
 (v_game.id,'t14','Пепельные окраины',45,48,'neutral','plain',0,20,false,'neutral_reward'),
 (v_game.id,'t15','Забытые башни',52,57,'neutral','mountain',100,40,false,'neutral_reward'),
 (v_game.id,'t16','Столица Восточного побережья',83,45,'capital','coast',0,0,true,'capital'),
 (v_game.id,'t17','Прибрежные поля',75,57,'ordinary','coast',0,0,true,null),
 (v_game.id,'t18','Академия мудрецов',65,38,'special','forest',100,0,false,'academy'),
 (v_game.id,'t19','Каменная граница',63,52,'neutral','mountain',100,60,false,'neutral_reward'),
 (v_game.id,'t20','Цитадель Пепельной Короны',55,67,'neutral','mountain',100,0,false,'citadel'),
 (v_game.id,'t21','Юго-восточная столица',75,82,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t22','Южный перекрёсток',62,82,'ordinary','plain',0,0,false,null),
 (v_game.id,'t23','Свободный порт',85,62,'special','coast',0,0,true,'free_port'),
 (v_game.id,'t24','Долина стражей',43,72,'neutral','forest',100,100,false,'neutral_reward'),
 (v_game.id,'t25','Южные горы',20,82,'ordinary','mountain',100,0,false,null),
 (v_game.id,'t26','Юго-западная столица',10,72,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t27','Западные пастбища',22,60,'ordinary','plain',0,0,false,null),
 (v_game.id,'t28','Древний лес',35,72,'special','forest',250,0,false,'ancient_forest'),
 (v_game.id,'t29','Южный мыс',78,70,'ordinary','coast',0,0,true,null),
 (v_game.id,'t30','Королевский мост',32,48,'special','plain',250,0,false,'royal_bridge');
 insert into public.conquest_map_edges(game_id,territory_a,territory_b) values
 (v_game.id,'t01','t02'),(v_game.id,'t01','t04'),(v_game.id,'t02','t03'),(v_game.id,'t02','t25'),(v_game.id,'t02','t30'),
 (v_game.id,'t03','t12'),(v_game.id,'t03','t13'),(v_game.id,'t03','t14'),(v_game.id,'t03','t30'),
 (v_game.id,'t04','t05'),(v_game.id,'t04','t30'),(v_game.id,'t05','t06'),(v_game.id,'t05','t08'),
 (v_game.id,'t06','t07'),(v_game.id,'t07','t08'),(v_game.id,'t07','t09'),(v_game.id,'t08','t14'),
 (v_game.id,'t09','t11'),(v_game.id,'t10','t11'),(v_game.id,'t10','t12'),
 (v_game.id,'t12','t16'),(v_game.id,'t12','t18'),(v_game.id,'t13','t14'),(v_game.id,'t13','t19'),
 (v_game.id,'t14','t15'),(v_game.id,'t15','t19'),(v_game.id,'t15','t20'),(v_game.id,'t16','t17'),
 (v_game.id,'t17','t18'),(v_game.id,'t17','t22'),(v_game.id,'t18','t19'),(v_game.id,'t19','t20'),(v_game.id,'t19','t24'),
 (v_game.id,'t20','t24'),(v_game.id,'t21','t22'),(v_game.id,'t21','t29'),(v_game.id,'t22','t23'),(v_game.id,'t22','t30'),
 (v_game.id,'t23','t24'),(v_game.id,'t23','t29'),(v_game.id,'t24','t28'),(v_game.id,'t25','t26'),(v_game.id,'t25','t28'),
 (v_game.id,'t26','t27'),(v_game.id,'t27','t28'),(v_game.id,'t27','t29');
 return jsonb_build_object('game_id',v_game.id,'room_id',p_room_id,'status',v_game.status,'territories',30);
end; $$;

create or replace function public.start_conquest_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.rooms; g public.conquest_games; p record; v_count integer:=0; v_capitals text[]:=array['t01','t06','t11','t16','t21','t26']; v_colors text[]:=array['#8b5cf6','#f97316','#06b6d4','#ef4444','#22c55e','#eab308']; v_first uuid;
begin
 select * into r from public.rooms where id=p_room_id for update; select * into g from public.conquest_games where room_id=p_room_id for update;
 if not found then raise exception 'Сначала создай карту игры.'; end if;
 if r.host_id<>auth.uid() then raise exception 'Начать игру может только ведущий.'; end if;
 if g.status<>'lobby' then raise exception 'Игра уже запущена.'; end if;
 for p in select rp.* from public.room_players rp where rp.room_id=p_room_id order by rp.joined_at loop
   v_count:=v_count+1; if v_count>6 then raise exception 'В «Завоевателях» максимум 6 игроков.'; end if;
   insert into public.conquest_game_players(game_id,room_player_id,color,gold) values(g.id,p.id,v_colors[v_count],0) on conflict (game_id,room_player_id) do update set color=excluded.color,is_eliminated=false,eliminated_at=null,disconnected_at=null,reconnect_deadline=null,surrendered_at=null,final_rank=null,gold=0,citadel_bonus_battles_remaining=0,academy_battles_since_use=0;
   update public.conquest_map_territories set owner_player_id=p.id,is_capital=true where game_id=g.id and territory_key=v_capitals[v_count];
   if v_first is null then v_first:=p.id; end if;
 end loop;
 if v_count<2 then raise exception 'Нужно минимум 2 игрока.'; end if;
 update public.conquest_games set status='playing',current_player_id=v_first,turn_number=1,updated_at=now() where id=g.id;
 update public.rooms set status='playing' where id=p_room_id;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,v_first,'game_started',jsonb_build_object('players',v_count,'map_territories',30));
 return jsonb_build_object('status','playing','players',v_count);
end; $$;

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
 select array_agg(id) into v_ids from (select id from public.questions where active and category=any(v_categories) order by random() limit 3) s;
 if coalesce(array_length(v_ids,1),0)<3 then select array_agg(id) into v_ids from (select id from public.questions where active order by random() limit 3) s; end if;
 if coalesce(array_length(v_ids,1),0)<3 then raise exception 'В базе недостаточно активных вопросов.'; end if;
 insert into public.conquest_battles(game_id,turn_number,attacker_player_id,defender_player_id,target_territory_key,battle_type,question_ids,defender_defense_bonus,attacker_citadel_bonus)
 values(g.id,g.turn_number,me.id,v_defender,p_target_key,v_type,v_ids,v_defense,v_citadel_bonus);
 if v_citadel_bonus>0 then update public.conquest_game_players set citadel_bonus_battles_remaining=citadel_bonus_battles_remaining-1 where game_id=g.id and room_player_id=me.id; end if;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,me.id,'battle_started',jsonb_build_object('target',p_target_key,'type',v_type,'defender',v_defender));
 return jsonb_build_object('status','question','type',v_type,'target',p_target_key);
end; $$;

create or replace function public.invest_conquest_defense(p_room_id uuid,p_target_key text,p_gold integer)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; me public.room_players; t public.conquest_map_territories; p public.conquest_game_players; v_cost integer;
begin
 if p_gold is null or p_gold<1 or p_gold>50 then raise exception 'Можно вложить от 1 до 50 золотых за раз.'; end if;
 v_cost:=p_gold;
 select * into g from public.conquest_games where room_id=p_room_id for update;
 select * into me from public.room_players where room_id=p_room_id and user_id=auth.uid();
 select * into p from public.conquest_game_players where game_id=g.id and room_player_id=me.id for update;
 select * into t from public.conquest_map_territories where game_id=g.id and territory_key=p_target_key for update;
 if g.status<>'playing' or g.current_player_id<>me.id or exists(select 1 from public.conquest_battles where game_id=g.id and status='question') then raise exception 'Инвестировать можно только в свой ход вне боя.'; end if;
 if t.owner_player_id<>me.id then raise exception 'Вкладывать золото можно только в собственную территорию.'; end if;
 if t.investment_defense+p_gold*10>500 then raise exception 'Максимум вложенной защиты на территорию — 500.'; end if;
 if p.gold<v_cost then raise exception 'Недостаточно золота.'; end if;
 update public.conquest_game_players set gold=gold-v_cost where game_id=g.id and room_player_id=me.id;
 update public.conquest_map_territories set investment_defense=investment_defense+p_gold*10 where game_id=g.id and territory_key=p_target_key;
 return jsonb_build_object('success',true,'investment_defense',t.investment_defense+p_gold*10,'gold_remaining',p.gold-v_cost);
end; $$;

create or replace function public.use_conquest_academy(p_battle_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare b public.conquest_battles; g public.conquest_games; me public.room_players; q public.questions; v_wrong integer; v_since integer;
begin
 select * into b from public.conquest_battles where id=p_battle_id for update;
 if not found or b.status<>'question' then raise exception 'Нет активного боя.'; end if;
 select * into g from public.conquest_games where id=b.game_id;
 select * into me from public.room_players where room_id=g.room_id and user_id=auth.uid();
 if me.id is distinct from b.attacker_player_id and me.id is distinct from b.defender_player_id then raise exception 'Ты не участник этого боя.'; end if;
 if not exists(select 1 from public.conquest_map_territories where game_id=g.id and owner_player_id=me.id and special_effect='academy') then raise exception 'Для способности нужно владеть Академией мудрецов.'; end if;
 select academy_battles_since_use into v_since from public.conquest_game_players where game_id=g.id and room_player_id=me.id for update;
 if coalesce(v_since,0)<3 then raise exception 'Способность заряжается: нужно завершить ещё % боя(ев).',3-coalesce(v_since,0); end if;
 if exists(select 1 from public.conquest_battle_answers a where a.battle_id=b.id and a.player_id=me.id and a.question_index=b.question_index) then raise exception 'Сначала используй способность до ответа на вопрос.'; end if;
 if exists(select 1 from public.conquest_battle_assists where battle_id=b.id and player_id=me.id and question_index=b.question_index) then raise exception 'Подсказка для этого вопроса уже использована.'; end if;
 select * into q from public.questions where id=b.question_ids[b.question_index+1];
 select i into v_wrong from generate_series(0,3) i where i<>q.correct_index and not exists(select 1 from public.conquest_battle_answers a where a.battle_id=b.id and a.player_id=me.id and a.question_index=b.question_index and a.selected_index=i) order by random() limit 1;
 if v_wrong is null then raise exception 'Нет доступного неверного варианта.'; end if;
 insert into public.conquest_battle_assists(battle_id,player_id,question_index,removed_option_index) values(b.id,me.id,b.question_index,v_wrong);
 update public.conquest_game_players set academy_battles_since_use=0 where game_id=g.id and room_player_id=me.id;
 return jsonb_build_object('removed_option_index',v_wrong);
end; $$;

-- Correct answers stay server-side. The per-player eliminated option is only returned to its owner.
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
   v_battle:=jsonb_build_object('id',active_b.id,'type',active_b.battle_type,'target',active_b.target_territory_key,'attacker',active_b.attacker_player_id,'defender',active_b.defender_player_id,'index',active_b.question_index,'total',3,'attacker_score',active_b.attacker_score,'defender_score',active_b.defender_score,'defender_defense_bonus',active_b.defender_defense_bonus,'attacker_citadel_bonus',active_b.attacker_citadel_bonus,'removed_option_index',v_assist,'question',case when q.id is null then null else jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,'index',active_b.question_index+1,'started_at',active_b.question_started_at) end,'answered',exists(select 1 from public.conquest_battle_answers a where a.battle_id=active_b.id and a.player_id=me.id and a.question_index=active_b.question_index));
 end if;
 return jsonb_build_object('game_id',g.id,'room_id',p_room_id,'room_code',r.code,'status',g.status,'is_host',r.host_id=v_user,'self_player_id',me.id,'current_player_id',g.current_player_id,'turn_number',g.turn_number,'winner_player_id',g.winner_player_id,'citadel_rounds_remaining',g.citadel_rounds_remaining,'territories',v_territories,'players',v_players,'edges',v_edges,'battle',v_battle,'player_count',(select count(*) from public.conquest_game_players where game_id=g.id));
end; $$;

-- Update map/metadata for already-created lobbies; active games are not silently reshuffled.
-- New games are initialized with the canonical map above.

revoke all on function public.invest_conquest_defense(uuid,text,integer) from public,anon;
revoke all on function public.use_conquest_academy(uuid) from public,anon;
grant execute on function public.invest_conquest_defense(uuid,text,integer) to authenticated;
grant execute on function public.use_conquest_academy(uuid) to authenticated;
grant execute on function public.init_conquest_game(uuid) to authenticated;
grant execute on function public.start_conquest_game(uuid) to authenticated;
grant execute on function public.start_conquest_action(uuid,text) to authenticated;
grant execute on function public.get_conquest_state(uuid) to authenticated;

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
 if b.question_index<2 then
   update public.conquest_battles set question_index=question_index+1,question_started_at=now() where id=b.id;
   return jsonb_build_object('status','question','index',b.question_index+2);
 end if;
 select * into v_target from public.conquest_map_territories where game_id=g.id and territory_key=b.target_territory_key for update;
 if b.battle_type='claim' then
   select count(*) into v_answered from public.conquest_battle_answers where battle_id=b.id and player_id=b.attacker_player_id and is_correct;
   if v_answered>=2 then
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

-- Do not expose internal answer keys; only participants may advance the battle.
revoke all on function public.advance_conquest_battle(uuid) from public,anon;
grant execute on function public.advance_conquest_battle(uuid) to authenticated;
grant execute on function public.submit_conquest_answer(uuid,integer,integer) to authenticated;

create or replace function public.submit_conquest_answer(p_battle_id uuid,p_selected_index integer,p_elapsed_ms integer default 0)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare b public.conquest_battles; me public.room_players; q public.questions; v_correct boolean; v_points integer; v_elapsed integer;
begin
 if p_selected_index is null or p_selected_index not between 0 and 3 then raise exception 'Выбери один из четырёх ответов.'; end if;
 select * into b from public.conquest_battles where id=p_battle_id for update; if not found or b.status<>'question' then raise exception 'Бой уже завершён.'; end if;
 select * into me from public.room_players where user_id=auth.uid() and room_id=(select room_id from public.conquest_games where id=b.game_id); if not found then raise exception 'Ты не участник комнаты.'; end if;
 if me.id<>b.attacker_player_id and me.id is distinct from b.defender_player_id then raise exception 'Ты не участвуешь в этом бою.'; end if;
 if now()>b.question_started_at+interval '20 seconds' then raise exception 'Время на ответ истекло.'; end if;
 if exists(select 1 from public.conquest_battle_assists a where a.battle_id=b.id and a.player_id=me.id and a.question_index=b.question_index and a.removed_option_index=p_selected_index) then raise exception 'Этот вариант исключён Академией мудрецов.'; end if;
 select * into q from public.questions where id=b.question_ids[b.question_index+1];
 v_elapsed:=greatest(0,least(20000,(extract(epoch from (now()-b.question_started_at))*1000)::integer)); v_correct:=p_selected_index=q.correct_index; v_points:=case when v_correct then 1000+greatest(0,500-floor(v_elapsed::numeric/20000*500)::integer) else 0 end;
 insert into public.conquest_battle_answers(battle_id,player_id,question_index,question_id,selected_index,is_correct,elapsed_ms,points) values(b.id,me.id,b.question_index,b.question_ids[b.question_index+1],p_selected_index,v_correct,v_elapsed,v_points);
 if me.id=b.attacker_player_id then update public.conquest_battles set attacker_score=attacker_score+v_points where id=b.id; else update public.conquest_battles set defender_score=defender_score+v_points where id=b.id; end if;
 return jsonb_build_object('accepted',true,'points',v_points);
exception when unique_violation then raise exception 'Ответ на этот вопрос уже принят.';
end; $$;
revoke all on function public.submit_conquest_answer(uuid,integer,integer) from public,anon;
grant execute on function public.submit_conquest_answer(uuid,integer,integer) to authenticated;

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
 update public.conquest_map_territories set owner_player_id=null,is_capital=false,investment_defense=0,neutral_reward_claimed=false where game_id=g.id;
 update public.conquest_game_players set is_eliminated=false,eliminated_at=null,disconnected_at=null,reconnect_deadline=null,surrendered_at=null,final_rank=null,gold=0,citadel_bonus_battles_remaining=0,academy_battles_since_use=0 where game_id=g.id;
 update public.conquest_games set status='lobby',current_player_id=null,turn_number=1,winner_player_id=null,citadel_rounds_remaining=0,citadel_capture_owner=null,updated_at=now() where id=g.id;
 update public.rooms set status='lobby' where id=p_room_id;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,(select id from public.room_players where room_id=p_room_id and user_id=v_user limit 1),'rematch_lobby',jsonb_build_object('participants_preserved',true));
 return jsonb_build_object('status','lobby','room_id',p_room_id);
end; $$;
revoke all on function public.reset_conquest_game(uuid) from public,anon;
grant execute on function public.reset_conquest_game(uuid) to authenticated;
