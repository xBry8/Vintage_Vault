-- Vintage Vault core schema. Run once in the Supabase SQL editor.
create table public.admins (user_id uuid primary key references auth.users on delete cascade);
create function public.is_admin() returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  full_name text check (char_length(full_name) between 2 and 80),
  phone text check (phone ~ '^09\d{9}$'),
  address text check (char_length(address) between 8 and 300),
  created_at timestamptz not null default now());
create function public.new_profile() returns trigger language plpgsql security definer set search_path = public
as $$ begin insert into profiles (id) values (new.id) on conflict do nothing; return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.new_profile();

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  category text not null,
  price_php integer not null check (price_php > 0),
  condition text, size text, measurements text, description text,
  image_paths text[] not null default '{}',            -- paths in the product-images bucket
  status text not null default 'available' check (status in ('available','reserved','sold','unpublished')),
  created_at timestamptz not null default now());

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique default 'VV-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  user_id uuid not null references auth.users,
  ship_name text not null, ship_phone text not null, ship_address text not null,
  total_php integer not null check (total_php > 0),
  status text not null default 'pending_payment' check (status in
    ('pending_payment','payment_confirmed','processing','packed','shipped','delivered','cancelled')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','paid','failed','expired','refunded')),
  paymongo_session_id text unique, payment_id text,
  reserved_until timestamptz not null default now() + interval '30 minutes',
  created_at timestamptz not null default now(),
  check (payment_status = 'paid' or status in ('pending_payment','cancelled')));   -- nothing ships unpaid
create table public.order_items (
  order_id uuid references public.orders on delete cascade,
  product_id uuid references public.products,
  price_php integer not null,
  primary key (order_id, product_id));

create table public.webhook_events (id text primary key, type text, received_at timestamptz not null default now());
create table public.refund_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders on delete cascade,
  user_id uuid not null references auth.users,
  reason text not null check (char_length(reason) between 5 and 1000),
  evidence_paths text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','rejected','refunded')),
  created_at timestamptz not null default now());
create table public.chat_messages (
  id bigint generated always as identity primary key,
  customer_id uuid not null references auth.users,
  from_admin boolean not null default false,
  body text not null check (char_length(body) between 1 and 1000),
  read boolean not null default false,
  created_at timestamptz not null default now());
alter publication supabase_realtime add table public.chat_messages;

-- Reserve one-of-a-kind pieces atomically, then create the order. Service role only.
create function public.place_order(p_user uuid, p_ids uuid[], p_name text, p_phone text, p_address text)
returns table (o_id uuid, o_no text, o_total int) language plpgsql security definer set search_path = public as $$
declare v_n int; v_total int; v_id uuid; v_no text;
begin
  select array_agg(distinct x) into p_ids from unnest(p_ids) x;
  if p_ids is null or cardinality(p_ids) > 20 then raise exception 'invalid_cart'; end if;
  perform public.release_expired();
  update products set status = 'reserved' where id = any(p_ids) and status = 'available';
  get diagnostics v_n = row_count;
  if v_n <> cardinality(p_ids) then raise exception 'item_unavailable'; end if;  -- rolls everything back
  select sum(price_php) into v_total from products where id = any(p_ids);
  insert into orders (user_id, ship_name, ship_phone, ship_address, total_php)
    values (p_user, p_name, p_phone, p_address, v_total) returning id, orders.order_no into v_id, v_no;
  insert into order_items select v_id, id, price_php from products where id = any(p_ids);
  return query select v_id, v_no, v_total;
end $$;

-- Unpaid orders past their window are cancelled and their pieces go back on sale.
create function public.release_expired() returns void language sql security definer set search_path = public as $$
  with o as (update orders set status = 'cancelled', payment_status = 'expired'
             where status = 'pending_payment' and reserved_until < now() returning id)
  update products set status = 'available'
   where status = 'reserved' and id in (select product_id from order_items where order_id in (select id from o));
$$;
-- Optional (enable pg_cron first): select cron.schedule('release-expired','*/10 * * * *','select public.release_expired()');

-- Called only by the verified webhook. Idempotent.
create function public.mark_paid(p_session text, p_payment text) returns void
language plpgsql security definer set search_path = public as $$
declare v orders;
begin
  select * into v from orders where paymongo_session_id = p_session for update;
  if not found or v.payment_status = 'paid' then return; end if;
  update orders set payment_status = 'paid', payment_id = p_payment,
    status = case when v.status = 'pending_payment' then 'payment_confirmed' else v.status end where id = v.id;
  -- Paid after the window lapsed: order stays 'cancelled' + 'paid' so the admin can refund it. Stock is untouched.
  if v.status = 'pending_payment' then
    update products set status = 'sold' where id in (select product_id from order_items where order_id = v.id);
  end if;
end $$;
revoke all on function public.place_order(uuid,uuid[],text,text,text), public.release_expired(),
  public.mark_paid(text,text) from public, anon, authenticated;

-- Row Level Security
alter table public.admins enable row level security;           -- no policies: editable only via SQL editor
alter table public.webhook_events enable row level security;   -- no policies: service role only
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.refund_requests enable row level security;
alter table public.chat_messages enable row level security;

create policy profiles_read on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_new on profiles for insert with check (id = auth.uid());
create policy profiles_edit on profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy products_read on products for select using (status <> 'unpublished' or is_admin());
create policy products_admin on products for all using (is_admin()) with check (is_admin());
create policy orders_read on orders for select using (user_id = auth.uid() or is_admin());
create policy orders_admin on orders for update using (is_admin()) with check (is_admin());
create policy items_read on order_items for select using (exists (
  select 1 from orders o where o.id = order_id and (o.user_id = auth.uid() or is_admin())));
create policy refunds_read on refund_requests for select using (user_id = auth.uid() or is_admin());
create policy refunds_new on refund_requests for insert with check (user_id = auth.uid() and exists (
  select 1 from orders o where o.id = order_id and o.user_id = auth.uid() and o.payment_status = 'paid'));
create policy refunds_admin on refund_requests for update using (is_admin()) with check (is_admin());
create policy chat_read on chat_messages for select using (customer_id = auth.uid() or is_admin());
create policy chat_customer on chat_messages for insert with check (customer_id = auth.uid() and not from_admin);
create policy chat_admin on chat_messages for insert with check (is_admin() and from_admin);
create policy chat_seen on chat_messages for update using (is_admin()) with check (is_admin());

-- Browsers can never create orders or touch payment fields; admins may change fulfilment status only.
revoke insert, update, delete on public.orders, public.order_items from anon, authenticated;
grant update (status) on public.orders to authenticated;

-- Product photos: public read, admin-only writes, images only, 5 MB max.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy product_images_admin on storage.objects for all
  using (bucket_id = 'product-images' and public.is_admin())
  with check (bucket_id = 'product-images' and public.is_admin());
