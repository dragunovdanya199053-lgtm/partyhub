'use client';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { ArrowLeft, ArrowRight, ArrowUpRight, Check, ChevronDown, CircleHelp, Clock3, Copy, Crown, Gamepad2, Github, Heart, Lightbulb, Link2, LockKeyhole, Menu, Play, Plus, Radio, RotateCcw, Sparkles, Trophy, Users, Wifi, X, Zap } from 'lucide-react';
import { CATEGORIES, QUESTIONS, type Category, type Question } from '@/lib/questions';
import { getSupabase } from '@/lib/supabase';

type Screen = 'home' | 'setup' | 'quiz' | 'result' | 'room';
type QuizSettings = { count: number; categories: Category[]; timer: number };
const COUNT_OPTIONS = [10, 20, 30, 50, 75, 100];
const LETTERS = ['A','B','C','D'];

export default function Home() {
  const [screen, setScreen] = useState<Screen>('home');
  const [settings, setSettings] = useState<QuizSettings>({ count: 10, categories: [...CATEGORIES], timer: 20 });
  const [questions, setQuestions] = useState<Question[]>([]);
  const [index, setIndex] = useState(0);
  const [selected, setSelected] = useState<number | null>(null);
  const [locked, setLocked] = useState(false);
  const [seconds, setSeconds] = useState(20);
  const [lives, setLives] = useState(3);
  const [score, setScore] = useState(0);
  const [correctCount, setCorrectCount] = useState(0);
  const [wrongCount, setWrongCount] = useState(0);
  const [streak, setStreak] = useState(0);
  const [bestStreak, setBestStreak] = useState(0);
  const [earnedSpeed, setEarnedSpeed] = useState(0);
  const [earnedStreak, setEarnedStreak] = useState(0);
  const [showRoom, setShowRoom] = useState(false);
  const [roomCode, setRoomCode] = useState('');
  const [roomName, setRoomName] = useState('Игрок');
  const [roomBusy, setRoomBusy] = useState(false);
  const [roomMessage, setRoomMessage] = useState('');
  const [createdRoom, setCreatedRoom] = useState<{ code: string; roomId?: string } | null>(null);
  const [copied, setCopied] = useState(false);
  const [roomPlayers, setRoomPlayers] = useState<{ id: string; display_name: string; is_connected: boolean; user_id: string }[]>([]);
  const [roomHostId, setRoomHostId] = useState<string | null>(null);
  const [roomState, setRoomState] = useState<any>(null);
  const [roomAnswerBusy, setRoomAnswerBusy] = useState(false);

  const current = questions[index];
  const hasSupabase = Boolean(getSupabase());
  const progress = questions.length ? (index / questions.length) * 100 : 0;

  const resetGame = useCallback(() => {
    setIndex(0); setSelected(null); setLocked(false); setSeconds(settings.timer); setLives(3); setScore(0); setCorrectCount(0); setWrongCount(0); setStreak(0); setBestStreak(0); setEarnedSpeed(0); setEarnedStreak(0);
  }, [settings.timer]);

  const startSolo = useCallback(() => {
    const pool = QUESTIONS.filter(q => settings.categories.includes(q.category));
    if (pool.length < settings.count) return;
    const shuffled = [...pool].sort(() => Math.random() - 0.5).slice(0, settings.count);
    setQuestions(shuffled); resetGame(); setScreen('quiz');
  }, [settings, resetGame]);

  const finishOrNext = useCallback((nextLives: number) => {
    if (index + 1 >= questions.length || nextLives <= 0) setScreen('result');
    else { setIndex(v => v + 1); setSelected(null); setLocked(false); setSeconds(settings.timer); }
  }, [index, questions.length, settings.timer]);

  const answerQuestion = useCallback((choice: number | null) => {
    if (!current || locked) return;
    setLocked(true); setSelected(choice);
    const isCorrect = choice === current.correct;
    if (isCorrect) {
      const nextStreak = streak + 1;
      const speedBonus = Math.max(0, Math.floor(100 * seconds / settings.timer));
      const chainBonus = nextStreak >= 2 ? Math.min(nextStreak, 5) * 10 : 0;
      setScore(v => v + 100 + speedBonus + chainBonus);
      setCorrectCount(v => v + 1); setStreak(nextStreak); setBestStreak(v => Math.max(v, nextStreak));
      setEarnedSpeed(v => v + speedBonus); setEarnedStreak(v => v + chainBonus);
    } else {
      setWrongCount(v => v + 1); setStreak(0); if (lives > 0) setLives(v => Math.max(0, v - 1));
    }
  }, [current, locked, streak, seconds, settings.timer, lives]);

  useEffect(() => {
    if (screen !== 'quiz' || locked || !current) return;
    if (seconds <= 0) { answerQuestion(null); return; }
    const timer = window.setTimeout(() => setSeconds(s => s - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [screen, locked, current, seconds, answerQuestion]);

  const continueQuiz = () => finishOrNext(selected === current?.correct ? lives : Math.max(0, lives));
  const toggleCategory = (category: Category) => setSettings(s => ({ ...s, categories: s.categories.includes(category) ? s.categories.filter(c => c !== category) : [...s.categories, category] }));

  useEffect(() => {
    if (screen !== 'room' || !createdRoom?.roomId) return;
    const supabase = getSupabase();
    if (!supabase) return;
    let active = true;
    const refresh = async () => {
      const { data: stateData, error: stateError } = await supabase.rpc('get_room_state', { p_room_id: createdRoom.roomId! });
      if (!active) return;
      if (!stateError && stateData) {
        setRoomState(stateData);
        setRoomPlayers((stateData.players || []).map((p: any) => ({ id: p.id, display_name: p.display_name, is_connected: p.is_connected, user_id: p.user_id })));
        setRoomHostId(stateData.host_id || null);
      } else {
        const [{ data: players }, { data: room }] = await Promise.all([
          supabase.from('room_players').select('id,display_name,is_connected,user_id').eq('room_id', createdRoom.roomId!).order('joined_at', { ascending: true }),
          supabase.from('rooms').select('host_id').eq('id', createdRoom.roomId!).maybeSingle()
        ]);
        if (!active) return;
        if (players) setRoomPlayers(players as { id: string; display_name: string; is_connected: boolean; user_id: string }[]);
        if (room?.host_id) setRoomHostId(room.host_id);
      }
    };
    void refresh();
    const poll = window.setInterval(() => { void refresh(); }, 1000);
    const channel = supabase.channel(`partyhub-room-${createdRoom.roomId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'room_players', filter: `room_id=eq.${createdRoom.roomId}` }, () => { void refresh(); })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'rooms', filter: `id=eq.${createdRoom.roomId}` }, () => { void refresh(); })
      .subscribe();
    return () => { active = false; window.clearInterval(poll); void supabase.removeChannel(channel); };
  }, [screen, createdRoom?.roomId]);

  const createRoom = async () => {
    setRoomBusy(true); setRoomMessage('');
    const supabase = getSupabase();
    if (!supabase) { setRoomMessage('Для настоящих комнат сначала подключи Supabase: смотри README.md и файл .env.example.'); setRoomBusy(false); return; }
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) { const { error: authError } = await supabase.auth.signInAnonymously(); if (authError) { setRoomMessage(`Не удалось создать гостевую сессию: ${authError.message}. Проверь Anonymous Sign-Ins в Supabase.`); setRoomBusy(false); return; } }
    const { data, error } = await supabase.rpc('create_room', { p_display_name: roomName.trim() || 'Игрок', p_question_count: settings.count, p_categories: settings.categories, p_timer_seconds: settings.timer });
    if (error) setRoomMessage(`Не удалось создать комнату: ${error.message}`);
    else {
      const result = Array.isArray(data) ? data[0] : data;
      if (result?.room_code) { setCreatedRoom({ code: result.room_code, roomId: result.room_id }); setScreen('room'); setShowRoom(false); }
      else setRoomMessage('Сервер не вернул код комнаты. Проверь миграции Supabase.');
    }
    setRoomBusy(false);
  };
  const joinRoom = async () => {
    setRoomBusy(true); setRoomMessage('');
    const supabase = getSupabase();
    if (!supabase) { setRoomMessage('Для подключения к комнате настрой Supabase по инструкции в README.md.'); setRoomBusy(false); return; }
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session) { const { error: authError } = await supabase.auth.signInAnonymously(); if (authError) { setRoomMessage(`Не удалось создать гостевую сессию: ${authError.message}. Проверь Anonymous Sign-Ins в Supabase.`); setRoomBusy(false); return; } }
    const { data, error } = await supabase.rpc('join_room', { p_room_code: roomCode.trim().toUpperCase(), p_display_name: roomName.trim() || 'Игрок' });
    if (error) setRoomMessage(`Не удалось войти: ${error.message}`);
    else { const result = Array.isArray(data) ? data[0] : data; if (result?.room_code) { setCreatedRoom({ code: result.room_code, roomId: result.room_id }); setScreen('room'); setShowRoom(false); } else setRoomMessage('Комната не найдена или закрыта.'); }
    setRoomBusy(false);
  };
  const startMultiplayerGame = async () => {
    const supabase = getSupabase();
    if (!supabase || !createdRoom?.roomId) return;
    setRoomBusy(true); setRoomMessage('');
    const { error } = await supabase.rpc('start_room', { p_room_id: createdRoom.roomId });
    if (error) setRoomMessage(error.message);
    else { const { data } = await supabase.rpc('get_room_state', { p_room_id: createdRoom.roomId }); if (data) setRoomState(data); }
    setRoomBusy(false);
  };
  const submitMultiplayerAnswer = async (choice: number) => {
    const supabase = getSupabase();
    if (!supabase || !createdRoom?.roomId || roomAnswerBusy) return;
    setRoomAnswerBusy(true); setRoomMessage('');
    const { error } = await supabase.rpc('submit_room_answer', { p_room_id: createdRoom.roomId, p_selected_index: choice });
    if (error) setRoomMessage(error.message);
    else { const { data } = await supabase.rpc('get_room_state', { p_room_id: createdRoom.roomId }); if (data) setRoomState(data); }
    setRoomAnswerBusy(false);
  };

  return <main className="app-shell">
    <div className="ambient ambient-one"/><div className="ambient ambient-two"/>
    <header className="topbar wrap">
      <button className="brand" onClick={() => setScreen('home')} aria-label="На главную"><span className="brand-mark"><Gamepad2 size={21}/></span><span>Party<span className="brand-accent">Hub</span><small>ИГРЫ ДЛЯ СВОИХ</small></span></button>
      <nav className="nav-links"><button className={screen === 'home' ? 'nav-link active' : 'nav-link'} onClick={() => setScreen('home')}>Главная</button><button className="nav-link" onClick={() => document.getElementById('games')?.scrollIntoView({ behavior: 'smooth' })}>Игры</button></nav>
      <button className="guest-pill" onClick={() => { setRoomMessage(''); setShowRoom(true); }}><span className="online-dot"/> Гость <ChevronDown size={14}/></button>
    </header>

    {screen === 'home' && <>
      <section className="hero wrap">
        <div className="hero-copy"><div className="eyebrow"><Sparkles size={14}/> ТВОЯ КОМПАНИЯ — ТВОИ ПРАВИЛА</div><h1>Вечер, который<br/>вы <span className="gradient-text">запомните.</span></h1><p className="hero-subtitle">Собирайтесь, соревнуйтесь и выясняйте, кто здесь самый умный. Всё, что нужно для отличного вечера с друзьями.</p><div className="hero-actions"><button className="button button-primary" onClick={() => setScreen('setup')}><Play size={17} fill="currentColor"/> Играть в викторину <ArrowUpRight size={16}/></button><button className="button button-secondary" onClick={() => { setRoomMessage(''); setShowRoom(true); }}><Users size={17}/> Создать комнату</button></div><div className="hero-proof"><div className="avatar-stack"><span>А</span><span>М</span><span>К</span><span>+</span></div><div><strong>Лучше вместе</strong><small>Играй с друзьями с любого устройства</small></div></div></div>
        <div className="hero-art" aria-label="Иллюстрация игровой викторины"><div className="orbit orbit-a"/><div className="orbit orbit-b"/><div className="floating-chip chip-bolt"><Zap size={20} fill="currentColor"/></div><div className="floating-chip chip-trophy"><Trophy size={21}/></div><div className="quiz-card-visual"><div className="visual-top"><span className="live-label"><i/> ВИКТОРИНА</span><span className="visual-dots">•••</span></div><div className="visual-icon"><CircleHelp size={37}/></div><div className="visual-question">Насколько хорошо<br/>ты знаешь мир?</div><div className="visual-options"><span><b>A</b> На все 100%</span><span className="selected-option"><b>B</b> Сейчас проверим <Check size={14}/></span><span><b>C</b> Есть вопросы...</span></div><div className="visual-footer"><span><Users size={13}/> 4 игрока</span><span><Clock3 size={13}/> 00:18</span></div></div><div className="score-float"><span className="score-icon"><Trophy size={15}/></span><span><small>ТВОЙ РЕЗУЛЬТАТ</small><strong>+240 <i>очков</i></strong></span><span className="score-up">↗</span></div><div className="sparkle sparkle-one">✳</div><div className="sparkle sparkle-two">✦</div></div>
      </section>
      <section className="games-section wrap" id="games"><div className="section-heading"><div><div className="eyebrow">ВЫБИРАЙ СВОЙ РЕЖИМ</div><h2>Во что сыграем?</h2></div><span className="section-count">01 <i>/</i> 04</span></div><div className="games-grid">
        <button className="game-card quiz-game" onClick={() => setScreen('setup')}><div className="game-card-top"><span className="game-icon purple-icon"><Lightbulb size={23}/></span><span className="available-tag"><i/> ДОСТУПНО</span></div><div className="game-art art-quiz"><div className="art-circle circle-one"/><div className="art-circle circle-two"/><div className="art-letter">?</div><div className="art-mini mini-a">A</div><div className="art-mini mini-b">B</div><div className="art-mini mini-c">C</div></div><div className="game-card-info"><h3>Викторина</h3><p>Проверь эрудицию и докажи, кто здесь главный мозг.</p><div className="game-meta"><span><CircleHelp size={14}/> 5 категорий</span><span><Users size={14}/> 1–12 игроков</span></div><div className="game-card-cta">Играть сейчас <ArrowRight size={17}/></div></div></button>
        <GamePlaceholder title="Было не было" description="Неожиданные признания и истории, которые сближают." icon="sparkles" tint="pink"/>
        <GamePlaceholder title="Правда или действие" description="Смелые вопросы и задания для самых своих." icon="zap" tint="blue"/>
        <GamePlaceholder title="Кто из нас?" description="Узнай, что друзья на самом деле думают друг о друге." icon="users" tint="orange"/>
      </div></section>
      <section className="features wrap"><div className="feature"><span><Users size={19}/></span><div><strong>Вместе веселее</strong><small>Играй один или зови друзей</small></div></div><div className="feature"><span><Wifi size={19}/></span><div><strong>На любом устройстве</strong><small>Телефон, планшет или компьютер</small></div></div><div className="feature"><span><Trophy size={19}/></span><div><strong>Борьба за первое место</strong><small>Очки, серии и личные рекорды</small></div></div></section>
    </>}

    {screen === 'setup' && <section className="setup-page wrap"><button className="back-link" onClick={() => setScreen('home')}><ArrowLeft size={16}/> На главную</button><div className="setup-header"><div className="eyebrow">ПОДГОТОВКА К ИГРЕ</div><h1>Настрой свою <span className="gradient-text">викторину</span></h1><p>Выбирай темы, настраивай раунд и покажи, на что способен.</p></div><div className="setup-layout"><div className="setup-main panel"><div className="panel-heading"><span className="step-number">01</span><div><h3>Выбери темы</h3><p>Можно выбрать несколько или все сразу</p></div><button className="text-button" onClick={() => setSettings(s => ({...s,categories: s.categories.length === CATEGORIES.length ? [] : [...CATEGORIES]}))}>{settings.categories.length === CATEGORIES.length ? 'Снять все' : 'Выбрать все'}</button></div><div className="category-list">{CATEGORIES.map((cat,i)=><button key={cat} className={`category-option ${settings.categories.includes(cat)?'category-selected':''}`} onClick={()=>toggleCategory(cat)}><span className={`category-symbol cat-${i}`}>{['⚛','🌍','♫','♜','∑'][i]}</span><span className="category-copy"><strong>{cat}</strong><small>{[20,20,20,20,20][i]} вопросов в базе</small></span><span className={`check-box ${settings.categories.includes(cat)?'checked':''}`}>{settings.categories.includes(cat)&&<Check size={14}/>}</span></button>)}</div><div className="panel-divider"/><div className="panel-heading"><span className="step-number">02</span><div><h3>Количество вопросов</h3><p>Чем длиннее раунд, тем жарче борьба</p></div></div><div className="count-options">{COUNT_OPTIONS.map(n=><button key={n} onClick={()=>setSettings(s=>({...s,count:n}))} className={`count-option ${settings.count===n?'count-selected':''}`} disabled={n > QUESTIONS.filter(q=>settings.categories.includes(q.category)).length}><strong>{n}</strong><small>{n===10?'Коротко':n===20?'Быстро':n===30?'Стандарт':'Марафон'}</small></button>)}</div><p className="hint-line"><CircleHelp size={14}/> В базе 100 уникальных вопросов. Для раунда на 75 или 100 вопросов выбери достаточно тем.</p><div className="panel-divider"/><div className="panel-heading"><span className="step-number">03</span><div><h3>Таймер на вопрос</h3><p>Для сетевой игры время синхронизируется сервером</p></div></div><div className="timer-options">{[10,15,20,30].map(t=><button key={t} className={`timer-option ${settings.timer===t?'timer-option-selected':''}`} onClick={()=>setSettings(s=>({...s,timer:t}))}>{t} сек.</button>)}</div></div><aside className="setup-sidebar"><div className="summary-card"><div className="summary-top"><span className="summary-icon"><Gamepad2 size={21}/></span><span className="summary-label">ТВОЯ ИГРА</span></div><h3>Викторина</h3><p>Проверь свои знания в дружеском соревновании.</p><div className="summary-stat"><span>Темы</span><strong>{settings.categories.length} из 5</strong></div><div className="summary-stat"><span>Вопросы</span><strong>{settings.count}</strong></div><div className="summary-stat"><span>Игровой режим</span><strong>Соло</strong></div><div className="summary-divider"/><div className="summary-stat"><span>Таймер на вопрос</span><strong>{settings.timer} сек.</strong></div><button className="button button-primary full-button" disabled={!settings.categories.length || QUESTIONS.filter(q=>settings.categories.includes(q.category)).length < settings.count} onClick={startSolo}><Play size={16} fill="currentColor"/> Начать игру <ArrowRight size={16}/></button><button className="button button-secondary full-button" onClick={()=>{setRoomMessage('');setShowRoom(true)}}><Users size={16}/> Играть с друзьями</button><div className="secure-note"><LockKeyhole size={13}/> Без регистрации и лишних данных</div></div></aside></div></section>}

    {screen === 'quiz' && current && <section className="quiz-page wrap"><div className="quiz-topline"><button className="back-link" onClick={()=>setScreen('home')}><X size={16}/> Выйти</button><div className="quiz-counter">ВОПРОС <strong>{index+1}</strong> <span>/ {questions.length}</span></div><div className={`timer-pill ${seconds<=5?'timer-danger':''}`}><Clock3 size={16}/><strong>00:{String(seconds).padStart(2,'0')}</strong></div></div><div className="progress-track"><div className="progress-fill" style={{width:`${progress}%`}}/></div><div className="quiz-layout"><div className="question-panel panel"><div className="question-meta"><span className="question-category">{current.category}</span><span className="difficulty">{current.difficulty}</span></div><div className="question-number">ВОПРОС {String(index+1).padStart(2,'0')}</div><h1>{current.text}</h1><p className="answer-instruction">Выбери один правильный ответ</p><div className="answers-grid">{current.answers.map((answer,i)=><button key={answer} disabled={locked} onClick={()=>answerQuestion(i)} className={`answer-option ${locked&&i===current.correct?'answer-correct':''} ${locked&&selected===i&&i!==current.correct?'answer-wrong':''}`}><span className="answer-letter">{LETTERS[i]}</span><span>{answer}</span>{locked&&i===current.correct&&<Check size={18} className="answer-status"/>}{locked&&selected===i&&i!==current.correct&&<X size={18} className="answer-status"/>}</button>)}</div>{locked&&<div className={`answer-feedback ${selected===current.correct?'feedback-correct':'feedback-wrong'}`}><div className="feedback-title">{selected===current.correct?'Верно! Отличная работа':'Не совсем так'}</div><p>{current.explanation}</p></div>}<div className="question-bottom"><span><Heart size={16} fill={lives>0?'currentColor':'none'}/> <strong>{lives}</strong> жизни</span><span><Zap size={16}/> Серия: <strong>{streak}</strong></span><span><Trophy size={16}/> <strong>{score}</strong> очков</span>{locked&&<button className="button button-primary next-button" onClick={continueQuiz}>{index+1>=questions.length||lives<=0?'Результаты':'Дальше'} <ArrowRight size={16}/></button>}</div></div><aside className="leaderboard panel"><div className="leaderboard-heading"><div><h3>Твой результат</h3><p>Соло-режим</p></div><span className="leaderboard-trophy"><Trophy size={19}/></span></div><div className="score-big">{score}<small>ОЧКОВ</small></div><div className="mini-stat-grid"><div><span>Правильно</span><strong>{correctCount}</strong></div><div><span>Ошибки</span><strong>{wrongCount}</strong></div></div><div className="life-row"><span>Оставшиеся жизни</span><span className="hearts">{[0,1,2].map(i=><Heart key={i} size={16} fill={i<lives?'currentColor':'none'}/>)}</span></div><div className="sidebar-note"><Sparkles size={15}/><p>Отвечай быстрее, чтобы получить бонусные очки!</p></div></aside></div></section>}

    {screen === 'result' && <section className="result-page wrap"><div className="result-card panel"><div className="result-confetti"><Trophy size={35}/></div><div className="eyebrow">ИГРА ЗАВЕРШЕНА</div><h1>{lives===0?'Не сдавайся!':'Отличный раунд!'}</h1><p className="result-sub">{lives===0?'Жизни закончились, но это повод попробовать ещё раз.':'Ты прошёл викторину. Вот как ты справился.'}</p><div className="final-score"><span>ТВОЙ РЕЗУЛЬТАТ</span><strong>{score}</strong><small>очков</small></div><div className="result-stats"><div><Check size={18}/><strong>{correctCount}</strong><small>Правильно</small></div><div><X size={18}/><strong>{wrongCount}</strong><small>Ошибки</small></div><div><Zap size={18}/><strong>{bestStreak}</strong><small>Лучшая серия</small></div><div><Heart size={18}/><strong>{lives}</strong><small>Жизней осталось</small></div></div><div className="bonus-breakdown"><div><span>Бонус за скорость</span><strong>+{earnedSpeed}</strong></div><div><span>Бонус за серию</span><strong>+{earnedStreak}</strong></div></div><div className="result-actions"><button className="button button-primary" onClick={startSolo}><RotateCcw size={16}/> Сыграть ещё раз</button><button className="button button-secondary" onClick={()=>setScreen('home')}>На главную</button></div></div></section>}

    {screen === 'room' && <section className="room-page wrap">
      {roomState?.status === 'playing' && roomState?.question ? <div className="multiplayer-game">
        <div className="multiplayer-top"><button className="back-link" onClick={()=>setScreen('home')}><X size={16}/> Выйти на главную</button><div className="room-code-mini">КОМНАТА <strong>{createdRoom?.code}</strong></div><div className="timer-pill"><Clock3 size={15}/><strong>{Math.max(0, roomState.question.timer_seconds - Math.floor((Date.now() - new Date(roomState.question.started_at).getTime()) / 1000))}с</strong></div></div>
        <div className="progress-track"><div className="progress-fill" style={{width:`${(roomState.question.index / roomState.question.total) * 100}%`}}/></div>
        <div className="multiplayer-layout"><div className="question-panel panel"><div className="question-meta"><span className="question-category">{roomState.question.category}</span><span className="difficulty">{roomState.question.difficulty}</span><span className="room-round">Вопрос {roomState.question.index} / {roomState.question.total}</span></div><h1 className="network-question">{roomState.question.text}</h1><p className="answer-instruction">{roomState.question.phase === 'reveal' ? 'Правильный ответ' : roomState.question.answered ? 'Ответ принят — ждём остальных игроков' : 'Выбери один правильный ответ'}</p><div className="answers-grid">{roomState.question.answers.map((answer:string,i:number)=><button key={answer} disabled={roomState.question.phase==='reveal'||roomState.question.answered||roomAnswerBusy||roomState.self?.lives===0} onClick={()=>submitMultiplayerAnswer(i)} className={`answer-option ${roomState.question.phase==='reveal'&&i===roomState.question.correct_index?'answer-correct':''} ${roomState.question.answered&&roomState.question.your_answer===i&&roomState.question.phase==='reveal'&&i!==roomState.question.correct_index?'answer-wrong':''} ${roomState.question.answered&&roomState.question.your_answer===i&&roomState.question.phase!=='reveal'?'answer-picked':''}`}><span className="answer-letter">{LETTERS[i]}</span><span>{answer}</span>{roomState.question.phase==='reveal'&&i===roomState.question.correct_index&&<Check size={18} className="answer-status"/>}</button>)}</div>{roomState.question.phase==='reveal'&&<div className="answer-feedback feedback-correct"><div className="feedback-title">Правильный ответ: {roomState.question.answers[roomState.question.correct_index]}</div><p>{roomState.question.explanation}</p></div>}{roomState.self?.lives===0&&<div className="inline-message">Ты выбыл из игры. Оставайся с компанией — результаты всё ещё обновляются.</div>}{roomMessage&&<div className="inline-message">{roomMessage}</div>}<div className="question-bottom"><span><Heart size={16} fill={roomState.self?.lives>0?'currentColor':'none'}/> <strong>{roomState.self?.lives ?? 0}</strong> жизни</span><span><Zap size={16}/> Серия: <strong>{roomState.self?.streak ?? 0}</strong></span><span><Trophy size={16}/> <strong>{roomState.self?.score ?? 0}</strong> очков</span></div></div>
          <aside className="leaderboard panel"><div className="leaderboard-heading"><div><h3>Таблица игроков</h3><p>{roomState.players?.length || 0} участников</p></div><span className="leaderboard-trophy"><Trophy size={19}/></span></div><div className="network-scoreboard">{(roomState.players||[]).map((player:any,i:number)=><div className={`network-score-row ${player.user_id===roomHostId?'network-host':''}`} key={player.id}><span className="network-rank">{i+1}</span><span className="network-player-name">{player.display_name}{player.is_host&&<small><Crown size={10}/> Ведущий</small>}{player.eliminated&&<small className="eliminated-label">Выбыл</small>}{!player.is_connected&&<small className="disconnected-label">Отключён</small>}</span><span className="network-player-score"><strong>{player.score}</strong><small>{'♥'.repeat(player.lives)}{'♡'.repeat(3-player.lives)}</small></span></div>)}</div><div className="sidebar-note"><Radio size={15}/><p>Ответы проверяются сервером. Таблица обновляется автоматически.</p></div></aside></div>
      </div> : roomState?.status === 'finished' ? <div className="room-panel panel"><div className="room-badge"><Trophy size={24}/></div><div className="eyebrow">МАТЧ ЗАВЕРШЁН</div><h1>Игра окончена</h1><p>Спасибо за игру! Итоговая таблица — ниже.</p><div className="network-scoreboard">{(roomState.players||[]).map((player:any,i:number)=><div className="network-score-row" key={player.id}><span className="network-rank">{i+1}</span><span className="network-player-name">{player.display_name}</span><span className="network-player-score"><strong>{player.score}</strong><small>очков</small></span></div>)}</div><button className="button button-secondary" onClick={()=>setScreen('home')}>На главную</button></div> : <div className="room-panel panel"><div className="room-badge"><Users size={22}/></div><div className="eyebrow">ИГРОВАЯ КОМНАТА</div><h1>Собираем <span className="gradient-text">компанию</span></h1><p>Поделись кодом с друзьями. Когда все будут готовы, ведущий сможет начать раунд.</p><div className="room-code-box"><span>КОД КОМНАТЫ</span><strong>{createdRoom?.code}</strong><button className="button button-secondary" onClick={async()=>{try{await navigator.clipboard.writeText(createdRoom?.code||'');setCopied(true);setTimeout(()=>setCopied(false),1800)}catch{setRoomMessage('Не удалось скопировать код.')}}}>{copied?<Check size={15}/>:<Copy size={15}/>} {copied?'Скопировано':'Копировать код'}</button></div><div className="room-status"><span className="online-dot"/> Комната создана · {roomPlayers.length} из 12 игроков</div><div className="room-player-list">{roomPlayers.map((player) => <div className="room-player" key={player.id}><span className="room-player-avatar">{player.display_name.slice(0,1).toUpperCase()}</span><span className="room-player-name">{player.display_name}{player.user_id === roomHostId && <small><Crown size={11}/> Ведущий</small>}</span><span className={`room-player-state ${player.is_connected?'':'player-disconnected'}`}><i/> {player.is_connected?'Подключён':'Отключён'}</span></div>)}</div><div className="room-settings-summary"><span>{roomState?.question_count || settings.count} вопросов</span><span>{(roomState?.categories || settings.categories).join(' · ')}</span><span>{roomState?.timer_seconds || settings.timer} секунд на вопрос</span></div><div className="room-actions"><button className="button button-secondary" onClick={()=>setScreen('home')}>На главную</button>{roomState?.is_host&&<button className="button button-primary" disabled={roomBusy||roomPlayers.length<1} onClick={startMultiplayerGame}>{roomBusy?<span className="spinner"/>:<Play size={16} fill="currentColor"/>} Начать игру <ArrowRight size={16}/></button>}</div>{roomMessage&&<div className="inline-message">{roomMessage}</div>}</div>}
    </section>}

    <footer className="footer wrap"><div className="footer-brand"><span className="brand-mark small-mark"><Gamepad2 size={16}/></span> Party<span className="brand-accent">Hub</span></div><span>Сделано для хороших компаний <span className="footer-heart">♥</span></span><span className="footer-version">MVP · 0.1.0</span></footer>

    {showRoom && <div className="modal-backdrop" onClick={()=>setShowRoom(false)}><div className="room-modal panel" onClick={e=>e.stopPropagation()}><button className="modal-close" onClick={()=>setShowRoom(false)}><X size={18}/></button><div className="modal-icon"><Users size={23}/></div><div className="eyebrow">ИГРАЕМ ВМЕСТЕ</div><h2>Комната для друзей</h2><p className="modal-sub">Создай комнату или подключись к уже существующей.</p><label className="field-label">ТВОЁ ИМЯ</label><input className="text-input" maxLength={20} value={roomName} onChange={e=>setRoomName(e.target.value)} placeholder="Например, Алекс"/><button className="button button-primary full-button" disabled={roomBusy||!roomName.trim()} onClick={createRoom}>{roomBusy?<span className="spinner"/>:<Plus size={17}/>} Создать новую комнату</button><div className="or-divider"><span>или войти по коду</span></div><label className="field-label">КОД КОМНАТЫ</label><div className="join-row"><input className="text-input code-input" maxLength={6} value={roomCode} onChange={e=>setRoomCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g,''))} placeholder="K7P4QX"/><button className="button button-secondary" disabled={roomBusy||roomCode.length!==6||!roomName.trim()} onClick={joinRoom}>{roomBusy?'...':'Войти'}</button></div>{!hasSupabase&&<div className="setup-notice"><LockKeyhole size={15}/><span>Для сетевых комнат нужно один раз подключить Supabase. Смотри инструкцию в README.</span></div>}{roomMessage&&<div className="inline-message">{roomMessage}</div>}</div></div>}
  </main>;
}

function GamePlaceholder({title,description,icon,tint}:{title:string;description:string;icon:string;tint:string}) {
  return <div className="game-card placeholder-card"><div className="game-card-top"><span className={`game-icon ${tint}-icon`}>{icon==='sparkles'?<Sparkles size={22}/>:icon==='zap'?<Zap size={22}/>:<Users size={22}/>}</span><span className="soon-tag">СКОРО</span></div><div className={`game-art art-${tint}`}><div className="placeholder-symbol">{icon==='sparkles'?'✦':icon==='zap'?'ϟ':'?'}</div><div className="placeholder-orbit orbit-left"/><div className="placeholder-orbit orbit-right"/></div><div className="game-card-info"><h3>{title}</h3><p>{description}</p><div className="game-meta"><span><LockKeyhole size={14}/> В разработке</span></div><div className="game-card-cta muted-cta">Скоро на PartyHub <LockKeyhole size={14}/></div></div></div>;
}
