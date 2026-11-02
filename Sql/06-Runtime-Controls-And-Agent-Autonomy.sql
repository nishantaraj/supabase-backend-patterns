-- 06. Runtime controls and agent autonomy
--
-- Two ideas here.
--
-- 1. Kill switches live in a table, so stopping all sending is one update,
--    not a deployment.
-- 2. Every automated agent starts with no freedom to send. Raising that is
--    a deliberate act by an owner, done through one function. Ordinary
--    roles have no privilege on the column at all.

create table control.runtime_controls (
    control_key text primary key,
    bool_value  boolean     not null,
    updated_by  uuid,
    updated_at  timestamptz not null default now()
);

-- Sending starts switched off. Someone has to turn it on.
insert into control.runtime_controls (control_key, bool_value)
values ('sending_enabled', false);

create function control.is_enabled(p_control_key text) returns boolean
language sql stable
as $$
    -- A missing control counts as disabled, never as enabled.
    select coalesce(
        (select bool_value from control.runtime_controls
         where control_key = p_control_key),
        false);
$$;

-- Autonomy levels for sending:
--   0 = may draft only, a person sends
--   1 = may send after a person approves each message
--   2 = may send within frequency limits for approved segments
--   3 = may send without per-message review
create table control.agent_autonomy (
    id             uuid primary key default gen_random_uuid(),
    agent_key      text     not null,
    segment        text     not null,
    sending_level  smallint not null default 0
        constraint sending_level_range check (sending_level between 0 and 3),
    updated_by     uuid,
    updated_at     timestamptz not null default now(),
    unique (agent_key, segment)
);

-- Ordinary roles can register an agent and change its notes, never its level.
-- INSERT is limited to columns that leave sending_level at its default of 0,
-- and there is no UPDATE privilege on sending_level for anyone but the owner
-- of the table (and the function below, which runs as that owner).
revoke all on control.agent_autonomy from public;
grant select on control.agent_autonomy to authenticated, service_role;
grant insert (agent_key, segment) on control.agent_autonomy
    to authenticated, service_role;

-- The one door to a higher level. It checks the caller is an owner, refuses
-- to jump more than one step, and refuses while the sending switch is off.
create function control.raise_sending_autonomy(
    p_agent_key text,
    p_segment   text,
    p_level     smallint
) returns void
language plpgsql security definer
set search_path = pg_catalog, control, access, public
as $$
declare
    v_caller  uuid := auth.uid();
    v_current smallint;
begin
    if v_caller is null or not access.has_role(v_caller, 'owner') then
        raise exception 'only an owner can change sending autonomy'
            using errcode = 'insufficient_privilege';
    end if;

    select sending_level into v_current
    from control.agent_autonomy
    where agent_key = p_agent_key and segment = p_segment
    for update;

    if not found then
        raise exception 'unknown agent/segment' using errcode = 'no_data_found';
    end if;

    if p_level > v_current + 1 then
        raise exception 'raise one level at a time (% to %)', v_current, p_level
            using errcode = 'check_violation';
    end if;

    if p_level > 0 and not control.is_enabled('sending_enabled') then
        raise exception 'sending is switched off' using errcode = 'check_violation';
    end if;

    update control.agent_autonomy
    set sending_level = p_level, updated_by = v_caller, updated_at = now()
    where agent_key = p_agent_key and segment = p_segment;
end;
$$;

revoke all on function control.raise_sending_autonomy(text, text, smallint) from public;
grant execute on function control.raise_sending_autonomy(text, text, smallint)
    to authenticated;
