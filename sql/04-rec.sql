-- =====================================================================
-- Osprey Document Bench — schema rec: runs and their results
--
--   rec.runs               a run: kind, audit date, rule set, model, prompt, reader
--   rec.inventory_folders  the folders on Drive at the start of the run
--   rec.inventory_files    the file versions on Drive at the start of the run
--   rec.findings           what the checks found
--   rec.folder_status      Complete / Incomplete per person folder
--   rec.decisions_log      a person's decision on a finding (insert-only)
--
-- A run works from its inventory, not from live Drive: repeating it a month later
-- reads the same files, uses the same cached answers and gives the same result.
--
-- Written by n8n (runs, inventory) and Python (classification, findings, status),
-- both as bench_pipeline. Requires 01-ref.sql and 03-doc.sql.
-- =====================================================================

create schema if not exists rec;
comment on schema rec is 'Runs, inventories, findings, folder status, decisions.';

-- ---------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------
create table rec.runs (
    id              bigint generated always as identity primary key,
    kind            text        not null check (kind in ('debug', 'measured', 'incremental', 'daily')),
    rule_set_id     bigint      not null references ref.rule_sets (id),
    audit_date      date        not null,
    model           text        not null,
    prompt_version  text        not null,
    reader_version  text        not null,
    batch_code      text,                    -- for bench runs; plain text: the pipeline cannot see truth
    settings        jsonb       not null default '{}',
    status          text        not null default 'running' check (status in ('running', 'done', 'failed')),
    started_at      timestamptz not null default now(),
    finished_at     timestamptz,
    error           text,
    note            text,
    check ((status = 'running') = (finished_at is null))
);

comment on column rec.runs.audit_date is
    'A parameter of the run, not the system clock: otherwise "expired" changes overnight and a repeat '
    'gives a different answer.';

-- The first run on a rule set locks it. The pipeline has no write access to ref,
-- so the lock goes through a SECURITY DEFINER function owned by the database owner.
create or replace function ref.lock_rule_set(p_rule_set_id bigint)
returns void
language sql
security definer
set search_path = pg_catalog, ref
as $$
    update ref.rule_sets set locked_at = now() where id = p_rule_set_id and locked_at is null;
$$;
revoke all on function ref.lock_rule_set(bigint) from public;

create or replace function rec.lock_on_run()
returns trigger
language plpgsql
as $$
begin
    perform ref.lock_rule_set(new.rule_set_id);
    return new;
end
$$;

create trigger runs_lock_rule_set after insert on rec.runs
    for each row execute function rec.lock_on_run();

-- ---------------------------------------------------------------------
-- Inventory: Drive as it was at the start of the run
-- ---------------------------------------------------------------------
create table rec.inventory_folders (
    run_id            bigint not null references rec.runs (id),
    drive_folder_id   text   not null,
    name              text   not null,
    parent_folder_id  text,                      -- NULL for the bench root
    path              text   not null,           -- from the bench root; '' for the root itself
    -- classified by code from the rules:
    role              text   check (role in ('root', 'type_parent', 'person', 'archive', 'other')),
    folder_type_id    bigint references ref.folder_types (id),
    person_number     text,
    primary key (run_id, drive_folder_id),
    check (role is distinct from 'person' or (folder_type_id is not null and person_number is not null))
);

comment on table rec.inventory_folders is
    'Folders are recorded, not only files: a person folder with no files at all must still be seen, '
    'or "every document missing" would never be reported.';

create table rec.inventory_files (
    run_id           bigint not null references rec.runs (id),
    drive_item_id    bigint not null references doc.drive_items (id),
    drive_file_id    text   not null,            -- repeated from drive_items: one version per Drive file per run
    drive_folder_id  text   not null,
    -- classified by code:
    location         text   check (location in ('main', 'archive', 'unexpected')),
    person_number    text,
    primary key (run_id, drive_item_id),
    unique (run_id, drive_file_id),
    foreign key (run_id, drive_folder_id) references rec.inventory_folders (run_id, drive_folder_id)
);

comment on column rec.inventory_files.location is
    'unexpected: directly in Caregivers, in a subfolder other than _Archive, or outside any person folder. '
    'Never skipped silently: such a file produces a needs-review finding.';

-- ---------------------------------------------------------------------
-- Findings and folder status
-- ---------------------------------------------------------------------
create table rec.findings (
    id                bigint generated always as identity primary key,
    run_id            bigint not null references rec.runs (id),
    person_number     text,                      -- NULL only for a file outside any person folder
    kind              text   not null check (kind in (
                          'missing', 'expired', 'expiring_soon', 'wrong_person', 'foreign_document',
                          'misleading_name', 'nonstandard_name', 'needs_review',
                          'unsupported_format', 'move_to_archive')),
    document_type_id  bigint references ref.document_types (id),
    drive_item_id     bigint references doc.drive_items (id),    -- NULL for missing: there is no file
    answer_id         bigint references doc.answers (id),        -- the reading the finding rests on
    tier              int    check (tier > 0),
    detail            jsonb  not null default '{}',              -- dates, reason, suggested file name
    created_at        timestamptz not null default now(),
    check ((kind = 'expiring_soon') = (tier is not null)),
    check (kind <> 'missing' or drive_item_id is null)
);

create index findings_by_run on rec.findings (run_id, person_number);

create table rec.folder_status (
    run_id          bigint  not null references rec.runs (id),
    person_number   text    not null,
    folder_type_id  bigint  not null references ref.folder_types (id),
    status          text    not null check (status in ('complete', 'incomplete')),
    needs_review    boolean not null default false,
    primary key (run_id, person_number),
    -- Complete only when the system is sure (see docs/architecture.md, section 5)
    check (not (status = 'complete' and needs_review))
);

-- ---------------------------------------------------------------------
-- Decisions: insert-only
-- ---------------------------------------------------------------------
create table rec.decisions_log (
    id          bigint generated always as identity primary key,
    finding_id  bigint      not null references rec.findings (id),
    decision    text        not null check (decision in ('confirmed', 'rejected', 'corrected')),
    note        text,
    decided_by  text        not null,
    decided_at  timestamptz not null default now()
);

create or replace function rec.deny_change()
returns trigger
language plpgsql
as $$
begin
    raise exception 'rec.decisions_log is insert-only: % is not allowed. A changed decision is a new row.', tg_op;
end
$$;

create trigger decisions_insert_only before update or delete on rec.decisions_log
    for each row execute function rec.deny_change();
