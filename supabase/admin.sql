-- =====================================================================
-- CS Society: admin dashboard support
-- Run ONCE in Supabase (SQL Editor -> New query), AFTER schema.sql
-- =====================================================================

-- ---------- who is an admin ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;

-- ---------- log of admin actions ----------
create table if not exists public.admin_log (
  id         bigint generated always as identity primary key,
  admin_id   uuid references public.profiles(id) on delete set null,
  text       text not null,
  created_at timestamptz not null default now()
);
alter table public.admin_log enable row level security;
revoke insert, update, delete on public.admin_log from anon, authenticated;
create policy "admins read log" on public.admin_log for select to authenticated using (public.is_admin());

-- admins can see everyone's volunteer hours
create policy "admins read all settings" on public.user_settings for select to authenticated using (public.is_admin());

-- ---------- admin actions ----------
create or replace function public.admin_update_issue(
  p_id bigint, p_title text, p_category text, p_place text, p_description text, p_status text, p_volunteer uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); i public.issues%rowtype; v_vol uuid; v_vname text;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select * into i from public.issues where id = p_id for update;
  if not found then raise exception 'Report not found'; end if;
  if char_length(trim(p_title)) < 8 or char_length(trim(p_title)) > 80 then raise exception 'The title must be 8 to 80 characters'; end if;
  if p_category not in ('litter','dumping','damage','bin','other') then raise exception 'Invalid category'; end if;
  if p_status not in ('New','Claimed','In Progress','Resolved') then raise exception 'Invalid status'; end if;
  v_vol := case when p_status = 'New' then null else p_volunteer end;
  if p_status in ('Claimed','In Progress') and v_vol is null then raise exception 'Choose a volunteer for a task that is claimed or in progress'; end if;
  update public.issues set title = trim(p_title), category = p_category, place = left(coalesce(p_place,''),200),
    description = left(coalesce(nullif(trim(p_description),''), trim(p_title)),400),
    status = p_status, volunteer_id = v_vol, updated_at = now() where id = p_id;
  if p_status <> 'New' and v_vol is distinct from i.volunteer_id then
    select coalesce(nullif(name,''),'a volunteer') into v_vname from public.profiles where id = v_vol;
    insert into public.issue_events(issue_id, author_id, type, text)
      values (p_id, v_uid, 'note', case when v_vol is null then 'Unassigned by a moderator.' else 'Assigned to ' || v_vname || ' by a moderator.' end);
  end if;
  if p_status <> i.status then
    insert into public.issue_events(issue_id, author_id, type, text, status) values (p_id, v_uid, 'status', 'Updated by a moderator.', p_status);
    perform public.notify(i.reporter_id, case when p_status = 'Resolved' then 'resolved' else 'update' end, p_id,
      case when p_status = 'Resolved' then 'A moderator marked your report resolved' else 'A moderator changed your report to ' || p_status end);
  end if;
  insert into public.admin_log(admin_id, text) values (v_uid, 'GN-' || lpad(p_id::text,4,'0') || ' "' || trim(p_title) || '" edited');
end $$;

create or replace function public.admin_set_status(p_ids bigint[], p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.issues%rowtype;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_status not in ('New','Claimed','In Progress','Resolved') then raise exception 'Invalid status'; end if;
  for r in select * from public.issues where id = any(p_ids) for update loop
    if r.status <> p_status then
      if p_status in ('Claimed','In Progress') and r.volunteer_id is null then raise exception 'Report % has no volunteer', r.id; end if;
      update public.issues set status = p_status, volunteer_id = case when p_status = 'New' then null else volunteer_id end, updated_at = now() where id = r.id;
      insert into public.issue_events(issue_id, author_id, type, text, status) values (r.id, v_uid, 'status', 'Updated by a moderator.', p_status);
      perform public.notify(r.reporter_id, case when p_status = 'Resolved' then 'resolved' else 'update' end, r.id,
        case when p_status = 'Resolved' then 'A moderator marked your report resolved' else 'A moderator changed your report to ' || p_status end);
      insert into public.admin_log(admin_id, text) values (v_uid, 'GN-' || lpad(r.id::text,4,'0') || ' "' || r.title || '": ' || r.status || ' to ' || p_status);
    end if;
  end loop;
end $$;

create or replace function public.admin_delete_issues(p_ids bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r record;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  for r in select id, title from public.issues where id = any(p_ids) loop
    insert into public.admin_log(admin_id, text) values (v_uid, 'Removed GN-' || lpad(r.id::text,4,'0') || ' "' || r.title || '"');
  end loop;
  delete from public.issues where id = any(p_ids);
end $$;

create or replace function public.admin_release_claim(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); i public.issues%rowtype; v_name text;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select * into i from public.issues where id = p_id for update;
  if not found then raise exception 'Report not found'; end if;
  select coalesce(nullif(name,''),'a volunteer') into v_name from public.profiles where id = i.volunteer_id;
  update public.issues set status = 'New', volunteer_id = null, updated_at = now() where id = p_id;
  insert into public.issue_events(issue_id, author_id, type, text) values (p_id, v_uid, 'note', 'Released by a moderator so other volunteers can take it.');
  perform public.notify(i.volunteer_id, 'update', p_id, 'A moderator released a report you had claimed');
  insert into public.admin_log(admin_id, text) values (v_uid, 'GN-' || lpad(p_id::text,4,'0') || ' released from ' || coalesce(v_name,'a volunteer'));
end $$;

create or replace function public.admin_dismiss_flag(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_title text;
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select title into v_title from public.issues where id = p_id;
  delete from public.flags where issue_id = p_id;
  insert into public.admin_log(admin_id, text) values (v_uid, 'Kept GN-' || lpad(p_id::text,4,'0') || ' "' || coalesce(v_title,'') || '" after review');
end $$;

revoke execute on function public.admin_update_issue(bigint,text,text,text,text,text,uuid) from public, anon;
revoke execute on function public.admin_set_status(bigint[],text)   from public, anon;
revoke execute on function public.admin_delete_issues(bigint[])     from public, anon;
revoke execute on function public.admin_release_claim(bigint)       from public, anon;
revoke execute on function public.admin_dismiss_flag(bigint)        from public, anon;
grant  execute on function public.admin_update_issue(bigint,text,text,text,text,text,uuid) to authenticated;
grant  execute on function public.admin_set_status(bigint[],text)   to authenticated;
grant  execute on function public.admin_delete_issues(bigint[])     to authenticated;
grant  execute on function public.admin_release_claim(bigint)       to authenticated;
grant  execute on function public.admin_dismiss_flag(bigint)        to authenticated;

-- =====================================================================
-- MAKE YOURSELF THE FIRST ADMIN (change the email, then run this line)
-- =====================================================================
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'you@example.com');
