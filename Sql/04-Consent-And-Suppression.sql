-- 04. Consent and suppression
--
-- Permission to contact someone lives in the database, not in each tool.
-- An opt-out recorded once is honoured by every sender that asks.

create type compliance.channel as enum ('email', 'whatsapp', 'phone');

create table compliance.consents (
    id            uuid primary key default gen_random_uuid(),
    person_ref    text               not null,
    channel       compliance.channel not null,
    purpose       text               not null,   -- e.g. 'program_updates'
    granted_at    timestamptz        not null default now(),
    withdrawn_at  timestamptz,
    check (withdrawn_at is null or withdrawn_at >= granted_at)
);

create index consents_lookup_idx
    on compliance.consents (person_ref, channel, purpose);

-- Suppression beats consent. One row blocks a channel for a person.
create table compliance.suppressions (
    id          uuid primary key default gen_random_uuid(),
    person_ref  text               not null,
    channel     compliance.channel not null,
    reason      text               not null,
    created_at  timestamptz        not null default now(),
    unique (person_ref, channel)
);

-- Every sender calls this before sending. It is the only definition of
-- "allowed to contact".
create function compliance.can_send(
    p_person_ref text,
    p_channel    compliance.channel,
    p_purpose    text
) returns boolean
language sql
stable
as $$
    select
        not exists (
            select 1 from compliance.suppressions s
            where s.person_ref = p_person_ref and s.channel = p_channel
        )
        and exists (
            select 1 from compliance.consents c
            where c.person_ref = p_person_ref
              and c.channel = p_channel
              and c.purpose = p_purpose
              and c.withdrawn_at is null
        );
$$;
