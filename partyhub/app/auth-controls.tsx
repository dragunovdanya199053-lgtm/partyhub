'use client';

import { useEffect, useState, type FormEvent } from 'react';
import { LogIn, LogOut, UserRound, X } from 'lucide-react';
import type { User } from '@supabase/supabase-js';
import { getSupabase } from '@/lib/supabase';

function loginEmail(username: string) {
  const bytes = new TextEncoder().encode(username.trim().toLowerCase());
  const binary = Array.from(bytes, byte => String.fromCharCode(byte)).join('');
  const encoded = btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
  return `u_${encoded}@users.partyhub.invalid`;
}

export default function AuthControls() {
  const [user, setUser] = useState<User | null>(null);
  const [open, setOpen] = useState(false);
  const [mode, setMode] = useState<'login' | 'register'>('login');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');

  useEffect(() => {
    const sb = getSupabase();
    if (!sb) return;
    void sb.auth.getUser().then(({ data }) => setUser(data.user));
    const { data: listener } = sb.auth.onAuthStateChange((_event, session) => setUser(session?.user ?? null));
    return () => listener.subscription.unsubscribe();
  }, []);

  const accountName = (user?.user_metadata?.username as string | undefined) || (user?.is_anonymous ? 'Гость' : user?.email?.split('@')[0]) || 'Аккаунт';

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault(); setMessage('');
    const sb = getSupabase();
    if (!sb) { setMessage('Сначала подключи Supabase в .env.local.'); return; }
    const normalized = username.trim();
    if (!/^[a-zA-Zа-яА-ЯёЁ0-9_-]{3,20}$/.test(normalized)) { setMessage('Никнейм: 3–20 символов, буквы (латиница или кириллица), цифры, _ или -.'); return; }
    if (password.length < 8) { setMessage('Пароль должен содержать минимум 8 символов.'); return; }
    setBusy(true);
    try {
      if (mode === 'register') {
        const { data: current } = await sb.auth.getUser();
        // Upgrade an existing guest identity in place so current multiplayer rooms remain attached to this player.
        const result = current.user?.is_anonymous
          ? await sb.auth.updateUser({ email: loginEmail(normalized), password, data: { username: normalized } })
          : await sb.auth.signUp({ email: loginEmail(normalized), password, options: { data: { username: normalized } } });
        if (result.error) throw result.error;
        const { data: sessionData } = await sb.auth.getSession();
        if (!sessionData.session) throw new Error('Supabase ожидает подтверждение email. Отключи Confirm email в Authentication → Providers → Email.');
        setUser(result.data.user); setOpen(false); setPassword(''); setMessage('');
      } else {
        const { data, error } = await sb.auth.signInWithPassword({ email: loginEmail(normalized), password });
        if (error) throw new Error('Неверный никнейм или пароль.');
        setUser(data.user); setOpen(false); setPassword(''); setMessage('');
      }
    } catch (e) { setMessage(e instanceof Error ? e.message : 'Не удалось выполнить вход.'); }
    finally { setBusy(false); }
  };

  const logout = async () => {
    const sb = getSupabase(); if (!sb) return;
    await sb.auth.signOut(); setUser(null); setMessage('');
  };

  return <>
    {user && !user.is_anonymous ? <button className="auth-account-button" onClick={logout} title="Выйти из аккаунта"><UserRound size={15}/><span>{accountName}</span><LogOut size={14}/></button> : <button className="auth-open-button" onClick={() => { setOpen(true); setMessage(''); }}><LogIn size={15}/><span>Войти</span></button>}
    {open && <div className="auth-overlay" onClick={() => setOpen(false)}><section className="auth-dialog" onClick={e => e.stopPropagation()} role="dialog" aria-modal="true" aria-label="Вход и регистрация">
      <button className="auth-close" onClick={() => setOpen(false)} aria-label="Закрыть"><X size={18}/></button>
      <div className="auth-symbol"><UserRound size={22}/></div><h2>{mode === 'register' ? 'Создать аккаунт' : 'С возвращением!'}</h2><p>Никнейм и пароль — без email и подтверждений.</p>
      <div className="auth-tabs"><button className={mode === 'login' ? 'selected' : ''} onClick={() => { setMode('login'); setMessage(''); }}>Вход</button><button className={mode === 'register' ? 'selected' : ''} onClick={() => { setMode('register'); setMessage(''); }}>Регистрация</button></div>
      <form onSubmit={submit} className="auth-form"><label>Никнейм<input autoComplete="username" value={username} onChange={e => setUsername(e.target.value)} minLength={3} maxLength={20} required placeholder="Например, Alex_7"/></label><label>Пароль<input autoComplete={mode === 'register' ? 'new-password' : 'current-password'} type="password" value={password} onChange={e => setPassword(e.target.value)} minLength={8} required placeholder="Минимум 8 символов"/></label><button className="auth-submit" type="submit" disabled={busy}>{busy ? 'Подождите…' : mode === 'register' ? 'Зарегистрироваться' : 'Войти'}</button></form>
      {message && <div className="auth-message" role="status">{message}</div>}
      <small className="auth-footnote">Пароль хранится и проверяется Supabase Auth, а не в открытом виде на сайте.</small>
    </section></div>}
  </>;
}
