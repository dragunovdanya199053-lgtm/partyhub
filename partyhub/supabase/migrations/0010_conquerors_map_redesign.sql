-- PartyHub «Завоеватели»: redesign map coordinates and routes while keeping the illustrated SVG artwork unchanged.
-- Apply after migrations 0001-0009. Existing and future maps use the same territory layout.
begin;

with positions(territory_key, position_x, position_y) as (values
 ('t01',13,48),
 ('t02',24,43),
 ('t03',38,42),
 ('t04',19,58),
 ('t05',17,68),
 ('t06',38,18),
 ('t07',46,25),
 ('t08',49,32),
 ('t09',62,20),
 ('t10',80,31),
 ('t11',72,17),
 ('t12',42,48),
 ('t13',53,46),
 ('t14',47,56),
 ('t15',35,59),
 ('t16',87,43),
 ('t17',79,56),
 ('t18',65,47),
 ('t19',59,58),
 ('t20',66,69),
 ('t21',76,79),
 ('t22',62,77),
 ('t23',83,68),
 ('t24',75,61),
 ('t25',31,71),
 ('t26',29,82),
 ('t27',43,80),
 ('t28',49,68),
 ('t29',56,85),
 ('t30',31,39)
)
update public.conquest_map_territories t
set position_x=p.position_x, position_y=p.position_y
from positions p
where t.territory_key=p.territory_key;

delete from public.conquest_map_edges;
insert into public.conquest_map_edges(game_id, territory_a, territory_b)
select g.id, e.territory_a, e.territory_b
from public.conquest_games g
cross join (values
 ('t01','t02'),
 ('t01','t04'),
 ('t02','t03'),
 ('t02','t04'),
 ('t02','t30'),
 ('t03','t12'),
 ('t03','t13'),
 ('t03','t30'),
 ('t04','t05'),
 ('t04','t15'),
 ('t05','t25'),
 ('t06','t07'),
 ('t06','t08'),
 ('t07','t08'),
 ('t07','t09'),
 ('t08','t13'),
 ('t09','t11'),
 ('t10','t11'),
 ('t10','t16'),
 ('t12','t13'),
 ('t12','t14'),
 ('t12','t15'),
 ('t13','t14'),
 ('t13','t18'),
 ('t13','t19'),
 ('t14','t15'),
 ('t14','t19'),
 ('t14','t28'),
 ('t15','t25'),
 ('t16','t17'),
 ('t17','t23'),
 ('t17','t24'),
 ('t18','t19'),
 ('t19','t20'),
 ('t19','t28'),
 ('t20','t21'),
 ('t20','t22'),
 ('t20','t24'),
 ('t21','t22'),
 ('t21','t23'),
 ('t22','t28'),
 ('t22','t29'),
 ('t23','t24'),
 ('t25','t26'),
 ('t25','t27'),
 ('t25','t28'),
 ('t26','t27'),
 ('t27','t28'),
 ('t27','t29')
) as e(territory_a,territory_b);

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
 (v_game.id,'t01','Западная столица',13,48,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t02','Западные низины',24,43,'ordinary','plain',0,0,false,null),
 (v_game.id,'t03','Перевал Чёрного хребта',38,42,'special','mountain',100,0,false,'pass'),
 (v_game.id,'t04','Сосновые окраины',19,58,'ordinary','forest',100,0,false,null),
 (v_game.id,'t05','Западное побережье',17,68,'ordinary','coast',0,0,true,null),
 (v_game.id,'t06','Северная столица',38,18,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t07','Северные равнины',46,25,'ordinary','plain',0,0,false,null),
 (v_game.id,'t08','Крепость Железная Стража',49,32,'special','mountain',500,0,false,'fortress'),
 (v_game.id,'t09','Сосновые холмы',62,20,'ordinary','forest',100,0,false,null),
 (v_game.id,'t10','Северный мыс',80,31,'ordinary','coast',0,0,true,null),
 (v_game.id,'t11','Восточная столица',72,17,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t12','Торговая долина',42,48,'ordinary','plain',0,0,false,null),
 (v_game.id,'t13','Золотые копи',53,46,'special','mountain',100,0,false,'gold_mine'),
 (v_game.id,'t14','Пепельные окраины',47,56,'neutral','plain',0,20,false,'neutral_reward'),
 (v_game.id,'t15','Забытые башни',35,59,'neutral','mountain',100,40,false,'neutral_reward'),
 (v_game.id,'t16','Столица Восточного побережья',87,43,'capital','coast',0,0,true,'capital'),
 (v_game.id,'t17','Прибрежные поля',79,56,'ordinary','coast',0,0,true,null),
 (v_game.id,'t18','Академия мудрецов',65,47,'special','forest',100,0,false,'academy'),
 (v_game.id,'t19','Каменная граница',59,58,'neutral','mountain',100,60,false,'neutral_reward'),
 (v_game.id,'t20','Цитадель Пепельной Короны',66,69,'neutral','mountain',100,0,false,'citadel'),
 (v_game.id,'t21','Юго-восточная столица',76,79,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t22','Южный перекрёсток',62,77,'ordinary','plain',0,0,false,null),
 (v_game.id,'t23','Свободный порт',83,68,'special','coast',0,0,true,'free_port'),
 (v_game.id,'t24','Долина стражей',75,61,'neutral','forest',100,100,false,'neutral_reward'),
 (v_game.id,'t25','Южные горы',31,71,'ordinary','mountain',100,0,false,null),
 (v_game.id,'t26','Юго-западная столица',29,82,'capital','plain',0,0,false,'capital'),
 (v_game.id,'t27','Западные пастбища',43,80,'ordinary','plain',0,0,false,null),
 (v_game.id,'t28','Древний лес',49,68,'special','forest',250,0,false,'ancient_forest'),
 (v_game.id,'t29','Южный мыс',56,85,'ordinary','coast',0,0,true,null),
 (v_game.id,'t30','Королевский мост',31,39,'special','plain',250,0,false,'royal_bridge');
 insert into public.conquest_map_edges(game_id,territory_a,territory_b) values
 (v_game.id,'t01','t02'),
 (v_game.id,'t01','t04'),
 (v_game.id,'t02','t03'),
 (v_game.id,'t02','t04'),
 (v_game.id,'t02','t30'),
 (v_game.id,'t03','t12'),
 (v_game.id,'t03','t13'),
 (v_game.id,'t03','t30'),
 (v_game.id,'t04','t05'),
 (v_game.id,'t04','t15'),
 (v_game.id,'t05','t25'),
 (v_game.id,'t06','t07'),
 (v_game.id,'t06','t08'),
 (v_game.id,'t07','t08'),
 (v_game.id,'t07','t09'),
 (v_game.id,'t08','t13'),
 (v_game.id,'t09','t11'),
 (v_game.id,'t10','t11'),
 (v_game.id,'t10','t16'),
 (v_game.id,'t12','t13'),
 (v_game.id,'t12','t14'),
 (v_game.id,'t12','t15'),
 (v_game.id,'t13','t14'),
 (v_game.id,'t13','t18'),
 (v_game.id,'t13','t19'),
 (v_game.id,'t14','t15'),
 (v_game.id,'t14','t19'),
 (v_game.id,'t14','t28'),
 (v_game.id,'t15','t25'),
 (v_game.id,'t16','t17'),
 (v_game.id,'t17','t23'),
 (v_game.id,'t17','t24'),
 (v_game.id,'t18','t19'),
 (v_game.id,'t19','t20'),
 (v_game.id,'t19','t28'),
 (v_game.id,'t20','t21'),
 (v_game.id,'t20','t22'),
 (v_game.id,'t20','t24'),
 (v_game.id,'t21','t22'),
 (v_game.id,'t21','t23'),
 (v_game.id,'t22','t28'),
 (v_game.id,'t22','t29'),
 (v_game.id,'t23','t24'),
 (v_game.id,'t25','t26'),
 (v_game.id,'t25','t27'),
 (v_game.id,'t25','t28'),
 (v_game.id,'t26','t27'),
 (v_game.id,'t27','t28'),
 (v_game.id,'t27','t29');
 return jsonb_build_object('game_id',v_game.id,'room_id',p_room_id,'status',v_game.status,'territories',30);
end; $$;

commit;
