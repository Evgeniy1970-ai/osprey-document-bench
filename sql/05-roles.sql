-- =====================================================================
-- Osprey Document Bench — roles and permissions
--
-- This is the point of splitting the schemas. If the pipeline connects as a
-- role that can see truth, every earlier file is decoration.
--
--   bench_pipeline  n8n, recognition, checks, review screen. Reads ref, writes doc and rec.
--                   Cannot see truth. Cannot write ref (locks a rule set only through
--                   ref.lock_rule_set, called by the trigger on rec.runs).
--   bench_score     scoring. Reads everything, writes only score.
--
-- The database owner (postgres) is used only by the rules loader and the generator.
--
-- BEFORE RUNNING: replace both CHANGE_ME passwords in the Supabase SQL editor.
-- Do not save the real passwords into this file: it lives in the repository.
--
-- Requires 01-ref.sql to 04-rec.sql.
-- =====================================================================

create role bench_pipeline login password 'CHANGE_ME_PIPELINE';
create role bench_score    login password 'CHANGE_ME_SCORE';
-- COMMENT ON ROLE is not used: on Supabase the postgres role is not a superuser.

create schema if not exists score;
comment on schema score is 'Metrics per run. Written by bench_score only.';

-- ---------------------------------------------------------------------
-- Pipeline: reads ref, writes doc and rec, never deletes
-- ---------------------------------------------------------------------
grant usage on schema ref, doc, rec to bench_pipeline;

grant select on all tables in schema ref to bench_pipeline;
grant execute on function ref.lock_rule_set(bigint) to bench_pipeline;

grant select, insert, update on doc.files, doc.drive_items to bench_pipeline;
grant select, insert         on doc.answers             to bench_pipeline;   -- the cache is insert-only

grant select, insert, update on rec.runs, rec.inventory_folders, rec.inventory_files,
                                rec.findings, rec.folder_status to bench_pipeline;
grant select, insert         on rec.decisions_log       to bench_pipeline;   -- insert-only

-- ---------------------------------------------------------------------
-- Ground truth: invisible to the pipeline
-- ---------------------------------------------------------------------
-- New schemas grant nothing by default, so bench_pipeline has no access even
-- without these lines. They are here so the intent survives any later edit.
revoke all on schema truth from public, bench_pipeline;
revoke all on all tables in schema truth from public, bench_pipeline;

-- ---------------------------------------------------------------------
-- Scoring: reads everything, writes only score
-- ---------------------------------------------------------------------
grant usage on schema ref, doc, rec, truth, score to bench_score;
grant select on all tables in schema ref, doc, rec, truth to bench_score;
grant select, insert, update, delete on all tables in schema score to bench_score;

-- ---------------------------------------------------------------------
-- Supabase API roles: no access to any bench schema
-- ---------------------------------------------------------------------
-- These schemas are not in "Exposed schemas", so the API cannot reach them anyway.
-- The revokes record the intent. Never add ref, doc, rec, truth or score to
-- Exposed schemas, and never connect the pipeline with the service_role key.
do $$
declare
    r text;
begin
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = r) then
            execute format('revoke all on schema ref, doc, rec, truth, score from %I', r);
            execute format('revoke all on all tables in schema ref, doc, rec, truth, score from %I', r);
        end if;
    end loop;
end
$$;

-- ---------------------------------------------------------------------
-- Tables created later
-- ---------------------------------------------------------------------
alter default privileges in schema ref   grant select on tables to bench_pipeline, bench_score;
alter default privileges in schema doc   grant select on tables to bench_score;
alter default privileges in schema rec   grant select on tables to bench_score;
alter default privileges in schema truth grant select on tables to bench_score;
alter default privileges in schema score grant select, insert, update, delete on tables to bench_score;
-- New doc and rec tables get pipeline rights explicitly, table by table, in their own files:
-- a blanket default would hand insert/update on an insert-only table by accident.

-- ---------------------------------------------------------------------
-- Isolation check: run as the owner after this file.
-- Each line must fail with "permission denied".
-- ---------------------------------------------------------------------
-- set role bench_pipeline;
-- select count(*) from truth.defects;                 -- permission denied for schema truth
-- update ref.document_types set name = name;          -- permission denied for table document_types
-- delete from rec.findings;                           -- permission denied for table findings
-- reset role;
