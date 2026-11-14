-- =====================================================================
-- Osprey Document Bench — schema truth: the ground truth of a batch
--
-- Written by the generator, as the database owner. The pipeline has no access
-- to this schema (see the roles file). If it ever can read truth, every figure
-- of every run becomes worthless, and nothing in the figures would show it.
--
-- Life of a batch:
--   1. the generator inserts batch, persons, files, defects, expected findings, controls;
--   2. it seals the batch (sealed_at) — from then on nothing in it can be added,
--      changed or deleted;
--   3. only then it uploads to Drive and records each upload in truth.uploads.
-- So the ledger is frozen before anyone can look at Drive.
--
-- Requires 01-ref.sql.
-- =====================================================================

create schema if not exists truth;
comment on schema truth is
    'Ground truth of the batch. Read by scoring only. The pipeline must never reach it.';

-- ---------------------------------------------------------------------
-- Defect codes
-- ---------------------------------------------------------------------
create table truth.defect_codes (
    code        text primary key,
    level       text    not null check (level in ('completeness', 'warning', 'naming')),
    headline    boolean not null,
    description text    not null
);

comment on column truth.defect_codes.headline is
    'Counted in the headline N/M. NONSTANDARD_NAME is scored separately: dozens of easy cases would inflate it.';

insert into truth.defect_codes (code, level, headline, description) values
    ('MISSING',          'completeness', true,  'A required document is absent'),
    ('EXPIRED_PRINTED',  'completeness', true,  'Printed expiry date before the audit date'),
    ('EXPIRED_COMPUTED', 'completeness', true,  'Issue date + validity period before the audit date'),
    ('EXPIRED_CONTRACT', 'completeness', true,  'A fixed-term contract has ended'),
    ('WRONG_PERSON',     'completeness', true,  'Right document type, another person''s name'),
    ('FOREIGN_DOCUMENT', 'completeness', true,  'A file not in the rule set''s list'),
    ('EXPIRING_SOON',    'warning',      true,  'Expiry inside a warning tier'),
    ('MISLEADING_NAME',  'naming',       true,  'File-name code differs from the content'),
    ('NONSTANDARD_NAME', 'naming',       false, 'File name off the standard, content correct');

-- ---------------------------------------------------------------------
-- Batches
-- ---------------------------------------------------------------------
create table truth.batches (
    code               text primary key,
    rule_set_id        bigint      not null references ref.rule_sets (id),
    reference_date     date        not null,
    defect_seed        bigint      not null,
    presentation_seed  bigint      not null,
    generator_version  text        not null,
    created_at         timestamptz not null default now(),
    sealed_at          timestamptz,
    note               text,
    check (defect_seed <> presentation_seed)
);

comment on column truth.batches.reference_date is
    'Every date in the batch is built from it. It is also the default audit date of a run.';
comment on column truth.batches.defect_seed is
    'Seed of the generator that places defects.';
comment on column truth.batches.presentation_seed is
    'Seed of the separate generator that assigns template, scan/photo and file names. It knows nothing of defects.';
comment on column truth.batches.sealed_at is
    'Set once, before upload. After it the batch is immutable; only uploads may be recorded.';

-- ---------------------------------------------------------------------
-- Persons: one per folder
-- ---------------------------------------------------------------------
create table truth.persons (
    batch_code      text   not null references truth.batches (code),
    person_number   text   not null check (person_number ~ '^(CG|CL)-[0-9]{4}$'),
    folder_type_id  bigint not null references ref.folder_types (id),
    given_name      text   not null,
    surname         text   not null,
    date_of_birth   date   not null,
    folder_name     text   not null,
    primary key (batch_code, person_number)
);

-- ---------------------------------------------------------------------
-- Files: every file of the batch, defective or clean
-- ---------------------------------------------------------------------
create table truth.files (
    batch_code        text    not null,
    file_id           text    not null,
    person_number     text    not null,
    sha256            char(64) not null check (sha256 ~ '^[0-9a-f]{64}$'),
    file_name         text    not null,
    location          text    not null check (location in ('main', 'archive')),
    mime_type         text    not null check (mime_type in ('application/pdf', 'image/jpeg', 'image/png')),
    document_type_id  bigint  references ref.document_types (id),   -- what the file really is
    foreign_kind      text,                                          -- set only for files not in the list
    template          text    not null,
    rendition         text    not null check (rendition in ('pdf_text', 'scan', 'photo')),
    pages             int     not null check (pages > 0),
    name_printed      text,                                          -- the name as it appears in the document
    name_person       text,                                          -- whose name it is: the folder's person or former staff
    name_variant      boolean not null default false,                -- same person, written differently
    degradation       text    check (degradation in ('light', 'medium')),
    drive_path        text    not null,                              -- path inside the uploaded tree
    issue_date        date,
    expiry_date       date,                                          -- last valid day: printed or computed
    open_ended        boolean,                                       -- optional_expiry: explicitly no end date
    primary key (batch_code, file_id),
    unique (batch_code, sha256),
    unique (batch_code, drive_path),
    foreign key (batch_code, person_number) references truth.persons (batch_code, person_number),
    check ((document_type_id is null) <> (foreign_kind is null)),
    check ((rendition = 'pdf_text') = (degradation is null)),
    check (not (open_ended and expiry_date is not null))
);

comment on column truth.files.document_type_id is
    'What the document really is, regardless of its file name. NULL for foreign documents.';
comment on column truth.files.expiry_date is
    'True last valid day. For from_issue_date types computed by the date rule (issue + period - 1 day).';
comment on column truth.files.name_person is
    'Person number whose name is printed. For WRONG_PERSON it is a former staff member (FS-...), who has no folder.';
comment on column truth.files.name_variant is
    'The person''s own name written differently (case, order, diacritics). '
    'A wrong-person finding on such a file is a false alarm.';

create index files_by_person on truth.files (batch_code, person_number);

-- ---------------------------------------------------------------------
-- Defect ledger
-- ---------------------------------------------------------------------
create table truth.defects (
    id                bigint generated always as identity primary key,
    batch_code        text    not null,
    code              text    not null references truth.defect_codes (code),
    person_number     text    not null,
    document_type_id  bigint  references ref.document_types (id),
    file_id           text,
    boundary          boolean not null default false,
    tier              int     check (tier > 0),
    note              text,
    foreign key (batch_code, person_number) references truth.persons (batch_code, person_number),
    foreign key (batch_code, file_id)       references truth.files   (batch_code, file_id),
    -- folder-level defects have no file; every other defect lives in one
    check ((code = 'MISSING') = (file_id is null)),
    -- only a foreign document has no type from the list
    check ((code = 'FOREIGN_DOCUMENT') = (document_type_id is null)),
    -- a tier belongs to expiring-soon and only to it
    check ((code = 'EXPIRING_SOON') = (tier is not null))
);

comment on column truth.defects.boundary is
    'Sits exactly on a boundary: expires today, expired yesterday, exactly 90 or 60 days left.';

create index defects_by_code   on truth.defects (batch_code, code);
create index defects_by_person on truth.defects (batch_code, person_number);
create index defects_by_file   on truth.defects (batch_code, file_id);

-- At most one defect per (folder, document type), except naming notes which
-- sit on top of a file without changing what the folder holds.
create unique index defects_one_per_folder_type
    on truth.defects (batch_code, person_number, document_type_id)
    where code not in ('NONSTANDARD_NAME', 'MISLEADING_NAME', 'FOREIGN_DOCUMENT');

-- ---------------------------------------------------------------------
-- Expected findings: what each defect must produce
-- ---------------------------------------------------------------------
create table truth.expected_findings (
    id                bigint generated always as identity primary key,
    defect_id         bigint not null references truth.defects (id),
    kind              text   not null check (kind in (
                          'missing', 'expired', 'expiring_soon', 'wrong_person', 'foreign_document',
                          'misleading_name', 'nonstandard_name', 'needs_review',
                          'unsupported_format', 'move_to_archive')),
    document_type_id  bigint references ref.document_types (id),
    tier              int    check (tier > 0),
    on_file           boolean not null,          -- true: the finding is on the defect's file; false: on the folder
    unique (defect_id, kind),
    check ((kind = 'expiring_soon') = (tier is not null))
);

comment on table truth.expected_findings is
    'One defect can require several findings: WRONG_PERSON expects wrong_person on the file '
    'and missing for the person''s own document.';

-- ---------------------------------------------------------------------
-- Controls: near-misses where the right answer is no finding at all
-- ---------------------------------------------------------------------
create table truth.controls (
    id          bigint generated always as identity primary key,
    batch_code  text not null,
    kind        text not null check (kind in (
                    'outside_tier', 'own_tiers', 'valid_fixed_term', 'archived_version', 'name_variant')),
    file_id     text not null,
    note        text,
    foreign key (batch_code, file_id) references truth.files (batch_code, file_id),
    unique (batch_code, file_id)
);

comment on column truth.controls.kind is
    'outside_tier: 91 days left; own_tiers: care plan with 31 days left (its tiers are 30/14); '
    'valid_fixed_term: fixed-term contract still running; archived_version: superseded version in _Archive; '
    'name_variant: name written with or without diacritics.';

-- ---------------------------------------------------------------------
-- Uploads: insert-only, recorded after the batch is sealed
-- ---------------------------------------------------------------------
create table truth.uploads (
    batch_code     text        not null,
    file_id        text        not null,
    drive_file_id  text        not null unique,
    upload_order   int         not null check (upload_order > 0),
    uploaded_at    timestamptz not null default now(),
    primary key (batch_code, file_id),
    unique (batch_code, upload_order),
    foreign key (batch_code, file_id) references truth.files (batch_code, file_id)
);

comment on table truth.uploads is
    'Drive file IDs exist only after upload, so they live here and the ledger can be sealed first. '
    'upload_order and uploaded_at show that every file reached Drive after the batch was sealed.';

-- ---------------------------------------------------------------------
-- Expected folder status: computed, never stored
-- ---------------------------------------------------------------------
create view truth.expected_folder_status as
select
    p.batch_code,
    p.person_number,
    p.folder_name,
    case when exists (
        select 1
        from truth.defects d
        join truth.defect_codes c on c.code = d.code
        where d.batch_code = p.batch_code
          and d.person_number = p.person_number
          and c.level = 'completeness'
    ) then 'incomplete' else 'complete' end as expected_status,
    (select count(*) from truth.defects d
      join truth.defect_codes c on c.code = d.code
      where d.batch_code = p.batch_code and d.person_number = p.person_number and c.headline) as headline_defects
from truth.persons p;

comment on view truth.expected_folder_status is
    'Incomplete if the folder holds any completeness-level defect. Derived from the ledger so the two cannot drift.';

-- ---------------------------------------------------------------------
-- Immutability
-- ---------------------------------------------------------------------

-- No row of truth is ever updated or deleted. Re-generating a batch is a
-- deliberate act (drop and re-create the schema in a scratch database),
-- not a statement that slips through.
create or replace function truth.deny_change()
returns trigger
language plpgsql
as $$
begin
    raise exception 'truth is immutable: % on % is not allowed. Changing the ground truth after a run changes its result.',
        tg_op, tg_table_name;
end
$$;

-- Batches: the only allowed change is sealing, once.
create or replace function truth.guard_batch()
returns trigger
language plpgsql
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'truth is immutable: a batch cannot be deleted';
    end if;
    if old.sealed_at is not null then
        raise exception 'batch % is sealed since %; it cannot be changed', old.code, old.sealed_at;
    end if;
    if new.sealed_at is null
       or (new.code, new.rule_set_id, new.reference_date, new.defect_seed, new.presentation_seed,
           new.generator_version, new.created_at, new.note)
          is distinct from
          (old.code, old.rule_set_id, old.reference_date, old.defect_seed, old.presentation_seed,
           old.generator_version, old.created_at, old.note) then
        raise exception 'batch %: the only allowed change is setting sealed_at', old.code;
    end if;
    return new;
end
$$;

-- Content of a sealed batch cannot grow.
create or replace function truth.guard_sealed_insert()
returns trigger
language plpgsql
as $$
declare
    b text;
begin
    if tg_table_name = 'expected_findings' then
        select d.batch_code into b from truth.defects d where d.id = new.defect_id;
    else
        b := new.batch_code;
    end if;
    if exists (select 1 from truth.batches where code = b and sealed_at is not null) then
        raise exception 'batch % is sealed; nothing can be added to %', b, tg_table_name;
    end if;
    return new;
end
$$;

-- Uploads only after sealing.
create or replace function truth.guard_upload()
returns trigger
language plpgsql
as $$
begin
    if not exists (select 1 from truth.batches where code = new.batch_code and sealed_at is not null) then
        raise exception 'batch % is not sealed; seal the ledger before uploading', new.batch_code;
    end if;
    return new;
end
$$;

create trigger batches_guard before update or delete on truth.batches
    for each row execute function truth.guard_batch();

create trigger defect_codes_frozen      before update or delete on truth.defect_codes      for each row execute function truth.deny_change();
create trigger persons_frozen           before update or delete on truth.persons           for each row execute function truth.deny_change();
create trigger files_frozen             before update or delete on truth.files             for each row execute function truth.deny_change();
create trigger defects_frozen           before update or delete on truth.defects           for each row execute function truth.deny_change();
create trigger expected_findings_frozen before update or delete on truth.expected_findings for each row execute function truth.deny_change();
create trigger controls_frozen          before update or delete on truth.controls          for each row execute function truth.deny_change();
create trigger uploads_frozen           before update or delete on truth.uploads           for each row execute function truth.deny_change();

create trigger persons_sealed           before insert on truth.persons           for each row execute function truth.guard_sealed_insert();
create trigger files_sealed             before insert on truth.files             for each row execute function truth.guard_sealed_insert();
create trigger defects_sealed           before insert on truth.defects           for each row execute function truth.guard_sealed_insert();
create trigger expected_findings_sealed before insert on truth.expected_findings for each row execute function truth.guard_sealed_insert();
create trigger controls_sealed          before insert on truth.controls          for each row execute function truth.guard_sealed_insert();

create trigger uploads_after_seal before insert on truth.uploads
    for each row execute function truth.guard_upload();

-- TRUNCATE skips row triggers.
create or replace function truth.deny_truncate()
returns trigger
language plpgsql
as $$
begin
    raise exception 'truth is immutable: TRUNCATE on % is not allowed', tg_table_name;
end
$$;

create trigger batches_no_truncate           before truncate on truth.batches           for each statement execute function truth.deny_truncate();
create trigger defect_codes_no_truncate      before truncate on truth.defect_codes      for each statement execute function truth.deny_truncate();
create trigger persons_no_truncate           before truncate on truth.persons           for each statement execute function truth.deny_truncate();
create trigger files_no_truncate             before truncate on truth.files             for each statement execute function truth.deny_truncate();
create trigger defects_no_truncate           before truncate on truth.defects           for each statement execute function truth.deny_truncate();
create trigger expected_findings_no_truncate before truncate on truth.expected_findings for each statement execute function truth.deny_truncate();
create trigger controls_no_truncate          before truncate on truth.controls          for each statement execute function truth.deny_truncate();
create trigger uploads_no_truncate           before truncate on truth.uploads           for each statement execute function truth.deny_truncate();
