-- Fresh install only. Existing projects: back up and review before running.
create extension if not exists pgcrypto;
create table if not exists public.admin_users(user_id uuid primary key references auth.users(id) on delete cascade);
create table if not exists public.categories(name text primary key);
create table if not exists public.products(
 id text primary key, name text not null, category text not null references public.categories(name),
 description text not null default '', image_url text not null default '',
 price numeric(12,2) not null check(price>=0),old_price numeric(12,2) not null default 0 check(old_price>=0),
 stock integer not null default 0 check(stock>=0),created_at timestamptz not null default now()
);
create table if not exists public.store_settings(id integer primary key check(id=1),whatsapp text not null default '');
insert into public.store_settings(id,whatsapp) values(1,'218915206879') on conflict do nothing;
create table if not exists public.orders(
 id uuid primary key default gen_random_uuid(),customer text not null,phone text not null,address text not null,
 status text not null default 'جديد' check(status in ('جديد','قيد التجهيز','تم التسليم','ملغي')),
 total numeric(12,2) not null default 0,created_at timestamptz not null default now()
);
create table if not exists public.order_items(
 id bigint generated always as identity primary key,order_id uuid not null references public.orders(id) on delete cascade,
 product_id text references public.products(id) on delete set null,name text not null,price numeric(12,2) not null,quantity integer not null check(quantity>0)
);
create or replace function public.is_store_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.admin_users where user_id=(select auth.uid()));
$$;
revoke all on function public.is_store_admin() from public;
grant execute on function public.is_store_admin() to authenticated;
alter table public.admin_users enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.store_settings enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
create policy "admin sees self" on public.admin_users for select to authenticated using(user_id=(select auth.uid()));
create policy "public reads categories" on public.categories for select to anon,authenticated using(true);
create policy "admin edits categories" on public.categories for all to authenticated using(public.is_store_admin()) with check(public.is_store_admin());
create policy "public reads products" on public.products for select to anon,authenticated using(true);
create policy "admin edits products" on public.products for all to authenticated using(public.is_store_admin()) with check(public.is_store_admin());
create policy "public reads settings" on public.store_settings for select to anon,authenticated using(true);
create policy "admin edits settings" on public.store_settings for all to authenticated using(public.is_store_admin()) with check(public.is_store_admin());
create policy "admin reads orders" on public.orders for select to authenticated using(public.is_store_admin());
create policy "admin edits order status" on public.orders for update to authenticated using(public.is_store_admin()) with check(public.is_store_admin());
create policy "admin reads items" on public.order_items for select to authenticated using(public.is_store_admin());
create or replace function public.place_order(p_customer text,p_phone text,p_address text,p_items jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_item jsonb; v_product public.products%rowtype; v_qty integer; v_total numeric(12,2):=0; v_count integer:=0;
begin
 if length(trim(coalesce(p_customer,''))) not between 1 and 120 or length(trim(coalesce(p_phone,''))) not between 7 and 25 or length(trim(coalesce(p_address,''))) not between 1 and 500 then raise exception 'Invalid customer information'; end if;
 if jsonb_typeof(p_items)!='array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Invalid cart'; end if;
 create temporary table if not exists pg_temp.checkout_lines(pid text primary key,qty integer) on commit drop;
 truncate pg_temp.checkout_lines;
 insert into pg_temp.checkout_lines(pid,qty) select x.product_id,sum(x.quantity)::integer from jsonb_to_recordset(p_items) as x(product_id text,quantity integer) group by x.product_id;
 if exists(select 1 from pg_temp.checkout_lines where qty<1 or qty>100) then raise exception 'Invalid quantity'; end if;
 insert into public.orders(customer,phone,address,total) values(trim(p_customer),trim(p_phone),trim(p_address),0) returning id into v_id;
 for v_item in select jsonb_build_object('id',pid,'quantity',qty) from pg_temp.checkout_lines order by pid loop
  v_qty=(v_item->>'quantity')::integer;
  select * into v_product from public.products where id=v_item->>'id' for update;
  if not found or v_product.stock<v_qty then raise exception 'Product unavailable or insufficient stock'; end if;
  update public.products set stock=stock-v_qty where id=v_product.id;
  insert into public.order_items(order_id,product_id,name,price,quantity) values(v_id,v_product.id,v_product.name,v_product.price,v_qty);
  v_total=v_total+v_product.price*v_qty;v_count=v_count+1;
 end loop;
 if v_count=0 then raise exception 'Empty order';end if;
 update public.orders set total=v_total where id=v_id;
 return v_id;
end;
$$;
revoke all on function public.place_order(text,text,text,jsonb) from public;
grant execute on function public.place_order(text,text,text,jsonb) to anon,authenticated;
insert into public.categories(name) values('هواتف'),('حواسيب'),('سماعات'),('شواحن'),('ألعاب'),('ساعات ذكية') on conflict do nothing;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id) do nothing;
create policy "admin uploads images" on storage.objects for insert to authenticated with check(bucket_id='product-images' and public.is_store_admin());
create policy "admin edits images" on storage.objects for update to authenticated using(bucket_id='product-images' and public.is_store_admin()) with check(bucket_id='product-images' and public.is_store_admin());
create policy "admin removes images" on storage.objects for delete to authenticated using(bucket_id='product-images' and public.is_store_admin());
