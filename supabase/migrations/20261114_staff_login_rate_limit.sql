-- Server-only login throttling; invoke via service-role server client, never from Flutter.
create table if not exists public.staff_login_attempts (
 fingerprint text primary key,
 attempts integer not null default 0,
 window_started timestamptz not null default now(),
 blocked_until timestamptz
);
alter table public.staff_login_attempts enable row level security;
create or replace function public.check_staff_login_rate(p_fingerprint text)
returns boolean language plpgsql security definer set search_path='' as $$
declare r public.staff_login_attempts%rowtype;
begin
 if char_length(p_fingerprint)<>64 then return false; end if;
 insert into public.staff_login_attempts(fingerprint) values(p_fingerprint) on conflict do nothing;
 select * into r from public.staff_login_attempts where fingerprint=p_fingerprint for update;
 if r.blocked_until > now() then return false; end if;
 if r.window_started < now()-interval '15 minutes' then
  update public.staff_login_attempts set attempts=1,window_started=now(),blocked_until=null where fingerprint=p_fingerprint;
  return true;
 end if;
 update public.staff_login_attempts set attempts=attempts+1,
  blocked_until=case when attempts+1>=8 then now()+interval '15 minutes' else null end
  where fingerprint=p_fingerprint;
 return r.attempts < 8;
end;
$$;
revoke all on function public.check_staff_login_rate(text) from public,anon,authenticated;
grant execute on function public.check_staff_login_rate(text) to service_role;
