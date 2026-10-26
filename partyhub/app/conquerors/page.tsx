'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import Link from 'next/link';
import { ArrowLeft, Crown, Flag, LoaderCircle, Map, Swords, Users, WifiOff } from 'lucide-react';
import { getSupabase } from '@/lib/supabase';
import AuthControls from '../auth-controls';
import { CATEGORIES } from '@/lib/questions';
import './conquerors.css';

type Territory = { key: string; name: string; x: number; y: number; owner_player_id: string | null; is_capital: boolean };
type Player = { id: string; name: string; user_id: string; color: string; is_eliminated: boolean; disconnected_at?: string | null; reconnect_deadline?: string | null; surrendered_at?: string | null; territories: number };
type Battle = { id: string; type: 'claim' | 'attack'; target: string; attacker: string; defender: string | null; index: number; total: number; attacker_score: number; defender_score: number; answered: boolean; question: { id: number; prompt: string; options: string[]; index: number; started_at: string } | null };
type GameState = { game_id: string; room_id: string; room_code: string; status: 'lobby' | 'playing' | 'finished'; is_host: boolean; self_player_id: string; current_player_id: string | null; turn_number: number; winner_player_id: string | null; territories: Territory[]; players: Player[]; edges: {a:string;b:string}[]; battle: Battle | null; player_count: number };
type RoomPlayer = { id: string; display_name: string; user_id: string; is_connected: boolean };

const COLORS = ['#8b5cf6','#f97316','#06b6d4','#ef4444','#22c55e','#eab308'];

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

  const self = state?.players.find(p => p.id === state.self_player_id);
  const current = state?.players.find(p => p.id === state.current_player_id);
  const battle = state?.battle;
  const selected = state?.territories.find(t => t.key === selectedTerritory);
  const neighbors = useMemo(() => {
    if (!state || !self) return new Set<string>();
    const owned = state.territories.filter(t => t.owner_player_id === self.id).map(t => t.key);
    const set = new Set<string>();
    state.edges.forEach(e => { if (owned.includes(e.a)) set.add(e.b); if (owned.includes(e.b)) set.add(e.a); });
    return set;
  }, [state, self]);
  const isMyTurn = Boolean(state && self && state.current_player_id === self.id && !self.is_eliminated);

  return <main className="conq-page">
    <header className="conq-header"><Link href="/" className="conq-brand"><span className="conq-brand-mark"><Swords size={20}/></span><span>Party<span>Hub</span><small>ЗАВОЕВАТЕЛИ</small></span></Link><div className="conq-header-actions"><AuthControls/><Link href="/" className="conq-back"><ArrowLeft size={16}/> На главную</Link></div></header>
    {!state ? <section className="conq-landing"><div className="conq-eyebrow"><Map size={15}/> СТРАТЕГИЯ · ВИКТОРИНА · ЗАВОЕВАНИЕ</div><h1>Завоюй карту.<br/><span>Стань последним королём.</span></h1><p className="conq-lead">Сражайся за территории, отвечай на вопросы быстрее соперников и захватывай столицы. От 2 до 6 игроков, одна фиксированная карта из 30 территорий.</p><div className="conq-setup-card"><label>Твоё имя<input value={name} maxLength={20} onChange={e=>setName(e.target.value)} placeholder="Например, Алекс"/></label><button disabled={loading} onClick={createGame} className="conq-primary">{loading?<LoaderCircle className="spin" size={17}/>:<Crown size={17}/>} Создать игру</button><div className="conq-or"><span/> ИЛИ <span/></div><label>Код комнаты<input value={codeInput} maxLength={6} onChange={e=>setCodeInput(e.target.value.toUpperCase())} placeholder="ABC123"/></label><button disabled={loading||codeInput.trim().length!==6} onClick={joinGame} className="conq-secondary"><Users size={17}/> Присоединиться</button><p className="conq-note">Для сетевой игры требуется настроенный Supabase и применённые миграции 0001–0007.</p></div><div className="conq-features"><div><Swords/><strong>3 вопроса на бой</strong><span>Сумма очков решает исход атаки</span></div><div><Flag/><strong>30 территорий</strong><span>Фиксированная карта и столицы</span></div><div><WifiOff/><strong>2 минуты на возврат</strong><span>Затем отключение считается сдачей</span></div></div></section> : <section className="conq-game-wrap">
      <div className="conq-roombar"><div><span className="conq-eyebrow">КОМНАТА {roomCode}</span><h1>{state.status==='lobby'?'Собираем королевства':state.status==='finished'?'Игра окончена':'Битва за континент'}</h1></div><button className="conq-secondary small" onClick={()=>navigator.clipboard?.writeText(roomCode)}>Скопировать код</button></div>
      {state.status==='lobby' ? <div className="conq-lobby"><div className="conq-panel"><h2><Users size={19}/> Игроки <span>{lobbyPlayers.length}/6</span></h2>{lobbyPlayers.map((p,i)=><div className="conq-lobby-player" key={p.id}><i style={{background:COLORS[i%COLORS.length]}}/><span>{p.display_name}</span><small>{p.user_id===undefined?'':'Готов к игре'}</small></div>)}<p className="conq-note">Нужно от 2 до 6 игроков. Поделись кодом комнаты с друзьями.</p>{state.is_host&&<button className="conq-primary" disabled={loading||lobbyPlayers.length<2||lobbyPlayers.length>6} onClick={startGame}><Swords size={17}/> Начать завоевание</button>}</div><div className="conq-panel conq-rules"><h2>Как играть</h2><ol><li>В начале каждый получает столицу и свой цвет.</li><li>В свой ход выбери соседнюю нейтральную территорию или владение соперника.</li><li>Захват нейтральной земли требует минимум 2 правильных ответа из 3.</li><li>В атаке оба игрока отвечают на одинаковые вопросы; выше сумма — победа. Ничья в пользу защитника.</li><li>Захват столицы выбивает игрока. Последнее королевство побеждает.</li></ol></div></div> : <>
        <div className="conq-status-row"><div className="conq-turn"><Crown size={17}/>{state.status==='finished'?`Победитель: ${state.players.find(p=>p.id===state.winner_player_id)?.name||'—'}`:<>Ход: <strong style={{color:current?.color}}>{current?.name||'—'}</strong> · раунд {state.turn_number}</>}</div><div className="conq-self">Ты: <i style={{background:self?.color||'#888'}}/> {self?.name||'—'}</div></div>
        <div className="conq-layout"><div className="conq-map-panel"><div className="conq-map-caption"><Map size={17}/> КАРТА КОРОЛЕВСТВ <span>30 территорий</span></div><div className="conq-map" role="group" aria-label="Карта территорий">
          <svg className="conq-edges" viewBox="0 0 100 100" preserveAspectRatio="none">{state.edges.map((e,i)=>{const a=state.territories.find(t=>t.key===e.a),b=state.territories.find(t=>t.key===e.b);return a&&b?<line key={i} x1={a.x} y1={a.y} x2={b.x} y2={b.y}/>:null})}</svg>
          {state.territories.map(t=>{const owner=state.players.find(p=>p.id===t.owner_player_id);const actionable=isMyTurn&&neighbors.has(t.key)&&owner?.id!==self?.id&&!battle;return <button key={t.key} title={`${t.name}${owner?` — ${owner.name}`:' — Нейтральная территория'}`} className={`conq-territory ${selectedTerritory===t.key?'selected':''} ${actionable?'actionable':''} ${t.is_capital?'capital':''}`} style={{left:`${t.x}%`,top:`${t.y}%`,borderColor:owner?.color||'#526079',background:owner?`${owner.color}cc`:'#273449'}} onClick={()=>setSelectedTerritory(t.key)}><span>{t.is_capital?<Crown size={12}/>:null}</span><b>{t.key.slice(1)}</b></button>})}
        </div><div className="conq-map-help">Выбирай подсвеченные соседние территории, чтобы начать захват или атаку.</div>{selected&&<div className="conq-selected"><div><strong>{selected.name}</strong><small>{state.players.find(p=>p.id===selected.owner_player_id)?.name||'Нейтральная территория'}{selected.is_capital?' · столица':''}</small></div><button className="conq-primary" disabled={!isMyTurn||!neighbors.has(selected.key)||selected.owner_player_id===self?.id||Boolean(battle)||state.status!=='playing'} onClick={()=>doAction(selected.key)}>{selected.owner_player_id?'Атаковать':'Захватить'}</button></div>}</div>
          <aside className="conq-side"><div className="conq-panel"><h2>Королевства</h2>{state.players.map(p=><div className={`conq-score-row ${p.is_eliminated?'eliminated':''}`} key={p.id}><i style={{background:p.color}}/><div><strong>{p.name}</strong><small>{p.is_eliminated?'Сдался / выбыл':p.id===state.current_player_id?'Ходит сейчас':`${p.territories} территорий`}</small></div><b>{p.territories}</b></div>)}</div>
          {battle&&battle.question&&<div className="conq-panel conq-battle"><div className="conq-battle-title"><Swords size={18}/><span>{battle.type==='claim'?'Захват территории':'Атака территории'}<small>Вопрос {battle.index+1} из 3</small></span><b>{secondsLeft}s</b></div><h3>{battle.question.prompt}</h3>{battle.answered?<div className="conq-wait"><LoaderCircle className="spin" size={18}/> Ответ принят. Ждём соперника и следующий вопрос…</div>:<div className="conq-options">{(battle.question.options as unknown as string[]).map((option,i)=><button key={i} disabled={loading||secondsLeft===0} onClick={()=>answer(i)}><span>{['A','B','C','D'][i]}</span>{option}</button>)}</div>}<div className="conq-battle-scores"><span>Тысячи очков за правильный ответ + бонус скорости</span><strong>{battle.attacker_score} : {battle.defender_score}</strong></div></div>}
          {state.status==='finished'&&<div className="conq-panel conq-winner"><Crown size={26}/><h2>Королевство победило!</h2><p>{state.players.find(p=>p.id===state.winner_player_id)?.name||'Победитель'} захватывает континент.</p><Link href="/conquerors" className="conq-primary">Новая игра</Link></div>}
          {state.status==='playing'&&!battle&&<div className="conq-panel conq-turn-help"><h3>{isMyTurn?'Твой ход!':'Ход соперника'}</h3><p>{isMyTurn?'Выбери соседнюю территорию на карте.':'Подожди, пока текущий игрок завершит действие.'}</p></div>}
        </aside></div></>}
      {message&&<div className="conq-message" role="status">{message}</div>}
    </section>}
    {!state&&message&&<div className="conq-message conq-message-landing">{message}</div>}
    <footer className="conq-footer">PartyHub · Завоеватели <span>Фиксированная карта · 30 территорий · 2–6 игроков</span></footer>
  </main>;
}
