-- 05. Access control and audit
--
-- Roles say what a person normally does. Grants are time-limited, carry a
-- reason, and are the only way to reach sensitive data. Each use is logged
-- in a table that cannot be edited afterwards.

create type access.staff_role as enum ('owner', 'admin', 'finance', 'viewer');

create table access.role_assignments (
    staff_id uuid              not null,
    role     access.staff_role not null,
    primary key (staff_id, role)
);

create table access.grants (
    id          uuid primary key default gen_random_uuid(),
    staff_id    uuid        not null,
    grant_key   text        not null,       -- e.g. 'view_contact_details'
    reason      text        not null check (length(btrim(reason)) >= 10),
    granted_by  uuid        not null,
    granted_at  timestamptz not null default now(),
    expires_at  timestamptz not null,
    check (expires_at > granted_at)
);

create index grants_lookup_idx on access.grants (staff_id, grant_key);

create function access.has_role(p_staff_id uuid, p_role access.staff_role)
returns boolean
language sql stable security definer
set search_path = pg_catalog, access
as $$
    select exists (
        select 1 from access.role_assignments
        where staff_id = p_staff_id and role = p_role
    );
$$;

create function access.has_grant(p_staff_id uuid, p_grant_key text)
returns boolean
language sql stable security definer
set search_path = pg_catalog, access
as $$
    select exists (
        select 1 from access.grants
        where staff_id = p_staff_id
          and grant_key = p_grant_key
          and expires_at > now()
    );
$$;

-- The audit log.
create table access.sensitive_access_log (
    id           bigint generated always as identity primary key,
    staff_id     uuid        not null,
    grant_key    text        not null,
    subject_kind text        not null,
    subject_id   text        not null,
    context      jsonb       not null default '{}'::jsonb,
    at           timestamptz not null default now()
);

-- Append-only, enforced by triggers. Revoking privileges is not enough on
-- its own, because a superuser or a table owner can still edit rows.
create function access.block_log_changes() returns trigger
language plpgsql
as $$
begin
    raise exception 'access.sensitive_access_log is append-only (% blocked)', tg_op
        using errcode = 'insufficient_privilege';
end;
$$;

create trigger log_no_update_delete
    before update or delete on access.sensitive_access_log
    for each row execute function access.block_log_changes();

create trigger log_no_truncate
    before truncate on access.sensitive_access_log
    for each statement execute function access.block_log_changes();

-- Reading sensitive data goes through this function. It checks for a live
-- grant and writes the log row in the same transaction as the decision.
create function access.log_sensitive_access(
    p_staff_id     uuid,
    p_grant_key    text,
    p_subject_kind text,
    p_subject_id   text,
    p_context      jsonb default '{}'::jsonb
) returns bigint
language plpgsql security definer
set search_path = pg_catalog, access
as $$
declare
    v_id bigint;
begin
    if not access.has_grant(p_staff_id, p_grant_key) then
        raise exception 'no live grant "%" for this staff member', p_grant_key
            using errcode = 'insufficient_privilege';
    end if;

    insert into access.sensitive_access_log
        (staff_id, grant_key, subject_kind, subject_id, context)
    values
        (p_staff_id, p_grant_key, p_subject_kind, p_subject_id, p_context)
    returning id into v_id;

    return v_id;
end;
$$;
