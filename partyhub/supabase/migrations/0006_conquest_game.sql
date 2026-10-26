-- PartyHub: «Завоеватели» — additive migration. Does not reset or replace classic quiz.
create extension if not exists pgcrypto;

alter table public.rooms add column if not exists game_type text not null default 'quiz';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='rooms_game_type_check') then
    alter table public.rooms add constraint rooms_game_type_check check (game_type in ('quiz','conquest'));
  end if;
end $$;

create table if not exists public.conquest_games (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null unique references public.rooms(id) on delete cascade,
  status text not null default 'lobby' check(status in ('lobby','playing','finished')),
  current_player_id uuid references public.room_players(id) on delete set null,
  turn_number integer not null default 1,
  winner_player_id uuid references public.room_players(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.conquest_game_players (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  room_player_id uuid not null references public.room_players(id) on delete cascade,
  color text not null,
  is_eliminated boolean not null default false,
  eliminated_at timestamptz,
  disconnected_at timestamptz,
  reconnect_deadline timestamptz,
  surrendered_at timestamptz,
  final_rank integer,
  unique(game_id,room_player_id), unique(game_id,color)
);
create table if not exists public.conquest_map_territories (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  territory_key text not null,
  name text not null,
  position_x integer not null check(position_x between 0 and 100),
  position_y integer not null check(position_y between 0 and 100),
  owner_player_id uuid references public.room_players(id) on delete set null,
  is_capital boolean not null default false,
  unique(game_id,territory_key)
);
create table if not exists public.conquest_map_edges (
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  territory_a text not null,
  territory_b text not null,
  primary key(game_id,territory_a,territory_b),
  check(territory_a <> territory_b),
  foreign key(game_id,territory_a) references public.conquest_map_territories(game_id,territory_key) on delete cascade deferrable initially deferred,
  foreign key(game_id,territory_b) references public.conquest_map_territories(game_id,territory_key) on delete cascade deferrable initially deferred
);
create table if not exists public.conquest_battles (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  turn_number integer not null,
  attacker_player_id uuid not null references public.room_players(id) on delete cascade,
  defender_player_id uuid references public.room_players(id) on delete cascade,
  target_territory_key text not null,
  battle_type text not null check(battle_type in ('claim','attack')),
  status text not null default 'question' check(status in ('question','finished')),
  question_ids integer[] not null,
  question_index integer not null default 0,
  question_started_at timestamptz not null default now(),
  attacker_score integer not null default 0,
  defender_score integer not null default 0,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create unique index if not exists conquest_one_active_battle on public.conquest_battles(game_id) where status='question';
create table if not exists public.conquest_battle_answers (
  id uuid primary key default gen_random_uuid(),
  battle_id uuid not null references public.conquest_battles(id) on delete cascade,
  player_id uuid not null references public.room_players(id) on delete cascade,
  question_index integer not null,
  question_id integer not null references public.questions(id),
  selected_index integer check(selected_index between 0 and 3),
  is_correct boolean not null,
  elapsed_ms integer not null default 0,
  points integer not null default 0,
  answered_at timestamptz not null default now(),
  unique(battle_id,player_id,question_index)
);
create table if not exists public.conquest_action_log (
  id bigint generated always as identity primary key,
  game_id uuid not null references public.conquest_games(id) on delete cascade,
  player_id uuid references public.room_players(id) on delete set null,
  action_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.conquest_games enable row level security;
alter table public.conquest_game_players enable row level security;
alter table public.conquest_map_territories enable row level security;
alter table public.conquest_map_edges enable row level security;
alter table public.conquest_battles enable row level security;
alter table public.conquest_battle_answers enable row level security;
alter table public.conquest_action_log enable row level security;
revoke all on public.conquest_games,public.conquest_game_players,public.conquest_map_territories,public.conquest_map_edges,public.conquest_battles,public.conquest_battle_answers,public.conquest_action_log from anon,authenticated;

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
 insert into public.conquest_map_territories(game_id,territory_key,name,position_x,position_y) values
 (v_game.id,'t01','Северный мыс',12,12),(v_game.id,'t02','Сосновый край',28,10),(v_game.id,'t03','Белые холмы',44,13),(v_game.id,'t04','Восточный дозор',62,11),(v_game.id,'t05','Туманный берег',82,14),
 (v_game.id,'t06','Северная долина',8,29),(v_game.id,'t07','Старый тракт',25,28),(v_game.id,'t08','Каменный лес',43,29),(v_game.id,'t09','Золотые поля',61,28),(v_game.id,'t10','Маяк',83,30),
 (v_game.id,'t11','Западная марка',10,46),(v_game.id,'t12','Серебряная река',27,45),(v_game.id,'t13','Королевская равнина',45,47),(v_game.id,'t14','Красный перевал',63,45),(v_game.id,'t15','Восточная марка',82,47),
 (v_game.id,'t16','Южный лес',9,64),(v_game.id,'t17','Три моста',27,63),(v_game.id,'t18','Изумрудная низина',44,65),(v_game.id,'t19','Солнечная бухта',63,64),(v_game.id,'t20','Край утёсов',83,65),
 (v_game.id,'t21','Западные ворота',12,82),(v_game.id,'t22','Лунный порт',28,82),(v_game.id,'t23','Южная столица',44,84),(v_game.id,'t24','Янтарный мыс',62,82),(v_game.id,'t25','Дальний юг',82,83),
 (v_game.id,'t26','Остров воронов',4,6),(v_game.id,'t27','Крепость ветров',34,5),(v_game.id,'t28','Перекрёсток',52,54),(v_game.id,'t29','Затонувший город',72,8),(v_game.id,'t30','Пограничье',94,54);
 insert into public.conquest_map_edges(game_id,territory_a,territory_b) values
 (v_game.id,'t01','t02'),(v_game.id,'t02','t03'),(v_game.id,'t03','t04'),(v_game.id,'t04','t05'),(v_game.id,'t01','t06'),(v_game.id,'t02','t07'),(v_game.id,'t03','t08'),(v_game.id,'t04','t09'),(v_game.id,'t05','t10'),
 (v_game.id,'t06','t07'),(v_game.id,'t07','t08'),(v_game.id,'t08','t09'),(v_game.id,'t09','t10'),(v_game.id,'t06','t11'),(v_game.id,'t07','t12'),(v_game.id,'t08','t13'),(v_game.id,'t09','t14'),(v_game.id,'t10','t15'),
 (v_game.id,'t11','t12'),(v_game.id,'t12','t13'),(v_game.id,'t13','t14'),(v_game.id,'t14','t15'),(v_game.id,'t11','t16'),(v_game.id,'t12','t17'),(v_game.id,'t13','t18'),(v_game.id,'t14','t19'),(v_game.id,'t15','t20'),
 (v_game.id,'t16','t17'),(v_game.id,'t17','t18'),(v_game.id,'t18','t19'),(v_game.id,'t19','t20'),(v_game.id,'t16','t21'),(v_game.id,'t17','t22'),(v_game.id,'t18','t23'),(v_game.id,'t19','t24'),(v_game.id,'t20','t25'),
 (v_game.id,'t21','t22'),(v_game.id,'t22','t23'),(v_game.id,'t23','t24'),(v_game.id,'t24','t25'),(v_game.id,'t26','t01'),(v_game.id,'t27','t02'),(v_game.id,'t27','t07'),(v_game.id,'t28','t13'),(v_game.id,'t28','t18'),(v_game.id,'t28','t19'),(v_game.id,'t29','t04'),(v_game.id,'t29','t09'),(v_game.id,'t30','t15'),(v_game.id,'t30','t20');
 return jsonb_build_object('game_id',v_game.id,'room_id',p_room_id,'status',v_game.status,'territories',30);
end; $$;

create or replace function public.join_conquest_room(p_room_code text,p_display_name text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid:=auth.uid(); r public.rooms; p public.room_players; v_name text:=left(trim(coalesce(p_display_name,'')),20); v_count integer;
begin
 if v_user is null then raise exception 'Для входа нужен гостевой вход.'; end if;
 if v_name='' then raise exception 'Укажи имя игрока.'; end if;
 select * into r from public.rooms where code=upper(trim(p_room_code)) for update;
 if not found then raise exception 'Комната не найдена. Проверь код.'; end if;
 select * into p from public.room_players where room_id=r.id and user_id=v_user;
 if found then
   update public.room_players set is_connected=true,last_seen_at=now() where id=p.id;
   return jsonb_build_object('room_id',r.id,'room_code',r.code,'status',r.status,'host_id',r.host_id,'reconnected',true);
 end if;
 if r.status<>'lobby' then raise exception 'Игра уже началась. Переподключиться можно только из того же гостевого сеанса.'; end if;
 select count(*) into v_count from public.room_players where room_id=r.id;
 if v_count>=6 then raise exception 'В «Завоевателях» максимум 6 игроков.'; end if;
 if exists(select 1 from public.room_players where room_id=r.id and lower(display_name)=lower(v_name)) then raise exception 'Это имя уже занято в комнате.'; end if;
 insert into public.room_players(room_id,user_id,display_name) values(r.id,v_user,v_name) returning * into p;
 return jsonb_build_object('room_id',r.id,'room_code',r.code,'status',r.status,'host_id',r.host_id,'reconnected',false);
end; $$;

create or replace function public.start_conquest_game(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare r public.rooms; g public.conquest_games; p record; v_count integer:=0; v_capitals text[]:=array['t01','t05','t11','t15','t21','t25']; v_colors text[]:=array['#8b5cf6','#f97316','#06b6d4','#ef4444','#22c55e','#eab308']; v_first uuid;
begin
 select * into r from public.rooms where id=p_room_id for update; select * into g from public.conquest_games where room_id=p_room_id for update;
 if not found then raise exception 'Сначала создай карту игры.'; end if;
 if r.host_id<>auth.uid() then raise exception 'Начать игру может только ведущий.'; end if;
 if g.status<>'lobby' then raise exception 'Игра уже запущена.'; end if;
 for p in select rp.* from public.room_players rp where rp.room_id=p_room_id order by rp.joined_at loop
   v_count:=v_count+1; if v_count>6 then raise exception 'В «Завоевателях» максимум 6 игроков.'; end if;
   insert into public.conquest_game_players(game_id,room_player_id,color) values(g.id,p.id,v_colors[v_count]);
   update public.conquest_map_territories set owner_player_id=p.id,is_capital=true where game_id=g.id and territory_key=v_capitals[v_count];
   if v_first is null then v_first:=p.id; end if;
 end loop;
 if v_count<2 then raise exception 'Нужно минимум 2 игрока.'; end if;
 update public.conquest_games set status='playing',current_player_id=v_first,turn_number=1,updated_at=now() where id=g.id;
 update public.rooms set status='playing' where id=p_room_id;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,v_first,'game_started',jsonb_build_object('players',v_count,'map_territories',30));
 return jsonb_build_object('status','playing','players',v_count);
end; $$;

create or replace function public.get_conquest_state(p_room_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; r public.rooms; me public.room_players; active_b public.conquest_battles; q public.questions; v_territories jsonb; v_players jsonb; v_edges jsonb; v_battle jsonb; v_user uuid:=auth.uid();
begin
 select * into r from public.rooms where id=p_room_id; if not found then raise exception 'Комната не найдена.'; end if;
 select * into me from public.room_players where room_id=p_room_id and user_id=v_user;
 if not found then raise exception 'Ты не участник этой комнаты.'; end if;
 update public.room_players set is_connected=false where room_id=p_room_id and id<>me.id and last_seen_at<now()-interval '15 seconds';
 update public.room_players set is_connected=true,last_seen_at=now() where id=me.id;
 select * into g from public.conquest_games where room_id=p_room_id; if not found then raise exception 'Карта ещё не создана.'; end if;
 -- A player who returns before the deadline resumes the same kingdom.
 update public.conquest_game_players set disconnected_at=null,reconnect_deadline=null where game_id=g.id and room_player_id=me.id and is_eliminated=false and reconnect_deadline>now();
 -- Mark a missing participant and surrender after the two-minute reconnect grace period.
 update public.conquest_game_players cgp set disconnected_at=coalesce(disconnected_at,now()),reconnect_deadline=coalesce(reconnect_deadline,now()+interval '2 minutes')
 from public.room_players rp where cgp.room_player_id=rp.id and cgp.game_id=g.id and rp.id<>me.id and rp.last_seen_at<now()-interval '15 seconds' and cgp.is_eliminated=false and cgp.disconnected_at is null;
 update public.conquest_game_players cgp set is_eliminated=true,eliminated_at=now(),surrendered_at=now(),final_rank=(select count(*)+1 from public.conquest_game_players x where x.game_id=g.id and x.is_eliminated=true)
 where cgp.game_id=g.id and cgp.is_eliminated=false and cgp.reconnect_deadline is not null and cgp.reconnect_deadline<now();
 update public.conquest_map_territories t set owner_player_id=null,is_capital=false from public.conquest_game_players cgp where t.game_id=g.id and t.owner_player_id=cgp.room_player_id and cgp.is_eliminated=true;
 -- If the disconnected player owned the turn and no battle is active, skip their turn after surrender.
 if not exists(select 1 from public.conquest_battles where game_id=g.id and status='question') and exists(select 1 from public.conquest_game_players where game_id=g.id and room_player_id=g.current_player_id and is_eliminated) then
   update public.conquest_games cg set current_player_id=coalesce(
     (select cgp.room_player_id from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id join public.room_players oldp on oldp.id=cg.current_player_id where cgp.game_id=cg.id and not cgp.is_eliminated and rp.joined_at>oldp.joined_at order by rp.joined_at limit 1),
     (select cgp.room_player_id from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=cg.id and not cgp.is_eliminated order by rp.joined_at limit 1)),
     turn_number=turn_number+1,updated_at=now() where cg.id=g.id;
   select * into g from public.conquest_games where id=g.id;
 end if;
 if g.status='playing' and (select count(*) from public.conquest_game_players where game_id=g.id and is_eliminated=false)<=1 then
   update public.conquest_games set status='finished',winner_player_id=(select room_player_id from public.conquest_game_players where game_id=g.id and is_eliminated=false limit 1),updated_at=now() where id=g.id returning * into g;
 end if;
 select * into active_b from public.conquest_battles where game_id=g.id and status='question' order by created_at desc limit 1;
 if active_b.id is not null then select * into q from public.questions where id=active_b.question_ids[active_b.question_index+1]; end if;
 select coalesce(jsonb_agg(jsonb_build_object('key',t.territory_key,'name',t.name,'x',t.position_x,'y',t.position_y,'owner_player_id',t.owner_player_id,'is_capital',t.is_capital) order by t.territory_key),'[]'::jsonb) into v_territories from public.conquest_map_territories t where t.game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('id',rp.id,'name',rp.display_name,'user_id',rp.user_id,'color',cgp.color,'is_eliminated',cgp.is_eliminated,'disconnected_at',cgp.disconnected_at,'reconnect_deadline',cgp.reconnect_deadline,'surrendered_at',cgp.surrendered_at,'territories',(select count(*) from public.conquest_map_territories t where t.game_id=g.id and t.owner_player_id=rp.id)) order by rp.joined_at),'[]'::jsonb) into v_players from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('a',e.territory_a,'b',e.territory_b)),'[]'::jsonb) into v_edges from public.conquest_map_edges e where e.game_id=g.id;
 if active_b.id is not null then
   v_battle:=jsonb_build_object('id',active_b.id,'type',active_b.battle_type,'target',active_b.target_territory_key,'attacker',active_b.attacker_player_id,'defender',active_b.defender_player_id,'index',active_b.question_index,'total',3,'attacker_score',active_b.attacker_score,'defender_score',active_b.defender_score,'question',case when q.id is null then null else jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,'index',active_b.question_index+1,'started_at',active_b.question_started_at) end,'answered',exists(select 1 from public.conquest_battle_answers a where a.battle_id=active_b.id and a.player_id=me.id and a.question_index=active_b.question_index));
 end if;
 return jsonb_build_object('game_id',g.id,'room_id',p_room_id,'room_code',r.code,'status',g.status,'is_host',r.host_id=v_user,'self_player_id',me.id,'current_player_id',g.current_player_id,'turn_number',g.turn_number,'winner_player_id',g.winner_player_id,'territories',v_territories,'players',v_players,'edges',v_edges,'battle',v_battle,'player_count',(select count(*) from public.conquest_game_players where game_id=g.id));
end; $$;

create or replace function public.start_conquest_action(p_room_id uuid,p_target_key text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare g public.conquest_games; me public.room_players; target public.conquest_map_territories; owner_id uuid; v_type text; v_ids integer[]; v_defender uuid; v_categories text[];
begin
 select * into g from public.conquest_games where room_id=p_room_id for update; if not found or g.status<>'playing' then raise exception 'Игра не запущена.'; end if;
 select * into me from public.room_players where room_id=p_room_id and user_id=auth.uid(); if not found then raise exception 'Ты не участник комнаты.'; end if;
 if g.current_player_id<>me.id then raise exception 'Сейчас ход другого игрока.'; end if;
 if exists(select 1 from public.conquest_battles where game_id=g.id and status='question') then raise exception 'Сначала заверши текущий бой.'; end if;
 if not exists(select 1 from public.conquest_game_players where game_id=g.id and room_player_id=me.id and not is_eliminated) then raise exception 'Выбывший игрок не может ходить.'; end if;
 select * into target from public.conquest_map_territories where game_id=g.id and territory_key=p_target_key for update; if not found then raise exception 'Территория не найдена.'; end if;
 if not exists(select 1 from public.conquest_map_territories own where own.game_id=g.id and own.owner_player_id=me.id and exists(select 1 from public.conquest_map_edges e where e.game_id=g.id and ((e.territory_a=own.territory_key and e.territory_b=target.territory_key) or (e.territory_b=own.territory_key and e.territory_a=target.territory_key)))) then raise exception 'Можно действовать только на соседней территории.'; end if;
 owner_id:=target.owner_player_id; if owner_id=me.id then raise exception 'Эта территория уже твоя.'; end if;
 if owner_id is null then v_type:='claim'; v_defender:=null; else v_type:='attack'; v_defender:=owner_id; end if;
 select categories into v_categories from public.rooms where id=p_room_id;
 select array_agg(id) into v_ids from (select id from public.questions where active and category=any(v_categories) order by random() limit 3) s;
 if coalesce(array_length(v_ids,1),0)<3 then select array_agg(id) into v_ids from (select id from public.questions where active order by random() limit 3) s; end if;
 if coalesce(array_length(v_ids,1),0)<3 then raise exception 'В базе недостаточно активных вопросов.'; end if;
 insert into public.conquest_battles(game_id,turn_number,attacker_player_id,defender_player_id,target_territory_key,battle_type,question_ids) values(g.id,g.turn_number,me.id,v_defender,p_target_key,v_type,v_ids);
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,me.id,'battle_started',jsonb_build_object('target',p_target_key,'type',v_type,'defender',v_defender));
 return jsonb_build_object('status','question','type',v_type,'target',p_target_key);
end; $$;

create or replace function public.submit_conquest_answer(p_battle_id uuid,p_selected_index integer,p_elapsed_ms integer default 0)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare b public.conquest_battles; me public.room_players; q public.questions; v_correct boolean; v_points integer; v_elapsed integer;
begin
 if p_selected_index not between 0 and 3 then raise exception 'Выбери один из четырёх ответов.'; end if;
 select * into b from public.conquest_battles where id=p_battle_id for update; if not found or b.status<>'question' then raise exception 'Бой уже завершён.'; end if;
 select * into me from public.room_players where user_id=auth.uid() and room_id=(select room_id from public.conquest_games where id=b.game_id); if not found then raise exception 'Ты не участник комнаты.'; end if;
 if me.id<>b.attacker_player_id and me.id is distinct from b.defender_player_id then raise exception 'Ты не участвуешь в этом бою.'; end if;
 select * into q from public.questions where id=b.question_ids[b.question_index+1];
 if now()>b.question_started_at+interval '20 seconds' then raise exception 'Время на ответ истекло.'; end if;
 v_elapsed:=greatest(0,least(20000,(extract(epoch from (now()-b.question_started_at))*1000)::integer)); v_correct:=p_selected_index=q.correct_index; v_points:=case when v_correct then 1000+greatest(0,500-floor(v_elapsed::numeric/20000*500)::integer) else 0 end;
 insert into public.conquest_battle_answers(battle_id,player_id,question_index,question_id,selected_index,is_correct,elapsed_ms,points) values(b.id,me.id,b.question_index,b.question_ids[b.question_index+1],p_selected_index,v_correct,v_elapsed,v_points);
 if me.id=b.attacker_player_id then update public.conquest_battles set attacker_score=attacker_score+v_points where id=b.id; else update public.conquest_battles set defender_score=defender_score+v_points where id=b.id; end if;
 return jsonb_build_object('accepted',true,'points',v_points);
exception when unique_violation then raise exception 'Ответ на этот вопрос уже принят.';
end; $$;

create or replace function public.advance_conquest_battle(p_battle_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare b public.conquest_battles; g public.conquest_games; r public.rooms; v_needed integer; v_answered integer; v_winner uuid; v_alive integer; v_next uuid; v_target public.conquest_map_territories;
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
 if b.battle_type='claim' then
   select count(*) into v_answered from public.conquest_battle_answers where battle_id=b.id and player_id=b.attacker_player_id and is_correct;
   if v_answered>=2 then update public.conquest_map_territories set owner_player_id=b.attacker_player_id where game_id=g.id and territory_key=b.target_territory_key; end if;
 else
   if b.attacker_score>b.defender_score then
     if exists(select 1 from public.conquest_map_territories where game_id=g.id and territory_key=b.target_territory_key and is_capital) then
       update public.conquest_game_players set is_eliminated=true,eliminated_at=now(),final_rank=(select count(*)+1 from public.conquest_game_players x where x.game_id=g.id and x.is_eliminated=true) where game_id=g.id and room_player_id=b.defender_player_id;
       update public.conquest_map_territories set owner_player_id=null,is_capital=false where game_id=g.id and owner_player_id=b.defender_player_id;
     end if;
     update public.conquest_map_territories set owner_player_id=b.attacker_player_id,is_capital=false where game_id=g.id and territory_key=b.target_territory_key;
   end if;
 end if;
 update public.conquest_battles set status='finished',finished_at=now() where id=b.id;
 select count(*) into v_alive from public.conquest_game_players where game_id=g.id and not is_eliminated;
 if v_alive<=1 then
   select room_player_id into v_winner from public.conquest_game_players where game_id=g.id and not is_eliminated limit 1;
   update public.conquest_games set status='finished',winner_player_id=v_winner,updated_at=now() where id=g.id;
 else
   select cgp.room_player_id into v_next from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id and not cgp.is_eliminated and rp.joined_at>(select joined_at from public.room_players where id=g.current_player_id) order by rp.joined_at limit 1;
   if v_next is null then select cgp.room_player_id into v_next from public.conquest_game_players cgp join public.room_players rp on rp.id=cgp.room_player_id where cgp.game_id=g.id and not cgp.is_eliminated order by rp.joined_at limit 1; end if;
   update public.conquest_games set current_player_id=v_next,turn_number=turn_number+1,updated_at=now() where id=g.id;
 end if;
 insert into public.conquest_action_log(game_id,player_id,action_type,payload) values(g.id,b.attacker_player_id,'battle_finished',jsonb_build_object('target',b.target_territory_key,'type',b.battle_type,'attacker_score',b.attacker_score,'defender_score',b.defender_score));
 return jsonb_build_object('status','finished','game_status',case when v_alive<=1 then 'finished' else 'playing' end,'winner_player_id',v_winner);
end; $$;

-- Expose only the safe RPC surface; correct answers are never returned by get_conquest_state.
revoke all on function public.init_conquest_game(uuid) from public,anon;
revoke all on function public.join_conquest_room(text,text) from public,anon;
revoke all on function public.start_conquest_game(uuid) from public,anon;
revoke all on function public.get_conquest_state(uuid) from public,anon;
revoke all on function public.start_conquest_action(uuid,text) from public,anon;
revoke all on function public.submit_conquest_answer(uuid,integer,integer) from public,anon;
revoke all on function public.advance_conquest_battle(uuid) from public,anon;
grant execute on function public.init_conquest_game(uuid) to authenticated;
grant execute on function public.join_conquest_room(text,text) to authenticated;
grant execute on function public.start_conquest_game(uuid) to authenticated;
grant execute on function public.get_conquest_state(uuid) to authenticated;
grant execute on function public.start_conquest_action(uuid,text) to authenticated;
grant execute on function public.submit_conquest_answer(uuid,integer,integer) to authenticated;
grant execute on function public.advance_conquest_battle(uuid) to authenticated;
