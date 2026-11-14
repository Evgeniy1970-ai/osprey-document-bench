# Osprey Document Bench — Architecture

Public edition · November 2026

> Osprey finds what is missing, expired or misfiled in folders of documents — and a bench measures how much of it Osprey actually finds.

---

## 1. The problem

Organisations that employ or serve people keep a folder per person: identity documents, contracts, certificates, training records, care plans, consent forms. Some of these must be present, some expire, some must be renewed on a fixed cycle. Checking them by hand is slow, and the expensive mistake is not an incomplete folder — it is an incomplete folder that someone believed was complete.

Osprey reads every document in a set of Google Drive folders, works out what each one is from its content, checks it against the list of documents the organisation requires, and reports, per person, what is missing, expired, expiring soon, belongs to someone else or is misnamed.

## 2. Why a measurement bench

An ordinary audit tool reports: "12 folders are incomplete." A bench answers a different question: of all the problems that are really there, what share did the system find, what share did it miss, and how often did it raise a false alarm?

Answering that requires knowing the right answer in advance. So the project is built backwards. First comes a batch of synthetic folders with defects planted on purpose and recorded in a ledger. Only then does the system run, and it is measured against that ledger. The denominator is known before the first run.

**The data is synthetic, and that is stated openly.** All names, documents and data in the bench are fictional.

## 3. Results

Two batches, each of 70 person folders (40 caregivers, 30 clients), 393 files and 110 planted defects.

| | Batch 1 | Batch 2 |
|---|---|---|
| Relation to the system | the batch the system was built against | generated **after** the system was frozen, with 13 document layouts it had never seen |
| Defects found and named correctly | **110 of 110** | **109 of 110** — the remaining one was handed to a person, not missed |
| Incomplete folders reported as complete | **0** | **0** |
| False alarms | 0 | 4 |
| Findings handed to a person for review | 1 | 2 |
| Cost of reading the whole batch | $4.95 | $4.86 |

**Together: 219 of 220 defects, and no incomplete folder ever reported as complete.** Every error the system made was either handed to a person or was a false alarm — extra work for a reviewer, never a silent miss.

A repeat run of batch 1 produced the same 207 findings line for line, at a reading cost of $0: model answers are cached by file content and version.

### What these figures do and do not say

They are exact for these two batches: every finding was matched file by file against the ledger, not just counted. Batch 1 was the batch the rules were developed against, so a perfect score there shows the rules fit it. Batch 2 is the real test — generated after the code was frozen and tagged, with new document layouts, new dates and new random seeds. A client's documents will differ from both, which is why every deployment starts with a measured run on the client's own folders.

## 4. Principles

1. **The model reads, the code counts.** The language model extracts what is printed on a page — type, name, dates. Every comparison, every date calculation and every decision is ordinary code. A run that cannot be repeated measures nothing.
2. **The answer key is locked away by the database.** The pipeline runs under a database role that cannot read the defect ledger. Postgres enforces this, not good intentions.
3. **The original is never altered.** The system does not rename, move or edit anyone's files. It suggests; people act.
4. **Nothing but the defect predicts the defect.** File names, processing order, upload times and other metadata carry no information about where defects were planted — and this is checked statistically, not assumed.
5. **Synthetic data, said out loud.**
6. **No company names in anything published**, not even invented ones.

## 5. What the system checks

### Required documents come from the client

The system does not know what any law requires and does not claim to. It reports what is missing from the list **the organisation** defined as required.

The first rule set is for home care (lists in `rules/`). They are **illustrative**, not legal requirements:

| Caregiver folder | Client folder |
|---|---|
| Identity document | Service agreement |
| Employment contract | Care plan |
| Background check certificate | Risk assessment |
| Care qualification certificate | Consent form |
| First aid certificate | Emergency contact form |
| Annual training record | |

The rule model is domain-neutral. Construction (worker, site), logistics (driver, vehicle) or staffing plug in as new rows in the rule tables, not new code. Each document type carries a plain-language description; that description is what the model uses to recognise the document. A client in another industry writes their own descriptions.

### Four kinds of expiry

| Kind | What the document shows | Who does what |
|---|---|---|
| printed expiry | an expiry date | the model reads the date; code compares |
| from issue date | an issue date only | the model reads the issue date; code adds the period from the rules |
| optional expiry | an end date, or an explicit open-ended term | the model says which of three: date found, open-ended, not found |
| none | nothing to expire | presence only |

"Not found" is never treated as "open-ended". It goes to a person. Otherwise a missed date would silently turn an expired fixed-term contract into a valid one.

**Dates are exact to the day.** The expiry date is the last valid day. A certificate issued on 14 March 2025 and valid for three years is valid through 13 March 2028. Month ends follow a fixed rule. The audit date is a parameter of the run, not the system clock, so a repeat a month later gives the same answer.

**Warnings come in tiers** — by default 90, 60 and 30 days before expiry, adjustable per document type. A care plan reviewed every six months uses 30 and 14 days; with a 90-day tier it would be flagged for half its life, and a warning that is always on stops being read.

### Findings

| Finding | What it means | Folder status |
|---|---|---|
| Missing | a required document is not in the folder | Incomplete |
| Expired | the document is past its last valid day | Incomplete |
| Wrong person | right type of document, someone else's name | Incomplete |
| Foreign document | a file that is not on the list | Incomplete |
| Needs review | the system is not sure (unreadable page, date not found, file in an unexpected place, unsupported format) | Needs review |
| Expiring soon | inside a warning tier | — |
| Misleading name | the file name says one document, the content is another | — |
| Non-standard name | the right document under a name like `scan_0012.pdf`; the correct name is suggested | — |
| Move to archive | two versions of the same document; the older can go | — |

**A folder is Complete only when the system is sure.** Anything it cannot establish makes the folder *Needs review*. The two errors are not equal: an unnecessary flag costs a reviewer five minutes; a false "all clear" means an inspector finds the expired certificate first.

**Names are matched carefully.** The name on a document is compared with the folder's name with accents, case, word order and punctuation removed — `KOWALSKA, Anna`, `Anna Kowalska` and `Kowalská Anna` are one person, and Polish letters such as `ł` are handled explicitly. A partial match (a second given name, a double surname) goes to a person rather than being called wrong.

**File names never decide anything.** Completeness is decided from content only. A file called `BGCHECK` that contains a contract does not count as a background check — and the misleading name is itself reported, because a person browsing the folder would believe it.

## 6. How it works

```
Google Drive
   │  read-only service account                         [n8n]
   ▼
intake: one listing ─► folder tree ─► inventory ─► stored copy by content fingerprint
   │
   ▼
recognition: page images ─► model ─► type, name, dates   [Python]
   │          (cached by content + rule set + model + prompt + reader versions)
   ▼
checks: missing · expired · expiring · wrong person ·
        foreign file · misleading name · non-standard name   [Python]
   │
   ▼
findings + folder status (write-once) ─► report functions   [Postgres]
   │                                          │
   ▼                                          ▼
review screen                          Google Sheets report  [Python / n8n]
```

### Intake

A Google service account with **read-only** access to one folder lists everything in it. The database builds the folder tree, classifies folders (person folder, archive, anything unexpected) and decides which files to fetch. Each file is stored once under the SHA-256 of its content. Every run records exactly which file version sat in which folder, so a report can say whether a person's folder was complete on a given date.

Failures are loud. An empty listing from Drive is an error, never "no documents". A file in an unexpected place, an empty file, a native Google Doc or an unknown format becomes a finding for a person, never a silent skip.

### Recognition

The model sees **content only** — no file name, no folder name, no person number, no metadata. Pages are rendered to images by our own code and sent as images, because a PDF upload carries its file name, and a model that sees `CG-0042_BGCHECK_….pdf` tends to believe the name. That would hide exactly the misleading-name defects the system exists to catch.

The answer format is enforced by a strict JSON schema; the document type must be one of the rule set's types or "other". Phone photos (including iPhone HEIC) are turned upright and converted before reading. Every answer is stored with the exact prompt, reader settings and library versions that produced it; a changed prompt under an old version name is refused.

### Checks

Plain code, no model, no clock. An expired document is present but expired; another person's document is not present (wrong person **and** missing). Dates are checked only on the person's own documents. Findings and folder status are written once per run and can never be edited afterwards — Postgres refuses it, even to the database owner.

### Report

A Google Sheet with three tabs: **Summary** (one row per person, Incomplete and Needs review first, with what is missing, expired or expiring and how many days are left), **Findings** (one row per finding, with links to the file in Drive and a suggested file name) and **Run info**. Every value is computed in the database; the workflow only copies rows. Values are written as raw text, so a date stays a date and a file name beginning with `=` stays text, never a formula. After writing, the row count Google holds is compared with what the database produced. The report is written by a second service account that can edit that one spreadsheet and nothing else.

### Review screen

A local web page where a person goes through the findings folder by folder, looking at **the same page images the model saw**. Three decisions: confirm, reject (with a reason from a fixed list) or correct — the person enters the fact printed on the page, and the system's own code recomputes the expiry. Decisions are kept beside the findings, never in them: nobody can improve the system's measured figure by deciding.

### Failures

Every workflow reports to an error workflow that marks the run as failed and e-mails the operator what stopped, where, and what to do. A run is marked *done* only when intake, recognition, checks and report have all succeeded; a database trigger enforces it.

## 7. The bench

### The batch

| | |
|---|---|
| Person folders | 70 (40 caregivers, 30 clients) |
| Files | 393 |
| Planted defects | 110, across eight types |
| Fully clean folders | 23 |
| Near-miss controls | 30 |
| Scans and phone photos | about a third of all files |
| Document layouts | 27 in batch 1; 40 in batch 2 |

**Eight defect types:** missing document, expired (printed date), expired (computed from issue date), ended fixed-term contract, another person's document, foreign document, expiring soon (with the expected tier), misleading file name. Non-standard file names are scored separately so that easy cases do not inflate the main figure.

**Boundary cases** sit exactly on the edges: expires today, expired yesterday, exactly 90 or 60 days left. **Controls** sit just outside them: 91 days left, a care plan with 31 days left, valid fixed-term contracts, correctly archived old versions, and names written with and without diacritics. Any finding on a control is a false alarm.

**Realistic documents.** Several layouts per document type, as if from different issuers or form versions; varied labels ("Valid until", "Expiry date", "Expires") and date formats; multi-page contracts with the end date on page 2; scans with tilt, noise and no text layer; phone photos with perspective and uneven light. No numeric date is ambiguous between day and month — a model "misreading" `04/03/2025` would be the bench's error, not the system's.

**Independence is tested.** The generator uses two separate random streams — one places defects, the other, with no knowledge of them, decides layout, scan or photo, and file name. Before upload, a chi-square test compares defective and clean files on every presentation feature; a batch that fails is rejected.

### Sealed before the system sees it

1. The generator writes the ledger and **seals** it. From that moment the database refuses any change to it.
2. Only then are the files uploaded to Drive.
3. Drive's own upload timestamps prove the order: batch 1 was sealed at 19:31 UTC, its first file reached Drive at 19:38 UTC. Batch 2 was sealed at 16:17:55 UTC; its files arrived from 16:27:05.

For batch 2 the system was frozen first: a git tag marks the code as measured, before the first line of the new generator was written.

### Scoring

A separate program, under a separate database role that may read the ledger and write scores but cannot touch findings, matches every finding to the ledger file by file. Each planted defect is either **correct**, **named differently** (found, but with the wrong tier or kind), **handed to a person**, or **not found**. Every finding that matches nothing is a false alarm. Folders are scored too, and the one error that matters most — an incomplete folder reported complete — is counted on its own. Scores are written once per scorer version and never overwritten.

## 8. Data and access

| Schema | Contents | Pipeline role | Scoring role |
|---|---|---|---|
| `ref` | rule sets, document types, requirements | read | read |
| `doc` | files, stored copies, cached model answers | read / write | read |
| `rec` | runs, inventories, findings, folder status, decisions | read / write | read |
| `truth` | the defect ledger | **no access** | read |
| `score` | scoring results | **no access** | insert only |

Rule sets are versioned and locked by the first run that uses them. The pipeline connects only as its own restricted role — never with a key that bypasses row-level security. None of these schemas is exposed through a public API. Schemas and roles are in `sql/`.

## 9. Stack

| Part | Where |
|---|---|
| Drive intake, Sheets report, error handling and alerts | n8n |
| Recognition, checks, scoring, review screen, batch generator | Python |
| Rules, inventories, findings, ledger, report functions, run status | PostgreSQL (Supabase) |
| Document reading | OpenAI `gpt-5.6-terra` |

## 10. What is not in this repository

This repository holds the design, the rules, the database schemas and roles, and the results. The pipeline code, prompts, workflows and batch generators are kept private. They are available for review on request, as is a live demonstration on the bench.

**Out of scope of the system:** regulatory knowledge, scheduling, billing, visit tracking. A second phase — collecting missing documents through a no-account upload link, with reminders and escalation — is designed on top of this one and not yet built.

---

*All names, documents and data in this project are fictional. The required-document lists are illustrative.*
