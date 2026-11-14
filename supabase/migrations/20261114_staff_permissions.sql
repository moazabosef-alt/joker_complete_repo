-- AL JOKER STORE: run after reviewing a backup of your existing database.
-- Keeps public.admin_users as the owner-only allowlist. Do NOT add staff there.
begin;
create table if not exists public.staff_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 username text not null unique check (username ~ '^[a-z][a-z0-9_]{2,29}$'),
 display_name text not null check (char_length(trim(display_name)) between 1 and 100),
 phone text,
 is_active boolean not null default true,
 created_at timestamptz not null default now()
);
create table if not exists public.staff_permissions (
 user_id uuid primary key references public.staff_profiles(user_id) on delete cascade,
 can_add_products boolean not null default false,
 can_edit_products boolean not null default false,
 can_change_prices boolean not null default false,
 can_delete_products boolean not null default false,
 can_manage_categories boolean not null default false,
 can_manage_stock boolean not null default false,
 can_view_orders boolean not null default false,
 can_manage_orders boolean not null default false,
 can_manage_images boolean not null default false
);
create table if not exists public.staff_audit_log (
 id bigint generated always as identity primary key,
 actor_id uuid references auth.users(id) on delete set null,
 action text not null,
 target_table text not null,
 target_id text,
 old_record jsonb,
 new_record jsonb,
 created_at timestamptz not null default now()
);
create index if not exists idx_staff_audit_created on public.staff_audit_log(created_at desc);

create or replace function public.is_store_owner() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.admin_users where user_id = (select auth.uid()));
$$;
create or replace function public.staff_can(permission_name text) returns boolean
language sql stable security definer set search_path = '' as $$
 select public.is_store_owner() or exists (
  select 1 from public.staff_profiles p join public.staff_permissions s on s.user_id=p.user_id
  where p.user_id=(select auth.uid()) and p.is_active and
  case permission_name
   when 'add_products' then s.can_add_products
   when 'edit_products' then s.can_edit_products
   when 'change_prices' then s.can_change_prices
   when 'delete_products' then s.can_delete_products
   when 'manage_categories' then s.can_manage_categories
   when 'manage_stock' then s.can_manage_stock
   when 'view_orders' then s.can_view_orders
   when 'manage_orders' then s.can_manage_orders
   when 'manage_images' then s.can_manage_images
   else false end
 );
$$;
revoke all on function public.is_store_owner() from public;
revoke all on function public.staff_can(text) from public;
grant execute on function public.is_store_owner() to authenticated;
grant execute on function public.staff_can(text) to authenticated;

alter table public.staff_profiles enable row level security;
alter table public.staff_permissions enable row level security;
alter table public.staff_audit_log enable row level security;
create policy "owner or self reads staff profile" on public.staff_profiles for select to authenticated using(public.is_store_owner() or user_id=(select auth.uid()));
create policy "owner or self reads permissions" on public.staff_permissions for select to authenticated using(public.is_store_owner() or user_id=(select auth.uid()));
create policy "owner reads audit" on public.staff_audit_log for select to authenticated using(public.is_store_owner());
-- No direct client INSERT/UPDATE/DELETE policies on staff, permissions or audit.
-- Provision accounts and modify permissions only through trusted server-side operations.

-- Replace broad legacy policies. Existing SELECT policies for public catalog remain.
drop policy if exists "admin edits categories" on public.categories;
drop policy if exists "admin edits products" on public.products;
drop policy if exists "admin edits settings" on public.store_settings;
drop policy if exists "admin reads orders" on public.orders;
drop policy if exists "admin edits order status" on public.orders;
drop policy if exists "admin reads items" on public.order_items;
drop policy if exists "admin uploads images" on storage.objects;
drop policy if exists "admin edits images" on storage.objects;
drop policy if exists "admin removes images" on storage.objects;

create policy "staff adds categories" on public.categories for insert to authenticated with check(public.staff_can('manage_categories'));
create policy "staff edits categories" on public.categories for update to authenticated using(public.staff_can('manage_categories')) with check(public.staff_can('manage_categories'));
create policy "staff removes categories" on public.categories for delete to authenticated using(public.staff_can('manage_categories'));
create policy "staff adds products" on public.products for insert to authenticated with check(public.staff_can('add_products'));
create policy "staff removes products" on public.products for delete to authenticated using(public.staff_can('delete_products'));
-- Update policy grants row access; trigger below enforces field-level rights.
create policy "staff updates products" on public.products for update to authenticated using(public.staff_can('edit_products') or public.staff_can('change_prices') or public.staff_can('manage_stock') or public.staff_can('manage_images')) with check(public.staff_can('edit_products') or public.staff_can('change_prices') or public.staff_can('manage_stock') or public.staff_can('manage_images'));
create policy "owner edits settings" on public.store_settings for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
create policy "staff reads orders" on public.orders for select to authenticated using(public.staff_can('view_orders') or public.staff_can('manage_orders'));
create policy "staff edits orders" on public.orders for update to authenticated using(public.staff_can('manage_orders')) with check(public.staff_can('manage_orders'));
create policy "staff reads order items" on public.order_items for select to authenticated using(public.staff_can('view_orders') or public.staff_can('manage_orders'));
create policy "staff uploads images" on storage.objects for insert to authenticated with check(bucket_id='product-images' and public.staff_can('manage_images'));
create policy "staff updates images" on storage.objects for update to authenticated using(bucket_id='product-images' and public.staff_can('manage_images')) with check(bucket_id='product-images' and public.staff_can('manage_images'));
create policy "staff removes images" on storage.objects for delete to authenticated using(bucket_id='product-images' and public.staff_can('manage_images'));

create or replace function public.enforce_product_permissions() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
 if (select auth.uid()) is null then return new; end if; -- checkout RPC adjusts stock as trusted definer
 if old.name is distinct from new.name or old.category is distinct from new.category or old.description is distinct from new.description then
  if not public.staff_can('edit_products') then raise exception 'No permission to edit product details' using errcode='42501'; end if;
 end if;
 if old.price is distinct from new.price or old.old_price is distinct from new.old_price then
  if not public.staff_can('change_prices') then raise exception 'No permission to change prices' using errcode='42501'; end if;
 end if;
 if old.stock is distinct from new.stock then
  if not public.staff_can('manage_stock') then raise exception 'No permission to change stock' using errcode='42501'; end if;
 end if;
 if old.image_url is distinct from new.image_url then
  if not public.staff_can('manage_images') then raise exception 'No permission to change image' using errcode='42501'; end if;
 end if;
 if old.id is distinct from new.id or old.created_at is distinct from new.created_at then
  raise exception 'Cannot modify immutable product fields' using errcode='42501';
 end if;
 return new;
end;
$$;
drop trigger if exists trg_enforce_product_permissions on public.products;
create trigger trg_enforce_product_permissions before update on public.products
for each row execute function public.enforce_product_permissions();

-- Protect order total/customer PII from edits by staff; status-only updates.
create or replace function public.enforce_order_permissions() returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
 if (select auth.uid()) is null then return new; end if; -- checkout RPC sets server-calculated total
 if row(old.id,old.customer,old.phone,old.address,old.total,old.created_at)
 is distinct from row(new.id,new.customer,new.phone,new.address,new.total,new.created_at) then
  raise exception 'Only order status may be updated' using errcode='42501';
 end if;
 return new;
end;
$$;
drop trigger if exists trg_enforce_order_permissions on public.orders;
create trigger trg_enforce_order_permissions before update on public.orders
for each row execute function public.enforce_order_permissions();

-- Audit direct authenticated edits; server-side checkout calls can have auth.uid() null.
create or replace function public.audit_staff_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if (select auth.uid()) is not null then
  insert into public.staff_audit_log(actor_id,action,target_table,target_id,old_record,new_record)
  values((select auth.uid()),tg_op,tg_table_name,
   case when tg_op='DELETE' then to_jsonb(old)->>'id' else to_jsonb(new)->>'id' end,
   case when tg_op='INSERT' then null else to_jsonb(old) end,
   case when tg_op='DELETE' then null else to_jsonb(new) end);
 end if;
 return case when tg_op='DELETE' then old else new end;
end;
$$;
drop trigger if exists trg_audit_products on public.products;
create trigger trg_audit_products after insert or update or delete on public.products for each row execute function public.audit_staff_change();
drop trigger if exists trg_audit_orders on public.orders;
create trigger trg_audit_orders after update on public.orders for each row execute function public.audit_staff_change();

-- Prevent accidental owner creation by staff: admin_users has no INSERT policy.
commit;
