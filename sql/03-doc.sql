-- =====================================================================
-- Osprey Document Bench — schema doc: what arrived and what the model read
--
-- Lives outside runs. A file's content is stored once, whatever run or Drive
-- location it came from; a model answer is stored once per reading setup.
--
--   doc.files        one row per distinct content (SHA-256)
--   doc.drive_items  what n8n saw on Drive: one row per (Drive file, content version)
--   doc.answers      model answers, cached by what determines them
--
-- Written by n8n (files, drive_items) and Python (answers, page facts),
-- both as bench_pipeline. Requires 01-ref.sql.
-- =====================================================================

create schema if not exists doc;
comment on schema doc is 'Incoming files and model answers. Lives outside runs.';

-- ---------------------------------------------------------------------
-- Content: one row per distinct file content
-- ---------------------------------------------------------------------
create table doc.files (
    sha256          char(64)    primary key check (sha256 ~ '^[0-9a-f]{64}$'),
    storage_path    text        not null unique,     -- relative to the storage folder: ab/ab12...f9.pdf
    mime_type       text        not null,
    bytes           bigint      not null check (bytes > 0),
    page_count      int         check (page_count > 0),        -- filled by Python when it opens the file
    has_text_layer  boolean,                                    -- filled by Python
    first_seen_at   timestamptz not null default now(),
    check (storage_path = substr(sha256, 1, 2) || '/' || sha256 || '.' || split_part(storage_path, '.', 2))
);

comment on column doc.files.storage_path is
    'Path of the stored copy, built from the SHA-256, never from the file name: a name can lie, a fingerprint cannot.';

-- ---------------------------------------------------------------------
-- What n8n saw on Drive
-- ---------------------------------------------------------------------
create table doc.drive_items (
    id                 bigint generated always as identity primary key,
    drive_file_id      text        not null,
    sha256             char(64)    references doc.files (sha256),   -- NULL: native Google file, no content taken
    file_name          text        not null,
    mime_type          text        not null,
    parent_folder_id   text        not null,
    path               text        not null,                         -- from the bench root: Caregivers/CG-0042 .../x.pdf
    drive_created_at   timestamptz,
    drive_modified_at  timestamptz,
    first_seen_at      timestamptz not null default now(),
    unique nulls not distinct (drive_file_id, sha256)
);

comment on table doc.drive_items is
    'One row per version of a Drive file: the same Drive ID with new content is a new row, so every run '
    'knows exactly which version it read.';
comment on column doc.drive_items.drive_created_at is
    'Audit trail only. Neither checks nor the model read Drive times.';
comment on column doc.drive_items.sha256 is
    'NULL for native Google Docs/Sheets: phase 1 does not read them; they produce an unsupported-format finding.';

create index drive_items_by_file on doc.drive_items (drive_file_id);

-- ---------------------------------------------------------------------
-- Model answers: a cache keyed by everything that determines the answer
-- ---------------------------------------------------------------------
create table doc.answers (
    id               bigint generated always as identity primary key,
    sha256           char(64)    not null references doc.files (sha256),
    rule_set_id      bigint      not null references ref.rule_sets (id),  -- the type descriptions are in the prompt
    model            text        not null,
    prompt_version   text        not null,
    reader_version   text        not null,      -- how pages are prepared: resolution, page limit
    raw_response     jsonb       not null,
    doc_type_code    text        not null,      -- a code from the rule set, or 'other'
    name_as_written  text,
    issue_date       date,
    expiry_date      date,
    expiry_state     text        check (expiry_state in ('date_found', 'open_ended', 'not_found')),
    unreadable       boolean     not null default false,
    tokens_in        int,
    tokens_out       int,
    cost_usd         numeric(10, 6),
    duration_ms      int,
    created_at       timestamptz not null default now(),
    unique (sha256, rule_set_id, model, prompt_version, reader_version),
    check (expiry_state is null or (expiry_state = 'date_found') = (expiry_date is not null))
);

comment on table doc.answers is
    'A repeat run reuses the stored answer and reproduces the result exactly. A fresh model call is a '
    'deliberate act: a new prompt, reader, model or rule set means a new measurement, not random drift.';
comment on column doc.answers.reader_version is
    'Version of page preparation (resolution, pages sent). Without it, raising the resolution would '
    'silently reuse answers made at the old one.';
comment on column doc.answers.expiry_state is
    'For optional-expiry types only. not_found is never treated as open_ended: it goes to a person.';

-- The cache never changes: an answer that could be edited would make a repeat run meaningless.
create or replace function doc.deny_change()
returns trigger
language plpgsql
as $$
begin
    raise exception 'doc.answers is insert-only: % is not allowed. A new reading is a new row.', tg_op;
end
$$;

create trigger answers_insert_only before update or delete on doc.answers
    for each row execute function doc.deny_change();
