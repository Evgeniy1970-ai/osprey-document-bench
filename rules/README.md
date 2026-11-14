# Rules — source tables

Source of the `ref` schema. One CSV per table, UTF-8, comma-separated, loaded into Postgres as is.

| File | Table |
|---|---|
| `rule_sets.csv` | `ref.rule_sets` |
| `folder_types.csv` | `ref.folder_types` |
| `document_types.csv` | `ref.document_types` |
| `requirements.csv` | `ref.requirements` |

A rule set that has been used by a run is never edited. A change means a new version: copy the rows, raise `version`, edit the copy.

## Conventions

**Expiry kinds:** `printed_expiry`, `from_issue_date`, `optional_expiry`, `none`.

**Warning tiers:** days before expiry, separated by `;`. Empty in `document_types.csv` means the rule set's default.

**Last valid day.** The expiry date is the last day a document is valid. Valid until 14 March means expired from 15 March.

**Computed expiry (`from_issue_date`):** issue date + `validity_months` − 1 day.
Issued 2025-03-14, 36 months → last valid day 2028-03-13.

**Month end.** If the target month has no such day, take its last day, then subtract one day.
Issued 2025-08-31, 6 months → 2026-02-28 → last valid day 2026-02-27.
(This is what `dateutil.relativedelta` does.)

**Descriptions** are what the model sees when it classifies a document. Each says what the document is, what it is not confused with (only where confusion is likely), and which date it shows. The batch generator's templates must match them.

The document lists are illustrative, not legal requirements.
