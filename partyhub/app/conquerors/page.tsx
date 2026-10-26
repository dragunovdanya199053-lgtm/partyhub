'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { ArrowLeft, Crown, Flag, LoaderCircle, Map, Swords, Users, WifiOff } from 'lucide-react';
import { getSupabase } from '@/lib/supabase';
import AuthControls from '../auth-controls';
import { CATEGORIES } from '@/lib/questions';
import './conquerors.css';

type Territory = { key: string; name: string; x: number; y: number; owner_player_id: string | null; is_capital: boolean; territory_type?: string; terrain?: string; base_defense?: number; gold_reward?: number; coastal?: boolean; special_effect?: string | null; investment_defense?: number; neutral_reward_claimed?: boolean };
type Player = { id: string; name: string; user_id: string; color: string; is_eliminated: boolean; disconnected_at?: string | null; reconnect_deadline?: string | null; surrendered_at?: string | null; territories: number; gold?: number; citadel_bonus_battles_remaining?: number; academy_battles_since_use?: number };
type Battle = { id: string; type: 'claim' | 'attack'; target: string; attacker: string; defender: string | null; index: number; total: number; attacker_score: number; defender_score: number; answered: boolean; question: { id: number; prompt: string; options: string[]; index: number; started_at: string } | null };
type GameState = { game_id: string; room_id: string; room_code: string; status: 'lobby' | 'playing' | 'finished'; is_host: boolean; self_player_id: string; current_player_id: string | null; turn_number: number; winner_player_id: string | null; citadel_rounds_remaining?: number; territories: Territory[]; players: Player[]; edges: {a:string;b:string}[]; battle: (Battle & { defender_defense_bonus?: number; attacker_citadel_bonus?: number; removed_option_index?: number | null }) | null; player_count: number };
type RoomPlayer = { id: string; display_name: string; user_id: string; is_connected: boolean };

const COLORS = ['#8b5cf6','#f97316','#06b6d4','#ef4444','#22c55e','#eab308'];

function mapPosition(t: Territory) { return { x: t.x, y: t.y }; }

function routePath(a: Territory, b: Territory) {
  const pa = mapPosition(a), pb = mapPosition(b);
  return `M ${pa.x} ${pa.y} L ${pb.x} ${pb.y}`;
}

async function ensureGuest() {
  const sb = getSupabase();
  if (!sb) throw new Error('Сначала настрой Supabase: см. .env.example и README.md.');
  const { data: { session } } = await sb.auth.getSession();
  if (!session) {
    const { error } = await sb.auth.signInAnonymously();
    if (error) throw error;
  }
  return sb;
}

export default function ConquerorsPage() {
  const [name, setName] = useState('Игрок');
  const [registeredUsername, setRegisteredUsername] = useState<string | null>(null);
  const [codeInput, setCodeInput] = useState('');
  const [roomId, setRoomId] = useState('');
  const [roomCode, setRoomCode] = useState('');
  const [state, setState] = useState<GameState | null>(null);
  const [lobbyPlayers, setLobbyPlayers] = useState<RoomPlayer[]>([]);
  const [selectedTerritory, setSelectedTerritory] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState('');
  const [startedAt, setStartedAt] = useState<number>(Date.now());
  const [secondsLeft, setSecondsLeft] = useState(20);

  const refresh = useCallback(async (id = roomId) => {
    if (!id) return;
    const client = getSupabase(); if (!client) return;
    const { data, error } = await client.rpc('get_conquest_state', { p_room_id: id });
    if (error) { setMessage(error.message); return; }
    const next = data as GameState;
    setState(next); setRoomCode(next.room_code);
    if (next.status === 'lobby') {
      const { data: players } = await client.from('room_players').select('id,display_name,user_id,is_connected').eq('room_id', id).order('joined_at');
      if (players) setLobbyPlayers(players as RoomPlayer[]);
    }
  }, [roomId]);

  useEffect(() => {
    const client = getSupabase();
    if (!client) return;
    const applyUser = (user: { is_anonymous?: boolean; user_metadata?: Record<string, unknown> } | null) => {
      const username = !user?.is_anonymous && typeof user?.user_metadata?.username === 'string'
        ? user.user_metadata.username.trim()
        : '';
      setRegisteredUsername(username || null);
      if (username) setName(username);
    };
    void client.auth.getUser().then(({ data }) => applyUser(data.user));
    const { data: listener } = client.auth.onAuthStateChange((_event, session) => applyUser(session?.user ?? null));
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!roomId) return;
    void refresh(roomId);
    const interval = window.setInterval(async () => {
      const client = getSupabase();
      if (!client) return;
      await refresh(roomId);
      const { data } = await client.rpc('get_conquest_state', { p_room_id: roomId });
      const battle = (data as GameState | null)?.battle;
      if (battle?.id) await client.rpc('advance_conquest_battle', { p_battle_id: battle.id });
    }, 1800);
    return () => window.clearInterval(interval);
  }, [roomId, refresh]);

  useEffect(() => {
    if (!state?.battle?.question?.started_at) return;
    const tick = () => {
      const elapsed = Math.floor((Date.now() - new Date(state.battle!.question!.started_at).getTime()) / 1000);
      setSecondsLeft(Math.max(0, 20 - elapsed));
    };
    tick(); const interval = window.setInterval(tick, 250); return () => window.clearInterval(interval);
  }, [state?.battle?.id, state?.battle?.index, state?.battle?.question?.started_at]);

  const run = async (fn: () => Promise<void>) => {
    setLoading(true); setMessage('');
    try { await fn(); } catch (e) { setMessage(e instanceof Error ? e.message : 'Не удалось выполнить действие.'); }
    finally { setLoading(false); }
  };

  const createGame = () => run(async () => {
    const client = await ensureGuest();
    const { data, error } = await client.rpc('create_room', { p_display_name: name.trim() || 'Игрок', p_question_count: 10, p_categories: CATEGORIES, p_timer_seconds: 20, p_lives_limit: 3 });
    if (error) throw error;
    const id = data.room_id as string;
    const { error: initError } = await client.rpc('init_conquest_game', { p_room_id: id });
    if (initError) throw initError;
    setRoomId(id); setRoomCode(data.room_code); await refresh(id);
  });

  const joinGame = () => run(async () => {
    const client = await ensureGuest();
    const { data, error } = await client.rpc('join_conquest_room', { p_room_code: codeInput.trim().toUpperCase(), p_display_name: name.trim() || 'Игрок' });
    if (error) throw error;
    const id = data.room_id as string;
    setRoomId(id); setRoomCode(data.room_code); await refresh(id);
  });

  const startGame = () => run(async () => {
    if (!roomId) return;
    const client = await ensureGuest();
    const { error } = await client.rpc('start_conquest_game', { p_room_id: roomId });
    if (error) throw error; await refresh(roomId);
  });

  const doAction = (key: string) => run(async () => {
    if (!roomId) return;
    const client = await ensureGuest();
    const { error } = await client.rpc('start_conquest_action', { p_room_id: roomId, p_target_key: key });
    if (error) throw error; setSelectedTerritory(null); await refresh(roomId);
  });

  const answer = (index: number) => run(async () => {
    const battle = state?.battle; if (!battle) return;
    const client = await ensureGuest();
    const { error } = await client.rpc('submit_conquest_answer', { p_battle_id: battle.id, p_selected_index: index, p_elapsed_ms: Date.now() - startedAt });
    if (error) throw error; await refresh(roomId);
  });

  const useAcademy = () => run(async () => {
    const battle = state?.battle; if (!battle) return;
    const client = await ensureGuest();
    const { error } = await client.rpc('use_conquest_academy', { p_battle_id: battle.id });
    if (error) throw error; await refresh(roomId);
  });

  const investDefense = (territory: Territory) => run(async () => {
    const client = await ensureGuest();
    const { error } = await client.rpc('invest_conquest_defense', { p_room_id: roomId, p_target_key: territory.key, p_gold: 1 });
    if (error) throw error; await refresh(roomId);
  });

  const self = state?.players.find(p => p.id === state.self_player_id);
  const current = state?.players.find(p => p.id === state.current_player_id);
  const battle = state?.battle;
  const selected = state?.territories.find(t => t.key === selectedTerritory);
  const neighbors = useMemo(() => {
    if (!state || !self) return new Set<string>();
    const ownedTerritories = state.territories.filter(t => t.owner_player_id === self.id);
    const owned = ownedTerritories.map(t => t.key);
    const set = new Set<string>();
    state.edges.forEach(e => { if (owned.includes(e.a)) set.add(e.b); if (owned.includes(e.b)) set.add(e.a); });
    if (ownedTerritories.some(t => t.special_effect === 'free_port')) state.territories.filter(t => t.coastal).forEach(t => set.add(t.key));
    return set;
  }, [state, self]);
  const isMyTurn = Boolean(state && self && state.current_player_id === self.id && !self.is_eliminated);

  return <main className="conq-page">
    <header className="conq-header"><Link href="/" className="conq-brand"><span className="conq-brand-mark"><Swords size={20}/></span><span>Party<span>Hub</span><small>ЗАВОЕВАТЕЛИ</small></span></Link><div className="conq-header-actions"><AuthControls/><Link href="/" className="conq-back"><ArrowLeft size={16}/> На главную</Link></div></header>
    {!state ? <section className="conq-landing"><div className="conq-eyebrow"><Map size={15}/> СТРАТЕГИЯ · ВИКТОРИНА · ЗАВОЕВАНИЕ</div><h1>Завоюй карту.<br/><span>Стань последним королём.</span></h1><p className="conq-lead">Сражайся за территории, отвечай на вопросы быстрее соперников и захватывай столицы. От 2 до 6 игроков, одна фиксированная карта из 30 территорий.</p><div className="conq-setup-card">{registeredUsername ? <div className="conq-account-name"><span>Ты вошёл как</span><strong>{registeredUsername}</strong></div> : <label>Твоё имя<input value={name} maxLength={20} onChange={e=>setName(e.target.value)} placeholder="Например, Алекс"/></label>}<button disabled={loading} onClick={createGame} className="conq-primary">{loading?<LoaderCircle className="spin" size={17}/>:<Crown size={17}/>} Создать игру</button><div className="conq-or"><span/> ИЛИ <span/></div><label>Код комнаты<input value={codeInput} maxLength={6} onChange={e=>setCodeInput(e.target.value.toUpperCase())} placeholder="ABC123"/></label><button disabled={loading||codeInput.trim().length!==6} onClick={joinGame} className="conq-secondary"><Users size={17}/> Присоединиться</button><p className="conq-note">Для сетевой игры требуется настроенный Supabase и применённые миграции 0001–0009.</p></div><div className="conq-features"><div><Swords/><strong>3 вопроса на бой</strong><span>Сумма очков решает исход атаки</span></div><div><Flag/><strong>30 территорий</strong><span>Фиксированная карта и столицы</span></div><div><WifiOff/><strong>2 минуты на возврат</strong><span>Затем отключение считается сдачей</span></div></div></section> : <section className="conq-game-wrap">
      <div className="conq-roombar"><div><span className="conq-eyebrow">КОМНАТА {roomCode}</span><h1>{state.status==='lobby'?'Собираем королевства':state.status==='finished'?'Игра окончена':'Битва за континент'}</h1></div><button className="conq-secondary small" onClick={()=>navigator.clipboard?.writeText(roomCode)}>Скопировать код</button></div>
      {state.status==='lobby' ? <div className="conq-lobby"><div className="conq-panel"><h2><Users size={19}/> Игроки <span>{lobbyPlayers.length}/6</span></h2>{lobbyPlayers.map((p,i)=><div className="conq-lobby-player" key={p.id}><i style={{background:COLORS[i%COLORS.length]}}/><span>{p.display_name}</span><small>{p.user_id===undefined?'':'Готов к игре'}</small></div>)}<p className="conq-note">Нужно от 2 до 6 игроков. Поделись кодом комнаты с друзьями.</p>{state.is_host&&<button className="conq-primary" disabled={loading||lobbyPlayers.length<2||lobbyPlayers.length>6} onClick={startGame}><Swords size={17}/> Начать завоевание</button>}</div><div className="conq-panel conq-rules"><h2>Как играть</h2><ol><li>В начале каждый получает столицу и свой цвет.</li><li>В свой ход выбери соседнюю нейтральную территорию или владение соперника.</li><li>Захват нейтральной земли требует минимум 2 правильных ответа из 3.</li><li>В атаке оба игрока отвечают на одинаковые вопросы; выше сумма — победа. Ничья в пользу защитника.</li><li>Захват столицы выбивает игрока. Последнее королевство побеждает.</li></ol></div></div> : <>
        <div className="conq-status-row"><div className="conq-turn"><Crown size={17}/>{state.status==='finished'?`Победитель: ${state.players.find(p=>p.id===state.winner_player_id)?.name||'—'}`:<>Ход: <strong style={{color:current?.color}}>{current?.name||'—'}</strong> · ход №{state.turn_number}</>}</div><div className="conq-self">Ты: <i style={{background:self?.color||'#888'}}/> {self?.name||'—'} · {self?.gold||0} золота</div>{(state.citadel_rounds_remaining||0)>0&&<div className="conq-citadel-timer">Цитадель: {state.citadel_rounds_remaining} раундов до возвращения нейтралам</div>}</div>
        <div className="conq-layout"><div className="conq-map-panel"><div className="conq-map-caption"><Map size={17}/> КАРТА КОРОЛЕВСТВ <span>30 территорий</span></div><div className="conq-map" role="group" aria-label="Карта территорий">
          <svg className="conq-landscape" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
            <defs>
              <linearGradient id="landFill" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#d8c69a"/><stop offset=".48" stopColor="#b9b07e"/><stop offset="1" stopColor="#7d9a78"/></linearGradient>
              <linearGradient id="seaFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#294d61"/><stop offset="1" stopColor="#142e43"/></linearGradient>
              <pattern id="mapGrain" width="4" height="4" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r=".18" fill="#fff" opacity=".22"/><path d="M0 3.5L4 3" stroke="#4e624d" strokeWidth=".12" opacity=".18"/></pattern>
            </defs>
            <rect width="100" height="100" fill="url(#seaFill)"/>
            <path d="M7 30 L12 20 25 13 34 17 42 10 54 14 61 8 75 13 85 18 92 15 95 28 91 36 86 47 92 56 83 67 79 82 66 91 53 86 43 93 31 85 23 88 16 76 10 67 14 55 7 45Z" fill="#d8c89b" opacity=".22" transform="translate(1.5 1.8)"/>
            <path d="M7 30 L12 20 25 13 34 17 42 10 54 14 61 8 75 13 85 18 92 15 95 28 91 36 86 47 92 56 83 67 79 82 66 91 53 86 43 93 31 85 23 88 16 76 10 67 14 55 7 45Z" fill="url(#landFill)" stroke="#e6d7ac" strokeWidth="1.1"/>
            <path d="M10 32 Q22 24 29 31 T46 29 T62 24 T82 29 M15 51 Q27 44 40 50 T62 47 T84 50 M17 70 Q31 62 44 70 T69 67 T82 70" fill="none" stroke="#f1e2b5" strokeWidth=".45" opacity=".45"/>
            <path d="M29 18 Q35 31 31 43 T40 63 Q44 73 38 83 M58 17 Q53 29 60 38 T58 55 Q64 67 72 76" fill="none" stroke="#5d9da0" strokeWidth="1.2" opacity=".75"/>
            <path d="M29 18 Q35 31 31 43 T40 63 Q44 73 38 83 M58 17 Q53 29 60 38 T58 55 Q64 67 72 76" fill="none" stroke="#b9e1d5" strokeWidth=".35" opacity=".9"/>
            <g fill="#496b4c" stroke="#304f3d" strokeWidth=".2" opacity=".9"><path d="M21 35l2-5 2 5z M24 39l2.2-5.5 2.2 5.5z M20 42l2-5 2 5z M72 31l2-5 2 5z M75 35l2.2-5.5 2.2 5.5z M70 38l2-5 2 5z M32 72l2-5 2 5z M35 76l2.2-5.5 2.2 5.5z M31 79l2-5 2 5z"/></g>
            <g fill="#f1e4c4" stroke="#8b8265" strokeWidth=".28"><path d="M44 19l2.4-5 2.4 5z M47 20l2.6-6 2.6 6z M51 21l2.4-5 2.4 5z M43 24l2.4-5 2.4 5z M47 26l2.6-6 2.6 6z M51 25l2.4-5 2.4 5z"/></g>
            <g fill="#f4e8c6" opacity=".9" fontSize="2.5" letterSpacing=".45"><text x="18" y="17">ЗАПАДНЫЕ ЗЕМЛИ</text><text x="59" y="16">СЕВЕРНЫЙ КРАЙ</text><text x="58" y="91">ЮЖНЫЕ МАРКИ</text></g>
            <rect width="100" height="100" fill="url(#mapGrain)" opacity=".6"/>
          </svg>
          <svg className="conq-edges" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">{state.edges.map((e,i)=>{const a=state.territories.find(t=>t.key===e.a),b=state.territories.find(t=>t.key===e.b);return a&&b?<g key={i}><path className="conq-route-shadow" d={routePath(a,b)}/><path className="conq-route" d={routePath(a,b)}/></g>:null})}</svg>
          {state.territories.map(t=>{const owner=state.players.find(p=>p.id===t.owner_player_id);const ownerIndex=owner?state.players.findIndex(p=>p.id===owner.id)+1:0;const actionable=isMyTurn&&neighbors.has(t.key)&&owner?.id!==self?.id&&!battle;return <button key={t.key} title={`${t.name}${owner?` — ${owner.name}`:' — Нейтральная территория'}`} aria-label={`${t.name}${owner?`, владелец ${owner.name}`:', нейтральная'}${actionable?', доступна для атаки или захвата':''}`} className={`conq-territory ${selectedTerritory===t.key?'selected':''} ${actionable?'actionable':''} ${owner?'owned':''} ${t.is_capital?'capital':''} ${t.special_effect?'special':''} ${t.terrain||'plain'}`} style={{left:`${mapPosition(t).x}%`,top:`${mapPosition(t).y}%`}} onClick={()=>setSelectedTerritory(t.key)}><span>{t.is_capital?<Crown size={15}/>:t.special_effect==='gold_mine'?'✦':t.special_effect==='free_port'?'⚓':t.special_effect==='citadel'?'♜':t.special_effect==='academy'?'✧':t.special_effect==='fortress'?'▣':t.special_effect==='pass'?'⌁':t.special_effect==='royal_bridge'?'═':t.special_effect==='ancient_forest'?'♣':t.terrain==='mountain'?'▲':t.terrain==='forest'?'♣':t.coastal?'≈':null}</span><b>{t.key.slice(1)}</b>{owner&&<small className="conq-owner-mark" aria-hidden="true">{ownerIndex}</small>}</button>})}
        </div><div className="conq-map-help">Номера показывают территории; маленькая цифра — владелец по списку королевств. Выбери доступную соседнюю территорию для захвата или атаки.</div>{selected&&<div className="conq-selected"><div><strong>{selected.name}</strong><small>{state.players.find(p=>p.id===selected.owner_player_id)?.name||'Нейтральная территория'}{selected.is_capital?' · столица':''}{selected.coastal?' · побережье':''}{(selected.base_defense||0)>0?` · защита +${selected.base_defense}`:''}{(selected.investment_defense||0)>0?` · вложенная защита +${selected.investment_defense}`:''}{(selected.gold_reward||0)>0&&!selected.neutral_reward_claimed?` · награда ${selected.gold_reward} золота`:''}{selected.special_effect==='gold_mine'?' · +10 золота за ход':selected.special_effect==='free_port'?' · морские атаки':selected.special_effect==='academy'?' · Академия мудрецов':selected.special_effect==='citadel'?' · бонус +500 на 5 боёв':''}</small></div><div className="conq-selected-actions"><button className="conq-secondary small" disabled={!isMyTurn||selected.owner_player_id!==self?.id||Boolean(battle)||state.status!=='playing'||(self?.gold||0)<1||(selected.investment_defense||0)>=500} onClick={()=>investDefense(selected)}>+10 защиты · 1 золото</button><button className="conq-primary" disabled={!isMyTurn||!neighbors.has(selected.key)||selected.owner_player_id===self?.id||Boolean(battle)||state.status!=='playing'} onClick={()=>doAction(selected.key)}>{selected.owner_player_id?'Атаковать':'Захватить'}</button></div></div>}</div>
          <aside className="conq-side"><div className="conq-panel"><h2>Королевства</h2>{state.players.map((p,index)=><div className={`conq-score-row ${p.is_eliminated?'eliminated':''}`} key={p.id}><span className="conq-player-index">{index+1}</span><i style={{background:p.color}}/><div><strong>{p.name}</strong><small>{p.is_eliminated?'Сдался / выбыл':p.id===state.current_player_id?'Ходит сейчас':`${p.territories} территорий`} · {p.gold||0} золота</small></div><b>{p.territories}</b></div>)}</div>
          {battle&&battle.question&&<div className="conq-panel conq-battle"><div className="conq-battle-title"><Swords size={18}/><span>{battle.type==='claim'?'Захват территории':'Атака территории'}<small>Вопрос {battle.index+1} из 3</small></span><b>{secondsLeft}s</b></div><h3>{battle.question.prompt}</h3>{battle.answered?<div className="conq-wait"><LoaderCircle className="spin" size={18}/> Ответ принят. Ждём соперника и следующий вопрос…</div>:<div className="conq-options">{(battle.question.options as unknown as string[]).map((option,i)=>battle.removed_option_index===i?null:<button key={i} disabled={loading||secondsLeft===0} onClick={()=>answer(i)}><span>{['A','B','C','D'][i]}</span>{option}</button>)}</div>}<div className="conq-battle-scores"><span>Защита территории +{battle.defender_defense_bonus||0} · бонус Цитадели атакующего +{battle.attacker_citadel_bonus||0}</span><strong>{battle.attacker_score} : {battle.defender_score}</strong></div>{self&&state.territories.some(t=>t.owner_player_id===self.id&&t.special_effect==='academy')&&<button className="conq-secondary small" disabled={loading||battle.answered||(self.academy_battles_since_use||0)<3||(battle.removed_option_index!==null&&battle.removed_option_index!==undefined)} onClick={useAcademy}>Академия: убрать неверный ответ ({Math.max(0,3-(self.academy_battles_since_use||0))} боёв до готовности)</button>}</div>}
          {state.status==='finished'&&<div className="conq-panel conq-winner"><Crown size={26}/><h2>Королевство победило!</h2><p>{state.players.find(p=>p.id===state.winner_player_id)?.name||'Победитель'} захватывает континент.</p>{state.is_host ? <button className="conq-primary" disabled={loading} onClick={()=>run(async()=>{const client=await ensureGuest();const {error}=await client.rpc('reset_conquest_game',{p_room_id:roomId});if(error)throw error;setSelectedTerritory(null);await refresh(roomId);setMessage('Все игроки возвращены в лобби. Можно начать новую партию.');})}>{loading?<LoaderCircle className="spin" size={17}/>:null} Новая игра</button> : <p className="conq-note">Ожидаем, когда ведущий вернёт всех игроков в лобби…</p>}</div>}
          {state.status==='playing'&&!battle&&<div className="conq-panel conq-turn-help"><h3>{isMyTurn?'Твой ход!':'Ход соперника'}</h3><p>{isMyTurn?'Выбери соседнюю территорию на карте.':'Подожди, пока текущий игрок завершит действие.'}</p></div>}
        </aside></div></>}
      {message&&<div className="conq-message" role="status">{message}</div>}
    </section>}
    {!state&&message&&<div className="conq-message conq-message-landing">{message}</div>}
    <footer className="conq-footer">PartyHub · Завоеватели <span>Фиксированная карта · 30 территорий · 2–6 игроков</span></footer>
  </main>;
}
