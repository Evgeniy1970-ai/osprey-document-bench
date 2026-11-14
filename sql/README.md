# Database schemas and roles

PostgreSQL (Supabase). Run as the database owner, in number order.

| File | What it creates |
|---|---|
| `01-ref.sql` | Schema `ref`: rule sets, folder types, document types, requirements. A rule set used by a run is locked by triggers. |
| `02-truth.sql` | Schema `truth`: the defect ledger of a test batch. Sealed before upload; immutable afterwards. |
| `03-doc.sql` | Schema `doc`: files by content fingerprint, Drive versions, the insert-only cache of model answers. |
| `04-rec.sql` | Schema `rec`: runs, inventories, findings, folder status, review decisions. |
| `05-roles.sql` | Roles `bench_pipeline` and `bench_score`. The pipeline cannot see `truth`. |
| `09-score.sql` | Schema `score`: scoring results, insert-only. Findings and folder status become write-once. |

Files 06–08, 10 and 11 (intake, recognition, report and review-screen functions) are part of the private pipeline and are not published. In the live database `09-score.sql` was applied after them; it depends only on the objects created by 01–05.

`05-roles.sql` contains placeholder passwords (`CHANGE_ME_…`). Replace them when running it; never commit real ones.

The isolation can be checked by hand after `05-roles.sql` — see the commented block at the end of that file.
