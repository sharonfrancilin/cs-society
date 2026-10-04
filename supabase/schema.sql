-- =====================================================================
-- CS Society: database schema, security rules and functions
-- Run this ONCE in Supabase: SQL Editor -> New query -> paste -> Run
-- =====================================================================

-- ---------- tables ----------
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  photo_url  text,
  roles      text[] not null default array['resident','volunteer'],
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.user_settings (          -- private to each user
  user_id   uuid primary key references public.profiles(id) on delete cascade,
  loc_lat   double precision,
  loc_lng   double precision,
  loc_label text,
  prefs     jsonb not null default '{"claimed":true,"update":true,"resolved":true,"milestone":true,"near":false}',
  hours     numeric not null default 0
);

create table public.issues (
  id           bigint generated always as identity primary key,
  title        text not null check (char_length(title) between 8 and 80),
  category     text not null check (category in ('litter','dumping','damage','bin','other')),
  status       text not null default 'New' check (status in ('New','Claimed','In Progress','Resolved')),
  lat          double precision not null check (lat between -90 and 90),
  lng          double precision not null check (lng between -180 and 180),
  place        text not null default '',
  description  text not null default '',
  reporter_id  uuid not null references public.profiles(id) on delete cascade,
  volunteer_id uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index issues_status_idx on public.issues(status);
create index issues_geo_idx    on public.issues(lat, lng);

create table public.issue_events (           -- the timeline of each report
  id         bigint generated always as identity primary key,
  issue_id   bigint not null references public.issues(id) on delete cascade,
  author_id  uuid references public.profiles(id) on delete set null,
  type       text not null check (type in ('reported','claim','release','status','note')),
  text       text not null default '',
  status     text check (status in ('New','Claimed','In Progress','Resolved')),
  photo_url  text,
  created_at timestamptz not null default now()
);
create index events_issue_idx on public.issue_events(issue_id, created_at);

create table public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  type       text not null check (type in ('claimed','update','resolved','milestone','near')),
  issue_id   bigint references public.issues(id) on delete cascade,
  text       text not null,
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index notif_user_idx on public.notifications(user_id, created_at desc);

create table public.flags (                  -- "report this" for moderation
  id          bigint generated always as identity primary key,
  issue_id    bigint not null references public.issues(id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,
  reason      text not null default '',
  created_at  timestamptz not null default now()
);

-- ---------- new user -> profile ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare r text[] := array['resident','volunteer'];
begin
  if jsonb_typeof(new.raw_user_meta_data->'roles') = 'array' then
    r := array(select jsonb_array_elements_text(new.raw_user_meta_data->'roles'));
  end if;
  insert into public.profiles(id, name, roles)
    values (new.id, coalesce(new.raw_user_meta_data->>'name',''), r);
  insert into public.user_settings(user_id) values (new.id);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- row level security ----------
alter table public.profiles      enable row level security;
alter table public.user_settings enable row level security;
alter table public.issues        enable row level security;
alter table public.issue_events  enable row level security;
alter table public.notifications enable row level security;
alter table public.flags         enable row level security;

create policy "profiles are public"      on public.profiles      for select to anon, authenticated using (true);
create policy "edit own profile"         on public.profiles      for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "own settings: read"       on public.user_settings for select to authenticated using (user_id = auth.uid());
create policy "own settings: update"     on public.user_settings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "reports are public"       on public.issues        for select to anon, authenticated using (true);
create policy "timelines are public"     on public.issue_events  for select to anon, authenticated using (true);
create policy "own notifications: read"  on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "own notifications: update" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "admins read flags"        on public.flags for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin));

-- only these columns may be edited directly by a signed-in user
revoke update on public.profiles      from authenticated;
grant  update (name, photo_url, roles) on public.profiles to authenticated;
revoke update on public.user_settings from authenticated;
grant  update (loc_lat, loc_lng, loc_label, prefs) on public.user_settings to authenticated;
revoke update on public.notifications from authenticated;
grant  update (read) on public.notifications to authenticated;
revoke insert, delete on public.profiles, public.user_settings, public.issues, public.issue_events, public.notifications, public.flags from anon, authenticated;
revoke update, delete on public.issues, public.issue_events, public.flags from anon, authenticated;

-- ---------- helper: send a notification (internal only) ----------
create or replace function public.notify(p_user uuid, p_type text, p_issue bigint, p_text text) returns void
language sql security definer set search_path = public as $$
  insert into public.notifications(user_id, type, issue_id, text)
  select p_user, p_type, p_issue, p_text where p_user is not null;
$$;
revoke execute on function public.notify(uuid, text, bigint, text) from public, anon, authenticated;

-- ---------- actions (the only way to change reports) ----------
create or replace function public.create_issue(
  p_title text, p_category text, p_lat double precision, p_lng double precision,
  p_place text, p_description text, p_photo_url text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_id bigint;
begin
  if v_uid is null then raise exception 'Sign in required'; end if;
  if char_length(trim(p_title)) < 8 or char_length(trim(p_title)) > 80 then raise exception 'The title must be 8 to 80 characters'; end if;
  if p_category not in ('litter','dumping','damage','bin','other') then raise exception 'Invalid category'; end if;
  if not (p_lat between -90 and 90 and p_lng between -180 and 180) then raise exception 'Invalid location'; end if;
  if (select count(*) from public.issues where reporter_id = v_uid and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many reports in the last hour. Please try again later.'; end if;
  insert into public.issues(title, category, lat, lng, place, description, reporter_id)
    values (trim(p_title), p_category, p_lat, p_lng, left(coalesce(p_place,''),200),
            left(coalesce(nullif(trim(p_description),''), trim(p_title)),400), v_uid)
    returning id into v_id;
  insert into public.issue_events(issue_id, author_id, type, text, photo_url)
    values (v_id, v_uid, 'reported', left(coalesce(p_description,''),400), p_photo_url);
  perform public.notify(v_uid, 'update', v_id, 'Your report was shared with nearby volunteers');
  return v_id;
end $$;

create or replace function public.claim_issue(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); i public.issues%rowtype; v_name text; v_roles text[];
begin
  if v_uid is null then raise exception 'Sign in required'; end if;
  select roles into v_roles from public.profiles where id = v_uid;
  if not ('volunteer' = any(coalesce(v_roles, array[]::text[]))) then raise exception 'Turn on volunteering in your profile first'; end if;
  select * into i from public.issues where id = p_id for update;
  if not found then raise exception 'Report not found'; end if;
  if i.status <> 'New' or i.volunteer_id is not null then raise exception 'Someone has already claimed this report'; end if;
  update public.issues set status = 'Claimed', volunteer_id = v_uid, updated_at = now() where id = p_id;
  insert into public.issue_events(issue_id, author_id, type, text) values (p_id, v_uid, 'claim', 'A volunteer claimed this report.');
  select coalesce(nullif(name,''),'A volunteer') into v_name from public.profiles where id = v_uid;
  perform public.notify(i.reporter_id, 'claimed', p_id, v_name || ' claimed your report');
end $$;

create or replace function public.release_issue(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); i public.issues%rowtype;
begin
  if v_uid is null then raise exception 'Sign in required'; end if;
  select * into i from public.issues where id = p_id for update;
  if not found then raise exception 'Report not found'; end if;
  if i.volunteer_id is distinct from v_uid or i.status not in ('Claimed','In Progress') then
    raise exception 'You can only release a report you have claimed'; end if;
  update public.issues set status = 'New', volunteer_id = null, updated_at = now() where id = p_id;
  insert into public.issue_events(issue_id, author_id, type, text) values (p_id, v_uid, 'release', 'The volunteer released this report.');
  perform public.notify(i.reporter_id, 'update', p_id, 'A volunteer released your report. It is open again.');
end $$;

create or replace function public.post_update(
  p_id bigint, p_text text, p_status text default null, p_photo_url text default null, p_hours numeric default 0) returns void
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); i public.issues%rowtype; v_name text;
        v_is_vol boolean; v_is_rep boolean; v_type text := 'note';
begin
  if v_uid is null then raise exception 'Sign in required'; end if;
  select * into i from public.issues where id = p_id for update;
  if not found then raise exception 'Report not found'; end if;
  v_is_vol := i.volunteer_id = v_uid;  v_is_rep := i.reporter_id = v_uid;
  if not (v_is_vol or v_is_rep) then raise exception 'Only the reporter or the volunteer can post updates'; end if;
  if i.status = 'Resolved' and p_status is not null and p_status <> 'Resolved' then raise exception 'This report is already resolved'; end if;
  if p_status is not null and p_status <> i.status then
    if not v_is_vol then raise exception 'Only the volunteer can change the status'; end if;
    if p_status not in ('In Progress','Resolved') then raise exception 'Invalid status'; end if;
    update public.issues set status = p_status, updated_at = now() where id = p_id;
    v_type := 'status';
  end if;
  insert into public.issue_events(issue_id, author_id, type, text, status, photo_url)
    values (p_id, v_uid, v_type, left(coalesce(p_text,''),400), case when v_type = 'status' then p_status end, p_photo_url);
  if v_is_vol and coalesce(p_hours,0) > 0 then
    update public.user_settings set hours = hours + least(p_hours, 24) where user_id = v_uid; end if;
  select coalesce(nullif(name,''),'A neighbor') into v_name from public.profiles where id = v_uid;
  if v_is_vol then
    perform public.notify(i.reporter_id, case when p_status = 'Resolved' then 'resolved' else 'update' end, p_id,
      case when p_status = 'Resolved' then 'Your report was resolved by ' || v_name else v_name || ' added an update to your report' end);
  elsif i.volunteer_id is not null then
    perform public.notify(i.volunteer_id, 'update', p_id, v_name || ' added an update to the report you claimed');
  end if;
end $$;

create or replace function public.flag_issue(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  insert into public.flags(issue_id, reporter_id, reason) values (p_id, auth.uid(), left(coalesce(p_reason,''),300));
end $$;

-- reports near a point, closest first (radius in km)
create or replace function public.nearby_issues(p_lat double precision, p_lng double precision, p_radius_km double precision default 25)
returns table (id bigint, title text, category text, status text, lat double precision, lng double precision,
               place text, description text, reporter_id uuid, volunteer_id uuid, created_at timestamptz, distance_km double precision)
language sql stable as $$
  select * from (
    select i.id, i.title, i.category, i.status, i.lat, i.lng, i.place, i.description, i.reporter_id, i.volunteer_id, i.created_at,
           2 * 6371 * asin(sqrt(power(sin(radians(i.lat - p_lat) / 2), 2)
             + cos(radians(p_lat)) * cos(radians(i.lat)) * power(sin(radians(i.lng - p_lng) / 2), 2))) as distance_km
    from public.issues i) t
  where t.distance_km <= p_radius_km
  order by t.distance_km limit 200;
$$;

revoke execute on function public.create_issue(text,text,double precision,double precision,text,text,text) from public, anon;
revoke execute on function public.claim_issue(bigint)                 from public, anon;
revoke execute on function public.release_issue(bigint)               from public, anon;
revoke execute on function public.post_update(bigint,text,text,text,numeric) from public, anon;
revoke execute on function public.flag_issue(bigint,text)             from public, anon;
grant  execute on function public.create_issue(text,text,double precision,double precision,text,text,text) to authenticated;
grant  execute on function public.claim_issue(bigint)                 to authenticated;
grant  execute on function public.release_issue(bigint)               to authenticated;
grant  execute on function public.post_update(bigint,text,text,text,numeric) to authenticated;
grant  execute on function public.flag_issue(bigint,text)             to authenticated;
grant  execute on function public.nearby_issues(double precision,double precision,double precision) to anon, authenticated;

-- ---------- photo storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "photos: anyone can view"   on storage.objects for select to anon, authenticated using (bucket_id = 'photos');
create policy "photos: upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos: delete own"        on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- live updates ----------
alter publication supabase_realtime add table public.issues, public.issue_events, public.notifications;
