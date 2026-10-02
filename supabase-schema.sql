-- FIN Agency Sustainability Reporting Portal — Supabase setup
-- Run this whole file once in Supabase: SQL Editor -> New query -> Run.

create extension if not exists pgcrypto;

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','editor','viewer')),
  created_at timestamptz not null default now(),
  primary key (workspace_id,user_id)
);

create table if not exists public.workspace_invites (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  email text not null,
  role text not null default 'editor' check (role in ('editor','viewer')),
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  accepted_by uuid references auth.users(id) on delete set null,
  accepted_at timestamptz,
  unique (workspace_id,email)
);

create table if not exists public.register_items (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  item_id text not null,
  sort_order integer not null default 0,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (workspace_id,item_id)
);

create table if not exists public.item_history (
  id bigint generated always as identity primary key,
  workspace_id uuid not null,
  item_id text not null,
  action text not null check (action in ('insert','update','delete')),
  changed_at timestamptz not null default now(),
  changed_by uuid,
  data jsonb
);

create or replace function public.is_workspace_member(ws uuid, usr uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.workspace_members m where m.workspace_id=ws and m.user_id=usr); $$;

create or replace function public.can_edit_workspace(ws uuid, usr uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.workspace_members m where m.workspace_id=ws and m.user_id=usr and m.role in ('owner','editor')); $$;

create or replace function public.is_workspace_owner(ws uuid, usr uuid default auth.uid())
returns boolean
language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.workspace_members m where m.workspace_id=ws and m.user_id=usr and m.role='owner'); $$;

grant execute on function public.is_workspace_member(uuid,uuid) to authenticated;
grant execute on function public.can_edit_workspace(uuid,uuid) to authenticated;
grant execute on function public.is_workspace_owner(uuid,uuid) to authenticated;

alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_invites enable row level security;
alter table public.register_items enable row level security;
alter table public.item_history enable row level security;

-- Workspaces
create policy "members read workspaces" on public.workspaces for select to authenticated using (public.is_workspace_member(id));
create policy "users create own workspaces" on public.workspaces for insert to authenticated with check (created_by=auth.uid());
create policy "owners update workspaces" on public.workspaces for update to authenticated using (public.is_workspace_owner(id)) with check (public.is_workspace_owner(id));
create policy "owners delete workspaces" on public.workspaces for delete to authenticated using (public.is_workspace_owner(id));

-- Memberships. The workspace creator can add themself as the initial owner. Later membership is granted through claim_workspace_invites().
create policy "members read membership" on public.workspace_members for select to authenticated using (public.is_workspace_member(workspace_id));
create policy "creator adds initial owner" on public.workspace_members for insert to authenticated with check (
  user_id=auth.uid() and role='owner' and exists(select 1 from public.workspaces w where w.id=workspace_id and w.created_by=auth.uid())
);
create policy "owners update membership" on public.workspace_members for update to authenticated using (public.is_workspace_owner(workspace_id)) with check (public.is_workspace_owner(workspace_id));
create policy "owners delete membership" on public.workspace_members for delete to authenticated using (public.is_workspace_owner(workspace_id));

-- Invitations
create policy "owners read invites" on public.workspace_invites for select to authenticated using (public.is_workspace_owner(workspace_id));
create policy "owners create invites" on public.workspace_invites for insert to authenticated with check (public.is_workspace_owner(workspace_id) and created_by=auth.uid());
create policy "owners update invites" on public.workspace_invites for update to authenticated using (public.is_workspace_owner(workspace_id)) with check (public.is_workspace_owner(workspace_id));
create policy "owners delete invites" on public.workspace_invites for delete to authenticated using (public.is_workspace_owner(workspace_id));

-- Register items
create policy "members read register" on public.register_items for select to authenticated using (public.is_workspace_member(workspace_id));
create policy "editors insert register" on public.register_items for insert to authenticated with check (public.can_edit_workspace(workspace_id) and updated_by=auth.uid());
create policy "editors update register" on public.register_items for update to authenticated using (public.can_edit_workspace(workspace_id)) with check (public.can_edit_workspace(workspace_id) and updated_by=auth.uid());
create policy "editors delete register" on public.register_items for delete to authenticated using (public.can_edit_workspace(workspace_id));

-- Audit history is append-only via trigger and readable by workspace members.
create policy "members read history" on public.item_history for select to authenticated using (public.is_workspace_member(workspace_id));

create or replace function public.audit_register_item()
returns trigger
language plpgsql security definer set search_path=public
as $$
begin
  if tg_op='DELETE' then
    insert into public.item_history(workspace_id,item_id,action,changed_by,data)
      values(old.workspace_id,old.item_id,'delete',auth.uid(),old.data);
    return old;
  elsif tg_op='INSERT' then
    insert into public.item_history(workspace_id,item_id,action,changed_by,data)
      values(new.workspace_id,new.item_id,'insert',auth.uid(),new.data);
    return new;
  else
    new.updated_at=now();
    insert into public.item_history(workspace_id,item_id,action,changed_by,data)
      values(new.workspace_id,new.item_id,'update',auth.uid(),new.data);
    return new;
  end if;
end; $$;

drop trigger if exists register_items_audit on public.register_items;
create trigger register_items_audit before insert or update or delete on public.register_items
for each row execute function public.audit_register_item();

-- Accept matching email invitations after a user signs in.
create or replace function public.claim_workspace_invites()
returns integer
language plpgsql security definer set search_path=public,auth
as $$
declare
  user_email text;
  n integer := 0;
begin
  if auth.uid() is null then return 0; end if;
  select lower(email) into user_email from auth.users where id=auth.uid();

  insert into public.workspace_members(workspace_id,user_id,role)
  select i.workspace_id,auth.uid(),i.role
  from public.workspace_invites i
  where lower(i.email)=user_email and i.accepted_at is null
  on conflict (workspace_id,user_id) do nothing;

  update public.workspace_invites
     set accepted_by=auth.uid(), accepted_at=coalesce(accepted_at,now())
   where lower(email)=user_email and accepted_at is null;
  get diagnostics n = row_count;
  return n;
end; $$;

grant execute on function public.claim_workspace_invites() to authenticated;

-- Private evidence storage.
insert into storage.buckets(id,name,public) values('evidence','evidence',false)
on conflict (id) do update set public=false;

create policy "members download evidence" on storage.objects for select to authenticated
using (bucket_id='evidence' and public.is_workspace_member(((storage.foldername(name))[1])::uuid));
create policy "editors upload evidence" on storage.objects for insert to authenticated
with check (bucket_id='evidence' and public.can_edit_workspace(((storage.foldername(name))[1])::uuid));
create policy "editors update evidence" on storage.objects for update to authenticated
using (bucket_id='evidence' and public.can_edit_workspace(((storage.foldername(name))[1])::uuid))
with check (bucket_id='evidence' and public.can_edit_workspace(((storage.foldername(name))[1])::uuid));
create policy "editors delete evidence" on storage.objects for delete to authenticated
using (bucket_id='evidence' and public.can_edit_workspace(((storage.foldername(name))[1])::uuid));

-- Realtime is optional, but lets another open browser refresh shortly after a shared item changes.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='register_items'
  ) then
    alter publication supabase_realtime add table public.register_items;
  end if;
end $$;
