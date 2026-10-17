begin;
create table if not exists public.gmail_oauth_states(state_hash text primary key,verifier text not null,expires_at timestamptz not null);
create table if not exists public.gmail_connections(email text primary key check(email='thibo@bloxflow.be'),refresh_token_ciphertext text not null,refresh_token_iv text not null,scopes text[] not null,connected_at timestamptz not null default now(),sending_enabled boolean not null default false check(not sending_enabled));
alter table public.gmail_oauth_states enable row level security;
alter table public.gmail_connections enable row level security;
revoke all on public.gmail_oauth_states,public.gmail_connections from anon,authenticated;
grant all on public.gmail_oauth_states,public.gmail_connections to service_role;
update public.sending_settings set paused=true where id=true;
commit;
