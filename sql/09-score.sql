-- =====================================================================
-- Osprey Document Bench — scoring: where the results go, and what they rest on
--
--   score.runs       one row per (run, scorer version): when, which batch, the summary figures
--   score.expected   one row per expected finding of the ledger: what became of it
--   score.defects    one row per defect: its outcome under the strict rule
--   score.findings   one row per finding of the run: what it counted as
--   score.folders    one row per person folder: expected vs actual status
--
-- Every table is keyed by (run, scorer version). The same version is written once;
-- changed scoring rules are a new version next to the old one, never an overwrite.
-- Both sides are frozen (the ledger is sealed, the findings are written once), so a
-- version always gives the same figures.
--
-- This file also closes two gaps that scoring depends on:
--
-- 1. rec.findings and rec.folder_status become insert-only. 05-roles.sql gave
--    bench_pipeline UPDATE on both. Nothing uses it (checks.py only inserts; review
--    decisions go to rec.decisions_log), but scoring reads these rows as fixed facts:
--    a finding rewritten after scoring would silently change what the figures mean.
--
-- 2. bench_pipeline must never read score. Its tables are derived from truth
--    (which file is defective, which defect was missed); reading them would get
--    round the isolation of truth from the side. 05-roles.sql grants nothing on
--    score to bench_pipeline; the revokes below record the intent.
--
-- Run as the database owner. Requires 01-ref.sql to 08-recognition.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Results
-- ---------------------------------------------------------------------
create table score.runs (
    run_id          bigint      not null references rec.runs (id),
    scorer_version  text        not null check (scorer_version ~ '^score-v[0-9]+$'),
    batch_code      text        not null references truth.batches (code),
    scored_at       timestamptz not null default now(),
    summary         jsonb       not null,
    primary key (run_id, scorer_version)
);

comment on table score.runs is
    'One row per scoring of a run. The same scorer version is written once; new rules mean a new version.';

-- Outcome of one expected finding of the ledger.
--   correct           same place, same kind, same document type, same tier (expiring_soon)
--   named_differently same place, another finding of the same family (content / naming)
--   to_person         the file got needs_review or unsupported_format instead
--   not_found         nothing on that place
create table score.expected (
    run_id               bigint not null,
    scorer_version       text   not null,
    expected_finding_id  bigint not null references truth.expected_findings (id),
    defect_id            bigint not null references truth.defects (id),
    outcome              text   not null check (outcome in
                             ('correct', 'named_differently', 'to_person', 'not_found')),
    finding_id           bigint references rec.findings (id),
    primary key (run_id, scorer_version, expected_finding_id),
    foreign key (run_id, scorer_version) references score.runs (run_id, scorer_version),
    check ((outcome = 'not_found') = (finding_id is null))
);

-- Outcome of one defect: correct only when every expected finding of it is correct.
create table score.defects (
    run_id          bigint  not null,
    scorer_version  text    not null,
    defect_id       bigint  not null references truth.defects (id),
    code            text    not null references truth.defect_codes (code),
    headline        boolean not null,
    boundary        boolean not null,
    outcome         text    not null check (outcome in
                        ('correct', 'named_differently', 'to_person', 'not_found')),
    primary key (run_id, scorer_version, defect_id),
    foreign key (run_id, scorer_version) references score.runs (run_id, scorer_version)
);

-- What one finding of the run counted as.
--   matched           closed an expected finding exactly
--   named_differently closed an expected finding loosely
--   to_person         needs_review / unsupported_format: work handed to a person, never an alarm
--   not_counted       neither credited nor counted (nonstandard_name on a file that is not
--                     the person's own listed document)
--   false_alarm       everything else
create table score.findings (
    run_id               bigint not null,
    scorer_version       text   not null,
    finding_id           bigint not null references rec.findings (id),
    kind                 text   not null,
    outcome              text   not null check (outcome in
                             ('matched', 'named_differently', 'to_person', 'not_counted', 'false_alarm')),
    expected_finding_id  bigint references truth.expected_findings (id),
    file_id              text,                -- the batch file it sits on; NULL for a folder finding
    control_kind         text,                -- set when the file is a control
    name_variant         boolean not null default false,
    primary key (run_id, scorer_version, finding_id),
    unique (run_id, scorer_version, expected_finding_id),   -- one finding closes one expected finding
    foreign key (run_id, scorer_version) references score.runs (run_id, scorer_version),
    check ((outcome in ('matched', 'named_differently')) = (expected_finding_id is not null))
);

-- One person folder: what the ledger says against what the run said.
--   correct           same status
--   called_complete   incomplete in the ledger, complete in the run: the error that matters most
--   review_only       complete in the ledger, incomplete in the run only because of a review:
--                     the permitted error
--   false_incomplete  complete in the ledger, incomplete in the run with a completeness finding
create table score.folders (
    run_id           bigint  not null,
    scorer_version   text    not null,
    person_number    text    not null,
    expected_status  text    not null check (expected_status in ('complete', 'incomplete')),
    actual_status    text    not null check (actual_status in ('complete', 'incomplete')),
    needs_review     boolean not null,
    outcome          text    not null check (outcome in
                         ('correct', 'called_complete', 'review_only', 'false_incomplete')),
    primary key (run_id, scorer_version, person_number),
    foreign key (run_id, scorer_version) references score.runs (run_id, scorer_version),
    check ((outcome = 'correct') = (expected_status = actual_status)),
    check (outcome <> 'called_complete'
           or (expected_status = 'incomplete' and actual_status = 'complete')),
    check (outcome not in ('review_only', 'false_incomplete')
           or (expected_status = 'complete' and actual_status = 'incomplete')),
    check (outcome <> 'review_only' or needs_review)
);

-- ---------------------------------------------------------------------
-- 2. Insert-only: score, rec.findings, rec.folder_status
-- ---------------------------------------------------------------------
create or replace function score.deny_change()
returns trigger
language plpgsql
as $$
begin
    raise exception '%.% is insert-only: % is not allowed. New scoring rules mean a new scorer version.',
        tg_table_schema, tg_table_name, tg_op;
end
$$;

create or replace function rec.deny_change_results()
returns trigger
language plpgsql
as $$
begin
    raise exception 'rec.% is insert-only: % is not allowed. Findings are written once per run; '
                    'a decision on a finding goes to rec.decisions_log.', tg_table_name, tg_op;
end
$$;

do $$
declare
    t text;
begin
    foreach t in array array['runs', 'expected', 'defects', 'findings', 'folders'] loop
        execute format('create trigger %I before update or delete on score.%I '
                       'for each row execute function score.deny_change()', t || '_insert_only', t);
        execute format('create trigger %I before truncate on score.%I '
                       'for each statement execute function score.deny_change()', t || '_no_truncate', t);
    end loop;
    foreach t in array array['findings', 'folder_status'] loop
        execute format('create trigger %I before update or delete on rec.%I '
                       'for each row execute function rec.deny_change_results()', t || '_insert_only', t);
        execute format('create trigger %I before truncate on rec.%I '
                       'for each statement execute function rec.deny_change_results()', t || '_no_truncate', t);
    end loop;
end
$$;

-- ---------------------------------------------------------------------
-- 3. Permissions
-- ---------------------------------------------------------------------
-- Scoring: reads everything (05-roles.sql), writes score by insert only.
-- 05-roles.sql set default privileges that hand UPDATE and DELETE on every new score table;
-- take them back here and for any later table.
grant  select, insert                   on all tables in schema score to bench_score;
revoke update, delete, truncate         on all tables in schema score from bench_score;
alter default privileges in schema score revoke update, delete on tables from bench_score;

-- Pipeline: findings and folder status are written once.
revoke update on rec.findings, rec.folder_status from bench_pipeline;

-- Pipeline: no access to score, ever.
revoke all on schema score from public, bench_pipeline;
revoke all on all tables in schema score from public, bench_pipeline;

do $$
declare
    r text;
begin
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = r) then
            execute format('revoke all on all tables in schema score from %I', r);
        end if;
    end loop;
end
$$;

commit;
