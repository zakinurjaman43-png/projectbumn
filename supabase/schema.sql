create extension if not exists pgcrypto;
create sequence if not exists public.member_code_seq start with 100001 increment by 1;

create table if not exists public.profiles(
 id uuid primary key references auth.users(id) on delete cascade,
 member_code text not null unique default ('M'||nextval('public.member_code_seq')),
 name text not null,email text not null unique,phone text,
 role text not null default 'member' check(role in('member','admin')),
 status text not null default 'active' check(status in('active','suspended')),
 sponsor_id uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
create table if not exists public.products(
 id uuid primary key default gen_random_uuid(),name text not null,sku text not null unique,description text,
 reseller_price numeric(14,2) not null check(reseller_price>=0),selling_price numeric(14,2) not null check(selling_price>=0),
 stock integer not null default 0 check(stock>=0),active boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.orders(
 id uuid primary key default gen_random_uuid(),order_no text not null unique,buyer_id uuid not null references public.profiles(id),
 total_amount numeric(14,2) not null check(total_amount>=0),
 status text not null default 'pending' check(status in('pending','paid','processing','completed','cancelled','refunded')),
 created_at timestamptz not null default now(),completed_at timestamptz
);
create table if not exists public.order_items(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id) on delete cascade,product_id uuid not null references public.products(id),
 product_name text not null,qty integer not null check(qty>0),unit_price numeric(14,2) not null check(unit_price>=0),line_total numeric(14,2) not null check(line_total>=0)
);
create table if not exists public.wallets(member_id uuid primary key references public.profiles(id) on delete cascade,available numeric(14,2) not null default 0 check(available>=0),pending_withdrawal numeric(14,2) not null default 0 check(pending_withdrawal>=0),updated_at timestamptz not null default now());
create table if not exists public.wallet_transactions(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.profiles(id) on delete cascade,
 type text not null check(type in('commission_credit','withdrawal_hold','withdrawal_release','withdrawal_debit','manual_credit','manual_debit')),
 amount numeric(14,2) not null check(amount>0),reference_type text,reference_id uuid,description text not null,created_at timestamptz not null default now()
);
create table if not exists public.commissions(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id) on delete cascade,receiver_id uuid not null references public.profiles(id),source_member_id uuid not null references public.profiles(id),
 rate numeric(6,3) not null check(rate>=0 and rate<=100),amount numeric(14,2) not null check(amount>=0),status text not null default 'approved' check(status in('pending','approved','reversed')),
 created_at timestamptz not null default now(),unique(order_id,receiver_id)
);
create table if not exists public.withdrawals(
 id uuid primary key default gen_random_uuid(),withdrawal_no text not null unique,member_id uuid not null references public.profiles(id),
 amount numeric(14,2) not null check(amount>0),bank_name text not null,account_number text not null,account_name text not null,
 status text not null default 'pending' check(status in('pending','processing','paid','rejected','failed')),note text,created_at timestamptz not null default now(),processed_at timestamptz
);
create table if not exists public.settings(key text primary key,value_numeric numeric(14,4),value_text text,updated_at timestamptz not null default now());

create index if not exists idx_profiles_sponsor on public.profiles(sponsor_id);
create index if not exists idx_orders_buyer on public.orders(buyer_id);
create index if not exists idx_orders_status on public.orders(status);
create index if not exists idx_commissions_receiver on public.commissions(receiver_id);
create index if not exists idx_wallet_transactions_member on public.wallet_transactions(member_id);
create index if not exists idx_withdrawals_member on public.withdrawals(member_id);
create index if not exists idx_withdrawals_status on public.withdrawals(status);

insert into public.settings(key,value_numeric) values('referral_commission_rate',5) on conflict(key) do nothing;
insert into public.settings(key,value_numeric) values('minimum_withdrawal',50000) on conflict(key) do nothing;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare referral_code text; sponsor uuid;
begin
 referral_code:=nullif(trim(new.raw_user_meta_data->>'referral_code'),'');
 if referral_code is not null then select id into sponsor from public.profiles where member_code=upper(referral_code) limit 1; end if;
 insert into public.profiles(id,name,email,phone,sponsor_id)
 values(new.id,coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'),''),split_part(new.email,'@',1)),new.email,nullif(trim(new.raw_user_meta_data->>'phone'),''),sponsor);
 insert into public.wallets(member_id) values(new.id) on conflict(member_id) do nothing;
 return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.make_withdrawal_no() returns text language plpgsql as $$
begin return 'WD-'||to_char(now(),'YYYYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6); end;
$$;

create or replace function public.approve_order(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order orders%rowtype;v_buyer profiles%rowtype;v_rate numeric(6,3);v_commission numeric(14,2):=0;item record;new_stock integer;inserted_commission commissions.id%type;
begin
 select * into v_order from public.orders where id=p_order_id for update;
 if not found then raise exception 'Order tidak ditemukan'; end if;
 if v_order.status in('completed','cancelled','refunded') then raise exception 'Order sudah diproses'; end if;
 select * into v_buyer from public.profiles where id=v_order.buyer_id;
 if not found then raise exception 'Member pembeli tidak ditemukan'; end if;
 for item in select product_id,sum(qty)::integer qty from public.order_items where order_id=p_order_id group by product_id loop
   update public.products set stock=stock-item.qty,updated_at=now() where id=item.product_id and stock>=item.qty returning stock into new_stock;
   if not found then raise exception 'Stok produk tidak cukup'; end if;
 end loop;
 update public.orders set status='completed',completed_at=now() where id=p_order_id;
 select coalesce(value_numeric,5) into v_rate from public.settings where key='referral_commission_rate';
 if v_buyer.sponsor_id is not null then
   v_commission:=round((v_order.total_amount*v_rate/100)::numeric,2);
   if v_commission>0 then
     insert into public.commissions(order_id,receiver_id,source_member_id,rate,amount,status)
     values(p_order_id,v_buyer.sponsor_id,v_order.buyer_id,v_rate,v_commission,'approved')
     on conflict(order_id,receiver_id) do nothing returning id into inserted_commission;
     if inserted_commission is not null then
       insert into public.wallets(member_id) values(v_buyer.sponsor_id) on conflict(member_id) do nothing;
       update public.wallets set available=available+v_commission,updated_at=now() where member_id=v_buyer.sponsor_id;
       insert into public.wallet_transactions(member_id,type,amount,reference_type,reference_id,description)
       values(v_buyer.sponsor_id,'commission_credit',v_commission,'order',p_order_id,'Komisi referral dari order '||v_order.order_no);
     end if;
   end if;
 end if;
 return jsonb_build_object('success',true,'order_id',p_order_id,'commission_rate',v_rate,'commission_amount',v_commission);
end;
$$;

create or replace function public.request_withdrawal(p_amount numeric,p_bank_name text,p_account_number text,p_account_name text) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_member uuid:=auth.uid();v_available numeric(14,2);v_min numeric(14,2);v_id uuid;v_no text;
begin
 if v_member is null then raise exception 'Belum login'; end if;
 select coalesce(value_numeric,50000) into v_min from public.settings where key='minimum_withdrawal';
 if p_amount<v_min then raise exception 'Minimal withdrawal belum terpenuhi'; end if;
 select available into v_available from public.wallets where member_id=v_member for update;
 if coalesce(v_available,0)<p_amount then raise exception 'Saldo tidak cukup'; end if;
 v_no:=public.make_withdrawal_no();
 insert into public.withdrawals(withdrawal_no,member_id,amount,bank_name,account_number,account_name) values(v_no,v_member,p_amount,trim(p_bank_name),trim(p_account_number),trim(p_account_name)) returning id into v_id;
 update public.wallets set available=available-p_amount,pending_withdrawal=pending_withdrawal+p_amount,updated_at=now() where member_id=v_member;
 insert into public.wallet_transactions(member_id,type,amount,reference_type,reference_id,description) values(v_member,'withdrawal_hold',p_amount,'withdrawal',v_id,'Saldo ditahan untuk '||v_no);
 return jsonb_build_object('success',true,'withdrawal_id',v_id,'withdrawal_no',v_no);
end;
$$;

create or replace function public.process_withdrawal(p_withdrawal_id uuid,p_action text,p_note text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_w withdrawals%rowtype;
begin
 select * into v_w from public.withdrawals where id=p_withdrawal_id for update;
 if not found then raise exception 'Withdrawal tidak ditemukan'; end if;
 if v_w.status<>'pending' then raise exception 'Withdrawal sudah diproses'; end if;
 if p_action='paid' then
   update public.withdrawals set status='paid',note=p_note,processed_at=now() where id=p_withdrawal_id;
   update public.wallets set pending_withdrawal=pending_withdrawal-v_w.amount,updated_at=now() where member_id=v_w.member_id;
   insert into public.wallet_transactions(member_id,type,amount,reference_type,reference_id,description) values(v_w.member_id,'withdrawal_debit',v_w.amount,'withdrawal',p_withdrawal_id,'Withdrawal dibayar: '||v_w.withdrawal_no);
 elsif p_action='rejected' then
   update public.withdrawals set status='rejected',note=p_note,processed_at=now() where id=p_withdrawal_id;
   update public.wallets set pending_withdrawal=pending_withdrawal-v_w.amount,available=available+v_w.amount,updated_at=now() where member_id=v_w.member_id;
   insert into public.wallet_transactions(member_id,type,amount,reference_type,reference_id,description) values(v_w.member_id,'withdrawal_release',v_w.amount,'withdrawal',p_withdrawal_id,'Saldo dikembalikan karena withdrawal ditolak: '||v_w.withdrawal_no);
 else raise exception 'Aksi tidak valid'; end if;
 return jsonb_build_object('success',true,'status',p_action);
end;
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.wallets enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.commissions enable row level security;
alter table public.withdrawals enable row level security;

drop policy if exists "profiles own or direct referrals" on public.profiles;
create policy "profiles own or direct referrals" on public.profiles for select to authenticated using(id=auth.uid() or sponsor_id=auth.uid());
drop policy if exists "products authenticated read" on public.products;
create policy "products authenticated read" on public.products for select to authenticated using(active=true);
drop policy if exists "orders own read" on public.orders;
create policy "orders own read" on public.orders for select to authenticated using(buyer_id=auth.uid());
drop policy if exists "orders own insert" on public.orders;
create policy "orders own insert" on public.orders for insert to authenticated with check(buyer_id=auth.uid() and status='pending');
drop policy if exists "order items own read" on public.order_items;
create policy "order items own read" on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_items.order_id and o.buyer_id=auth.uid()));
drop policy if exists "order items own insert" on public.order_items;
create policy "order items own insert" on public.order_items for insert to authenticated with check(exists(select 1 from public.orders o where o.id=order_items.order_id and o.buyer_id=auth.uid() and o.status='pending'));
drop policy if exists "wallet own read" on public.wallets;
create policy "wallet own read" on public.wallets for select to authenticated using(member_id=auth.uid());
drop policy if exists "wallet transaction own read" on public.wallet_transactions;
create policy "wallet transaction own read" on public.wallet_transactions for select to authenticated using(member_id=auth.uid());
drop policy if exists "commissions own read" on public.commissions;
create policy "commissions own read" on public.commissions for select to authenticated using(receiver_id=auth.uid());
drop policy if exists "withdrawals own read" on public.withdrawals;
create policy "withdrawals own read" on public.withdrawals for select to authenticated using(member_id=auth.uid());

grant execute on function public.request_withdrawal(numeric,text,text,text) to authenticated;
revoke all on function public.approve_order(uuid) from public,anon,authenticated;
revoke all on function public.process_withdrawal(uuid,text,text) from public,anon,authenticated;
grant execute on function public.approve_order(uuid) to service_role;
grant execute on function public.process_withdrawal(uuid,text,text) to service_role;