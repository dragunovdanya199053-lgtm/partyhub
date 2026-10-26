import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = { title: 'PartyHub — твоя компания, твои игры', description: 'Викторины, мультиплеер и стратегия «Завоеватели» для компании друзей.' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="ru"><body>{children}</body></html>; }
