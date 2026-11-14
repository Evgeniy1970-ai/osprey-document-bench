-- Osprey Document Bench — schema ref: completeness rules
-- Source data: rules/*.csv (loaded by a separate loader).
-- Run as the database owner. Roles and grants live in a separate file.

create schema if not exists ref;

-- Warning tiers: one-dimensional, non-empty, positive, strictly descending (90, 60, 30).
-- NULL is allowed here; the columns decide whether NULL is permitted.
create or replace function ref.valid_tiers(t int[])
returns boolean
language sql
immutable
as $$
    select t is null or (
        array_ndims(t) = 1
        and cardinality(t) > 0
        and array_position(t, null) is null
        and not exists (
            select 1
            from unnest(t) with ordinality as a(v, i)
            where v <= 0
               or (i > 1 and v >= t[i - 1])
        )
    )
$$;

-- A complete, versioned set of rules. locked_at is set when the first run uses it;
-- after that the set and all its rows are read-only (see triggers below).
create table ref.rule_sets (
    id                     bigint generated always as identity primary key,
    code                   text        not null,
    version                int         not null check (version > 0),
    name                   text        not null,
    default_warning_tiers  int[]       not null check (ref.valid_tiers(default_warning_tiers)),
    notes                  text,
    created_at             timestamptz not null default now(),
    locked_at              timestamptz,
    unique (code, version)
);

-- Folder types per rule set; the Drive parent folder name identifies the type.
create table ref.folder_types (
    id                   bigint generated always as identity primary key,
    rule_set_id          bigint not null references ref.rule_sets (id),
    code                 text   not null check (code ~ '^[a-z][a-z0-9_]*$'),
    name                 text   not null,
    drive_parent_folder  text   not null check (length(trim(drive_parent_folder)) > 0),
    unique (rule_set_id, code),
    unique (rule_set_id, drive_parent_folder),
    unique (rule_set_id, id)              -- target for composite FK from requirements
);

-- Document types per rule set. description is what the model sees when classifying.
create table ref.document_types (
    id                  bigint generated always as identity primary key,
    rule_set_id         bigint not null references ref.rule_sets (id),
    code                text   not null check (code ~ '^[A-Z][A-Z0-9]*$'),
    name                text   not null,
    description         text   not null check (length(trim(description)) > 0),
    expiry_kind         text   not null check (expiry_kind in
                            ('printed_expiry', 'from_issue_date', 'optional_expiry', 'none')),
    validity_months     int    check (validity_months > 0),
    warning_tiers       int[]  check (ref.valid_tiers(warning_tiers)),   -- NULL = rule-set default
    filename_code       text   not null check (filename_code ~ '^[A-Z][A-Z0-9]*$'),
    -- a period exists if and only if the expiry is computed from the issue date
    check ((expiry_kind = 'from_issue_date') = (validity_months is not null)),
    -- nothing to warn about on a document that does not expire
    check (warning_tiers is null or expiry_kind <> 'none'),
    unique (rule_set_id, code),
    unique (rule_set_id, filename_code),
    unique (rule_set_id, id)
);

-- Which document type is required in which folder type.
-- Composite FKs keep both sides inside the same rule set.
create table ref.requirements (
    rule_set_id       bigint not null,
    folder_type_id    bigint not null,
    document_type_id  bigint not null,
    primary key (folder_type_id, document_type_id),
    foreign key (rule_set_id, folder_type_id)   references ref.folder_types   (rule_set_id, id),
    foreign key (rule_set_id, document_type_id) references ref.document_types (rule_set_id, id)
);

-- Locked rule sets are immutable. A change means a new version.
create or replace function ref.guard_locked()
returns trigger
language plpgsql
as $$
begin
    if tg_table_name = 'rule_sets' then
        if old.locked_at is not null then
            raise exception 'rule set %/v% is locked (used by a run); create a new version',
                old.code, old.version;
        end if;
    else
        if tg_op in ('UPDATE', 'DELETE') and exists (
            select 1 from ref.rule_sets where id = old.rule_set_id and locked_at is not null
        ) then
            raise exception 'rule set % is locked; create a new version', old.rule_set_id;
        end if;
        if tg_op in ('INSERT', 'UPDATE') and exists (
            select 1 from ref.rule_sets where id = new.rule_set_id and locked_at is not null
        ) then
            raise exception 'rule set % is locked; create a new version', new.rule_set_id;
        end if;
    end if;
    return case when tg_op = 'DELETE' then old else new end;
end
$$;

-- TRUNCATE skips row triggers, so block it while any locked set exists.
create or replace function ref.guard_truncate()
returns trigger
language plpgsql
as $$
begin
    if exists (select 1 from ref.rule_sets where locked_at is not null) then
        raise exception 'cannot truncate %: locked rule sets exist', tg_table_name;
    end if;
    return null;
end
$$;

create trigger rule_sets_guard      before update or delete           on ref.rule_sets      for each row execute function ref.guard_locked();
create trigger folder_types_guard   before insert or update or delete on ref.folder_types   for each row execute function ref.guard_locked();
create trigger document_types_guard before insert or update or delete on ref.document_types for each row execute function ref.guard_locked();
create trigger requirements_guard   before insert or update or delete on ref.requirements   for each row execute function ref.guard_locked();

create trigger rule_sets_no_truncate      before truncate on ref.rule_sets      for each statement execute function ref.guard_truncate();
create trigger folder_types_no_truncate   before truncate on ref.folder_types   for each statement execute function ref.guard_truncate();
create trigger document_types_no_truncate before truncate on ref.document_types for each statement execute function ref.guard_truncate();
create trigger requirements_no_truncate   before truncate on ref.requirements   for each statement execute function ref.guard_truncate();

comment on schema ref is 'Completeness rules: rule sets, folder types, document types, requirements. Read-only for the pipeline.';
comment on column ref.rule_sets.locked_at is 'Set when the first run uses this rule set; afterwards the set is immutable.';
comment on column ref.document_types.description is 'Plain-language description shown to the model when it classifies a document.';
comment on column ref.document_types.warning_tiers is 'Days before expiry, strictly descending. NULL means the rule set default.';
