-- 01. Extensions and schemas
--
-- One schema per concern, so grants and policies can be reasoned about a
-- layer at a time instead of table by table.

create extension if not exists pgcrypto;

create schema if not exists inbound;     -- raw arrivals, treated as claims
create schema if not exists core;        -- validated business facts
create schema if not exists compliance;  -- consent and suppression
create schema if not exists access;      -- staff roles, grants, audit
create schema if not exists control;     -- kill switches and agent autonomy

-- Nothing is reachable by default. Each later file grants only what it needs.
revoke all on schema inbound, core, compliance, access, control from public;
