# ProjectBumn — Reseller Platform

MVP platform reseller dengan ID member, referral, produk, order, omzet, komisi, saldo dan withdrawal.

## Stack
- Next.js 16.3.8
- React 19
- Supabase Auth + PostgreSQL
- TypeScript

## Setup
1. Buat project Supabase.
2. Jalankan seluruh SQL di supabase/schema.sql.
3. Salin .env.example menjadi .env.local.
4. Isi variabel Supabase dan NEXT_PUBLIC_SITE_URL.
5. Jalankan npm install.
6. Jalankan npm run dev.
7. Buka http://localhost:3000.

## Admin pertama
Setelah mendaftar, ubah role akun pertama di Supabase SQL Editor:

UPDATE public.profiles
SET role = 'admin'
WHERE email = 'email-kamu@example.com';

## Catatan
Payment gateway belum diaktifkan pada MVP.
Withdrawal masih manual di panel admin.
Xendit Payout disambungkan setelah ledger dan approval order stabil.
Jangan pernah memasukkan SUPABASE_SERVICE_ROLE_KEY ke client-side atau GitHub.