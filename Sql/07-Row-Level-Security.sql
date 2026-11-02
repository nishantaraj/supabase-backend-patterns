-- 07. Row-level security
--
-- Deny by default. RLS is switched on (and forced) for every table. A table
-- with RLS on and no policy returns nothing to anon and authenticated
-- callers. Policies below open exactly what each role needs.
--
-- service_role bypasses RLS in Supabase, which is why server-side code that
-- uses it must never be reachable from a browser.

alter table inbound.records            enable row level security;
alter table core.applications          enable row level security;
alter table core.payments              enable row level security;
alter table core.refunds               enable row level security;
alter table compliance.consents        enable row level security;
alter table compliance.suppressions    enable row level security;
alter table access.role_assignments    enable row level security;
alter table access.grants              enable row level security;
alter table access.sensitive_access_log enable row level security;
alter table control.runtime_controls   enable row level security;
alter table control.agent_autonomy     enable row level security;

alter table inbound.records            force row level security;
alter table core.applications          force row level security;
alter table core.payments              force row level security;
alter table core.refunds               force row level security;
alter table compliance.consents        force row level security;
alter table compliance.suppressions    force row level security;
alter table access.role_assignments    force row level security;
alter table access.grants              force row level security;
alter table access.sensitive_access_log force row level security;
alter table control.runtime_controls   force row level security;
alter table control.agent_autonomy     force row level security;

-- Schema and table privileges. anon gets nothing.
grant usage on schema core, compliance, access, control to authenticated, service_role;
grant usage on schema inbound to service_role;

grant select on core.applications, core.payments, core.refunds to authenticated;
grant select on compliance.consents, compliance.suppressions to authenticated;
grant select on access.role_assignments, access.grants to authenticated;
grant select on control.runtime_controls to authenticated;

grant all on all tables in schema inbound, core, compliance, access, control
    to service_role;
-- The log stays append-only for everyone, including service_role.
revoke update, delete, truncate on access.sensitive_access_log from service_role;

-- Money tables: finance, admin and owner can read.
create policy finance_reads_payments on core.payments
    for select to authenticated
    using (
        access.has_role(auth.uid(), 'finance')
        or access.has_role(auth.uid(), 'admin')
        or access.has_role(auth.uid(), 'owner')
    );

create policy finance_reads_refunds on core.refunds
    for select to authenticated
    using (
        access.has_role(auth.uid(), 'finance')
        or access.has_role(auth.uid(), 'admin')
        or access.has_role(auth.uid(), 'owner')
    );

create policy staff_read_applications on core.applications
    for select to authenticated
    using (
        access.has_role(auth.uid(), 'admin')
        or access.has_role(auth.uid(), 'owner')
        or access.has_role(auth.uid(), 'viewer')
    );

-- Compliance tables: admin and owner only.
create policy admin_reads_consents on compliance.consents
    for select to authenticated
    using (access.has_role(auth.uid(), 'admin') or access.has_role(auth.uid(), 'owner'));

create policy admin_reads_suppressions on compliance.suppressions
    for select to authenticated
    using (access.has_role(auth.uid(), 'admin') or access.has_role(auth.uid(), 'owner'));

-- A person can see their own role rows and their own grants. Nobody sees
-- anybody else's.
create policy own_roles on access.role_assignments
    for select to authenticated
    using (staff_id = auth.uid());

create policy own_grants on access.grants
    for select to authenticated
    using (staff_id = auth.uid());

-- Controls and autonomy are readable by owners and admins.
create policy staff_reads_controls on control.runtime_controls
    for select to authenticated
    using (access.has_role(auth.uid(), 'admin') or access.has_role(auth.uid(), 'owner'));

create policy staff_reads_autonomy on control.agent_autonomy
    for select to authenticated
    using (access.has_role(auth.uid(), 'admin') or access.has_role(auth.uid(), 'owner'));

-- inbound.records and access.sensitive_access_log intentionally have no
-- policies for authenticated callers. Only service_role reaches them.
