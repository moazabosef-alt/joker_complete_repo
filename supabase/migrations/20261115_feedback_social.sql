-- Run after base schema and staff permissions migration.
begin;
create table if not exists public.store_likes (
 id uuid primary key default gen_random_uuid(),
 visitor_token uuid not null unique,
 created_at timestamptz not null default now()
);
create table if not exists public.customer_feedback (
 id uuid primary key default gen_random_uuid(),
 rating integer not null check(rating between 1 and 5),
 message text not null default '' check(char_length(message)<=2000),
 created_at timestamptz not null default now()
);
create table if not exists public.social_links (
 platform text primary key, label text not null, url text not null default '', enabled boolean not null default false
);
insert into public.social_links(platform,label) values
('facebook','فيسبوك'),('instagram','إنستغرام'),('tiktok','تيك توك'),('telegram','تيليجرام'),('whatsapp','واتساب'),('youtube','يوتيوب'),('website','الموقع الإلكتروني') on conflict do nothing;
alter table public.store_likes enable row level security;
alter table public.customer_feedback enable row level security;
alter table public.social_links enable row level security;
create policy "public reads social" on public.social_links for select to anon,authenticated using(enabled);
create policy "owner manages social" on public.social_links for all to authenticated using(public.is_store_owner()) with check(public.is_store_owner());
create policy "owner reads feedback" on public.customer_feedback for select to authenticated using(public.is_store_owner());
-- Only controlled RPCs write feedback and likes; no direct public table writes.
create or replace function public.like_count() returns bigint language sql stable security definer set search_path='' as $$select count(*) from public.store_likes$$;
create or replace function public.toggle_store_like(p_token uuid, p_liked boolean) returns bigint language plpgsql security definer set search_path='' as $$
begin
 if p_token is null then raise exception 'Missing token'; end if;
 if p_liked then insert into public.store_likes(visitor_token) values(p_token) on conflict(visitor_token) do nothing;
 else delete from public.store_likes where visitor_token=p_token; end if;
 return (select count(*) from public.store_likes);
end;$$;
create or replace function public.my_store_like(p_token uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.store_likes where visitor_token=p_token)$$;
create or replace function public.submit_feedback(p_rating integer,p_message text) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if p_rating not between 1 and 5 or char_length(coalesce(p_message,''))>2000 then raise exception 'Invalid feedback'; end if;
 insert into public.customer_feedback(rating,message) values(p_rating,coalesce(p_message,'')) returning id into v_id;
 return v_id;
end;$$;
revoke all on function public.like_count() from public;
revoke all on function public.toggle_store_like(uuid,boolean) from public;
revoke all on function public.my_store_like(uuid) from public;
revoke all on function public.submit_feedback(integer,text) from public;
grant execute on function public.like_count() to anon,authenticated;
grant execute on function public.toggle_store_like(uuid,boolean) to anon,authenticated;
grant execute on function public.my_store_like(uuid) to anon,authenticated;
grant execute on function public.submit_feedback(integer,text) to anon,authenticated;
commit;
-- IMPORTANT: anonymous visitor tokens are best-effort only; users can reset them.
-- Put rate limits/CAPTCHA at a trusted API gateway before public launch.
