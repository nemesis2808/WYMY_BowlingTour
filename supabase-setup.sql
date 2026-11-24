-- Bowling Strike Tournament 2026 - database + rules (run ONCE in Supabase > SQL Editor > New query > Run)
-- Same rules as the old server.js: 34 teams (SUP 6 / P1 14 / P2 14), 6 members (3M + 3F),
-- one team per Badge ID, unique team name, deadline, admin delete/export.

-- >>> CHANGE THE ADMIN KEY BELOW BEFORE RUNNING <<<
create table if not exists app_config(k text primary key, v text not null);
insert into app_config(k,v) values
  ('admin_key','CHANGE_ME_TO_YOUR_OWN_PASSWORD'),
  ('deadline','2026-12-10T23:59:59+08:00'),
  ('total_teams','34')
on conflict (k) do nothing;

create table if not exists teams(
  team_id text primary key,
  grp text not null,
  slot int not null,
  team_name text not null,
  registered_by text not null,
  created_at timestamptz not null default now(),
  members jsonb not null
);
create unique index if not exists teams_name_ci on teams (lower(team_name));
create unique index if not exists teams_grp_slot on teams (grp, slot);

create table if not exists sessions(token text primary key, badge text not null, exp timestamptz not null);

-- lock the tables: nobody can touch them directly, only through the functions below
alter table app_config enable row level security;
alter table teams enable row level security;
alter table sessions enable row level security;
revoke all on app_config, teams, sessions from anon, authenticated;

create or replace function _groups() returns jsonb language sql immutable as $$
  select '{"office":{"code":"SUP","name":"Support Team","cap":6},"plant1":{"code":"P1","name":"Plant 1","cap":14},"plant2":{"code":"P2","name":"Plant 2","cap":14}}'::jsonb
$$;
create or replace function _deadline() returns timestamptz language sql stable as $$ select v::timestamptz from app_config where k='deadline' $$;
create or replace function _total() returns int language sql stable as $$ select v::int from app_config where k='total_teams' $$;
create or replace function _admin_ok(key text) returns boolean language sql stable as $$
  select exists(select 1 from app_config where k='admin_key' and v = coalesce(key,''))
$$;
create or replace function _team_json(t teams) returns jsonb language sql immutable as $$
  select jsonb_build_object('teamId',t.team_id,'group',t.grp,'slot',t.slot,'teamName',t.team_name,
    'registeredBy',t.registered_by,'createdAt',to_char(t.created_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),'members',t.members)
$$;

-- GET teams
create or replace function api_teams() returns jsonb language plpgsql security definer set search_path=public as $$
declare list jsonb;
begin
  select coalesce(jsonb_agg(_team_json(t) order by case t.grp when 'office' then 1 when 'plant1' then 2 else 3 end, t.slot),'[]')
    into list from teams t;
  return jsonb_build_object('teams',list,'deadline',(select v from app_config where k='deadline'),
    'closed',now()>_deadline(),'total',_total(),'groups',_groups());
end $$;

-- login by badge
create or replace function api_login(badge text) returns jsonb language plpgsql security definer set search_path=public as $$
declare b text := upper(btrim(coalesce(badge,''))); t teams%rowtype; tok text;
begin
  if b !~ '^[A-Z0-9_-]{3,20}$' then return jsonb_build_object('_status',400,'error','Badge ID must be 3 to 20 letters, digits, - or _.'); end if;
  if now()>_deadline() then return jsonb_build_object('_status',403,'error','Registration is closed.','closed',true); end if;
  select * into t from teams where members @> jsonb_build_array(jsonb_build_object('badge',b)) limit 1;
  if found then return jsonb_build_object('_status',409,'error','Badge ID '||b||' is already registered in team '||t.team_id||' ('||t.team_name||').','team',_team_json(t)); end if;
  delete from sessions where exp < now();
  tok := replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into sessions values (tok,b,now()+interval '2 hours');
  return jsonb_build_object('token',tok,'badge',b);
end $$;

-- register a team
create or replace function api_register(d jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  s sessions%rowtype; g jsonb; errs text[] := '{}'; tn text; ms jsonb; clean jsonb := '[]'::jsonb;
  m jsonb; i int := 0; b text; dp text; nm text; gd text; cntm int := 0; cntf int := 0; allg boolean := true;
  seen text[] := '{}'; cap int; gname text; code text; inG int; nslot int; tid text; clash text[] := '{}'; t teams%rowtype; newt teams%rowtype;
  first_badge text;
begin
  perform pg_advisory_xact_lock(7001);   -- one registration at a time: two people can never win the last slot
  select * into s from sessions where token = d->>'token';
  if not found or s.exp < now() then return jsonb_build_object('_status',401,'errors',jsonb_build_array('Your login expired. Log in again.'),'relogin',true); end if;
  if now()>_deadline() then return jsonb_build_object('_status',403,'errors',jsonb_build_array('Registration is closed.')); end if;
  g := _groups() -> (d->>'group');
  if g is null then return jsonb_build_object('_status',400,'errors',jsonb_build_array('Choose a group.')); end if;
  cap := (g->>'cap')::int; gname := g->>'name'; code := g->>'code';
  tn := btrim(regexp_replace(coalesce(d->>'teamName',''),'\s+',' ','g'));
  if char_length(tn) < 3 or char_length(tn) > 30 then errs := array_append(errs, ('Team name must be 3 to 30 characters.')::text); end if;
  ms := case when jsonb_typeof(d->'members')='array' then d->'members' else '[]'::jsonb end;
  if jsonb_array_length(ms) <> 6 then errs := array_append(errs, ('A team needs exactly 6 members.')::text); end if;
  for m in select * from jsonb_array_elements(ms) loop
    i := i + 1;
    b  := upper(btrim(coalesce(m->>'badge','')));
    dp := upper(btrim(coalesce(m->>'dept','')));
    nm := upper(btrim(regexp_replace(coalesce(m->>'name',''),'\s+',' ','g')));
    gd := m->>'gender';
    clean := clean || jsonb_build_array(jsonb_build_object('badge',b,'dept',dp,'name',nm,'gender',gd));
    if b !~ '^[A-Z0-9_-]{3,20}$' then errs := array_append(errs, (('Member '||i||': Badge ID is required.'))::text); end if;
    if dp !~ '^[A-Z0-9_-]{2,12}$' then errs := array_append(errs, (('Member '||i||': Dept code is required.'))::text); end if;
    if char_length(nm) < 3 or char_length(nm) > 80 then errs := array_append(errs, (('Member '||i||': Name as per NRIC is required.'))::text); end if;
    if gd is distinct from 'M' and gd is distinct from 'F' then errs := array_append(errs, (('Member '||i||': Select gender.'))::text); allg := false; end if;
    if gd = 'M' then cntm := cntm + 1; elsif gd = 'F' then cntf := cntf + 1; end if;
    if i = 1 then first_badge := b; end if;
    if b = any(seen) then errs := array_append(errs, (('Member '||i||': Badge ID '||b||' is repeated in this team.'))::text); end if;
    seen := array_append(seen, b);
  end loop;
  if first_badge is not null and first_badge <> s.badge then errs := array_append(errs, ('Member 1 must be the person who logged in.')::text); end if;
  if allg and jsonb_array_length(ms) > 0 and (cntm <> 3 or cntf <> 3) then
    errs := array_append(errs, (('Gender check failed: this team has '||cntm||' male and '||cntf||' female. Each team needs exactly 3 male and 3 female members.'))::text);
  end if;
  if array_length(errs,1) > 0 then return jsonb_build_object('_status',400,'errors',to_jsonb(errs)); end if;

  if (select count(*) from teams) >= _total() then return jsonb_build_object('_status',409,'errors',jsonb_build_array('All '||_total()||' team slots are taken.'),'back',true); end if;
  select count(*) into inG from teams where grp = d->>'group';
  if inG >= cap then return jsonb_build_object('_status',409,'errors',jsonb_build_array(gname||' is full ('||cap||' of '||cap||'). Pick another group.'),'back',true); end if;
  if exists(select 1 from teams where lower(team_name)=lower(tn)) then
    return jsonb_build_object('_status',409,'errors',jsonb_build_array('Team name "'||tn||'" is already taken. Choose another.'));
  end if;
  for m in select * from jsonb_array_elements(clean) loop
    select * into t from teams where members @> jsonb_build_array(jsonb_build_object('badge',m->>'badge')) limit 1;
    if found then clash := array_append(clash, (m->>'name')||' ('||(m->>'badge')||') is already registered in team '||t.team_id||'.'); end if;
  end loop;
  if array_length(clash,1) > 0 then return jsonb_build_object('_status',409,'errors',to_jsonb(clash)); end if;

  nslot := 1;
  while exists(select 1 from teams where grp = d->>'group' and teams.slot = nslot) loop nslot := nslot + 1; end loop;
  tid := code||'-'||lpad(nslot::text,2,'0');
  insert into teams(team_id,grp,slot,team_name,registered_by,members) values (tid,d->>'group',nslot,tn,s.badge,clean) returning * into newt;
  delete from sessions where token = s.token;
  return jsonb_build_object('team',_team_json(newt));
end $$;

-- admin
create or replace function api_admin_check(key text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not _admin_ok(key) then return jsonb_build_object('_status',401,'error','Wrong admin key.'); end if;
  return jsonb_build_object('ok',true);
end $$;
create or replace function api_admin_delete(key text, tid text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not _admin_ok(key) then return jsonb_build_object('_status',401,'error','Wrong admin key.'); end if;
  delete from teams where team_id = tid;
  return jsonb_build_object('ok',true);
end $$;
create or replace function api_admin_export(key text) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not _admin_ok(key) then return jsonb_build_object('_status',401,'error','Wrong admin key.'); end if;
  return api_teams();
end $$;

-- only the api_* functions are callable from the web page
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function api_teams(), api_login(text), api_register(jsonb), api_admin_check(text), api_admin_delete(text,text), api_admin_export(text) to anon, authenticated;
