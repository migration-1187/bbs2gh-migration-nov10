# 🚀 Bitbucket Server to GitHub Repository Migration Pipeline

> A GitHub Actions–based solution for migrating **Bitbucket Server** repositories to **GitHub** at scale. Supports parallel migrations, pre-migration checks, post-migration validation, multiple storage backends, and GitHub Data Residency.

[![Migration Tool](https://img.shields.io/badge/Tool-gh--bbs2gh-181717.svg)](https://github.com/github/gh-bbs2gh)
[![Platform](https://img.shields.io/badge/Platform-Bash%20%7C%20PowerShell-blue.svg)](https://github.com/github/gh-bbs2gh)

---

## 📋 Table of Contents

- [Introduction](#-introduction)
- [Repository layout](#-repository-layout)
- [Limitations](#️-limitations)
- [Prerequisites](#️-prerequisites)
- [Initial Setup](#-initial-setup)
- [Quick Start](#-quick-start)
- [Running manually](#-running-manually)
- [Repository names vs slugs](#-repository-names-vs-slugs)
- [Large files / Git LFS](#-large-files--git-lfs)

---

## 📖 Introduction

Migrating repositories from Bitbucket Server to GitHub is a multi-stage process that includes readiness validation, parallel repository migration, and post-migration verification. When applied across hundreds or thousands of repositories, this process becomes difficult to coordinate, error-prone, and hard to scale using ad-hoc commands.

This toolkit addresses those challenges through a staged, CSV-driven execution model. Each stage runs independently, produces machine-readable output, and can be executed from the command line or embedded inside a CI/CD pipeline. Failures in individual repositories are isolated - they do not block the remaining batch.

The stages are numbered after their scripts: **Stage 0** pre-checks (`0_prechecks.sh`), **Stage 1** migration (`1_migration.sh`), **Stage 2** validation (`2_validation.sh`). The workflow's input descriptions number the same stages 1, 2 and 3. Two optional stages follow migration: **Git LFS** (`3_lfs_migration.sh`) copies LFS objects, and **Large-file** (`4_large_file_migration.sh`) migrates repos with files too large for `gh bbs2gh` by converting them to Git LFS.

---

## 🗂 Repository layout

There is a single set of scripts, used both by the GitHub Actions workflow (automated) and
by a human invoking them directly (manual) — no separate copies to keep in sync:

```
.github/workflows/bbs2gh-migration.yml   # GitHub Actions pipeline (automated approach)
.github/workflows/bbs2gh-gitlfs.yml      # Git LFS objects + large-file repos; the 'Git LFS / large files' stage of bbs2gh-migration.yml, or run by hand
scripts/
  bash/                                   # Called by the workflow, or run directly
    0_prechecks.sh
    1_migration.sh
    2_validation.sh
    3_lfs_migration.sh
    4_large_file_migration.sh
  powershell/                             # PowerShell equivalents, for manual use on Windows
    0_prechecks.ps1
    1_migration.ps1
    2_validation.ps1
    3_lfs_migration.ps1
    4_large_file_migration.ps1
archive/
  public/bbs2gh-gitlfs.yml                # Old large-file workflow, inactive (replaced by .github/workflows/bbs2gh-gitlfs.yml)
  private/bbs2gh-gitlfs.yml               # Inactive: same file
repos.csv                                # Input: repos to migrate
lfs-repos.csv                            # Optional input: Git LFS repos (header only = detect automatically)
large-file-repos.csv                     # Optional input: large-file repos (header only = scan automatically)
bbs2gh-env-list.txt                      # Reference list of secrets, variables and inputs
```

The **automated** approach triggers `bbs2gh-migration.yml` from the Actions tab (see
[Quick Start](#-quick-start)); the **manual** approach runs the scripts by hand from a
terminal (see [Running manually](#-running-manually)). The workflow calls the Bash scripts
only; the PowerShell scripts are never run by it.

---

## ⚠️ Limitations

- **Repository Migration Size Limits**
The [GitHub Enterprise Importer](https://github.com/github/gh-gei) has the following size limits:

| Item | Maximum Size |
|------|--------------|
| Repository archive | ~40 GiB |
| Single file (during migration) | 400 MiB |
| Single file (after migration) | 100 MiB (larger files must use Git LFS) |
| Single commit | 2 GiB |

- **What Gets Migrated:**
  - Git repository content (all files)
  - Complete commit history
  - All branches and tags
  - Commit metadata (authors, dates, messages, SHAs)

- **Concurrency:**
  - In the workflow, the `max_concurrent` input defaults to **10** (choices 1–10).
  - When you run `1_migration.sh` / `1_migration.ps1` by hand, the default is **3**. Raise it with `--max-concurrent`, up to 10.

- **Where the work happens:**
  - For each repository, `gh bbs2gh` starts an export on Bitbucket Server, then **downloads the export archive over SSH (SFTP) to the machine running the script** (the Actions runner, in the workflow), uploads it to the storage backend, and GitHub imports it from there.
  - The runner therefore needs SSH access to the Bitbucket host (port 22, or `BBS_SSH_PORT`) and enough free disk space for the archives being migrated in parallel. Only the final import runs on GitHub's backend; during it the script polls the migration status.

- **Job timeouts:**
  - Every job in the workflow sets `timeout-minutes: 50400` (35 days). GitHub's own job limits still apply: 360 minutes on GitHub-hosted runners and 5 days on self-hosted runners, so long migrations should run on self-hosted runners.

- **Track Long-Running Migrations:**
  - If a migration is taking longer than expected, monitor progress directly using the GitHub CLI: [GitHub Migration Monitor](https://github.com/mona-actions/gh-migration-monitor)
    ```bash
    gh extension install mona-actions/gh-migration-monitor
    gh migration monitor
    ```

---

## ⚙️ Prerequisites

- organization owner role for the destination organization in GitHub, or an organization owner must grant the migrator role.
- You must also have required permissions and access to your Bitbucket Server instance:
  -  Admin or super admin permissions.
  -  SFTP access to the instance over SSH, using a supported SSH private key. The scripts support only this method, so the Bitbucket Server host must accept SSH (in practice, a Linux host). File sharing (SMB) access for Windows hosts is not supported.
-  **GitHub Data Residency**, set `TARGET_API_URL` to the regional GitHub API endpoint (for example, https://api.tenant.ghe.com). 
- **GitHub PAT** (`GH_PAT`) with scopes `repo`, `admin:org` and `workflow`
- **Bitbucket Server:**
  - **Bitbucket Server URL:** `BBS_BASE_URL` — e.g., http://bitbucket.example.com:7990
  - **Username and password** (`BBS_USERNAME`, `BBS_PASSWORD`) — **always required**: the migration stage passes them to `gh bbs2gh`.
  - **Bitbucket API credentials** for pre-checks, validation and the Git LFS stage — one of:
    - `BBS_PAT` (used first when set), or
    - `BBS_AUTH_TYPE=Basic`, which makes these stages use `BBS_USERNAME` / `BBS_PASSWORD`.
    
    Set one of these. If neither is set, pre-checks and validation don't stop - they call the Bitbucket API without credentials and report misleading results.
  - **SSH:**
    - `SSH_USER` - SSH username for the Bitbucket Server host.
    - `SSH_PRIVATE_KEY` — an unencrypted (passphrase-free) private key.
- The `repos.csv` file must exist with the columns: `project-key`, `project-name`, `repo`, `github_org`, `github_repo`, `gh_repo_visibility`. Migration requires all six. Pre-checks check only for `project-key`, `project-name` and `repo`; validation requires the first five.
- **Optional Storage backend:**
  - **AWS S3:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET_NAME`, `AWS_REGION`
  - **Azure Blob:** `AZURE_STORAGE_CONNECTION_STRING`
  - **Github-owned:** 	*(nothing needed — automatic fallback)*

---

## 🔧 Initial Setup

The main workflow, `bbs2gh-migration.yml`, runs the jobs **Pre-check + Repository scan → Approve migration → Migration → Post-migration Validation**, plus the **Git LFS / large files** stage when it is enabled (see below).

**Repository scan** runs alongside Pre-check on every run. **Approve migration waits for it**, so flagged repos are known before anyone approves:
- **Repository size report and large-file repos** — always. Repos with files of `large_file_threshold_mb` (default 400) or more are listed in the job summary and get a warning on the run page: *remove them from `repos.csv`*. If they stay, Migration skips them (`Skipped - Large Files`) — set `skip_large_file_repos=false` to attempt them instead (the old behaviour: `gh bbs2gh` rejects them and the migration logs say why).
- **Detect Git LFS repos** — only when `detect_lfs_repos=true` or `migrate_lfs_repos=true`. With `migrate_lfs_repos=false` the LFS repos found are skipped (`Skipped - Git LFS`) and not migrated.

| Inputs | Git LFS repos | Large-file repos |
|---|---|---|
| defaults | Not detected; migrated like any other repo (LFS pointer files only, objects not copied) | Flagged, skipped (`Skipped - Large Files`), not migrated |
| `skip_large_file_repos=false` | — | Flagged, but attempted by Migration (expected to fail) |
| `detect_lfs_repos=true` | Flagged, skipped (`Skipped - Git LFS`), not migrated | — |
| `migrate_lfs_repos=true` | Flagged, migrated; then **Git LFS Migration** copies their LFS objects | — |
| `migrate_large_file_repos=true` | — | Flagged, skipped by Migration; then **Large-file Migration** converts them to Git LFS and migrates them after its own approval |

A repo that is both an LFS repo and a large-file repo is treated as a large-file repo. If the Repository scan fails, migration isn't approved or started.

**Git LFS / large files** stage: when `detect_lfs_repos`, `migrate_lfs_repos` or `migrate_large_file_repos` is `true`, the run also shows this stage (it calls `bbs2gh-gitlfs.yml`) with its jobs **Git LFS Migration**, **Approve large-file migration** and **Large-file Migration**. Jobs whose migrate input is `false`, or that have no repos to work on, show as skipped. With all three inputs `false` the stage itself shows as one skipped box — GitHub doesn't allow hiding a job completely. You only need to configure the secrets, variables and environments on GitHub.

**All secrets and variables live in one place.** Put them either on the `bbs-migration` environment or at repository level - you never need to duplicate them. The approval gate is a separate job that holds no secrets, so it cannot cause "secret is empty" failures.

- **Add Secrets:** Go to your GitHub repo → `Settings` → `Security` → `Secrets and variables` → `Actions` → `Secrets` → `New repository secret`, and add the following:
  - `GH_PAT`: GitHub PAT with `repo`, `admin:org`, and `workflow` scopes.
  - `BBS_PASSWORD`: Bitbucket password. Always required (used by migration).
  - `BBS_PAT` *(optional)*: Bitbucket token for the pre-check and validation API calls. If you don't set it, set the `BBS_AUTH_TYPE` variable to `Basic` instead.
  - `SSH_PRIVATE_KEY`: Contents of a passphrase-free private key (e.g. `~/.ssh/id_rsa`)
  - **Storage backend secrets** (add only one set, or none for GitHub-owned storage):
    - `AZURE_STORAGE_CONNECTION_STRING`: Azure Blob Storage
    - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_BUCKET_NAME`, `AWS_REGION`: AWS S3 (all four are read as secrets)
  - **Add Repository Variables:** Go to `Settings` → `Security` → `Secrets and variables` → `Actions` → `Variables` → `New Repository variable`, and add:
    - `BBS_BASE_URL`: Bitbucket Server URL e.g. http://bitbucket.example.com:7990. Every job fails without it.
    - `BBS_USERNAME`: Bitbucket username. Always required (used by migration).
    - `BBS_AUTH_TYPE`: `Basic`. Required unless you set the `BBS_PAT` secret.
    - `SSH_USER`: SSH username for the Bitbucket Server host
    - `TARGET_API_URL`: Only for GitHub Data Residency e.g. https://api.tenant.ghe.com
    - `BBS_SHARED_HOME` *(optional)*: Bitbucket **shared home** path *on the Bitbucket Server host* (usually `<bitbucket-home>/shared`). Needed when the archive is not under the gh bbs2gh default `/var/atlassian/application-data/bitbucket/shared`.
    - `BITBUCKET_HOME` *(optional)*: Bitbucket home path on the Bitbucket Server host. If `BBS_SHARED_HOME` is not set, migration uses `<BITBUCKET_HOME>/shared` as the shared home.
    - `BBS_SSH_PORT` *(optional)*: SSH port for downloading the export archive (default `22`)
    - `BBS_ARCHIVE_DOWNLOAD_HOST` *(optional)*: Host to SSH to for the archive, if different from the Bitbucket URL host
    - `BBS_DISABLE_SSL_VERIFY` *(optional)*: `true` for self-signed / internal CA certificates
    - `COMMIT_CHECK` *(optional)*: `false` to skip per-branch commit/SHA checks (default `true`)
    - `FAIL_ON_VALIDATION_FAILURES` *(optional)*: `true` to fail the Validation job on any discrepancy (default `false`)
  - **Create two Environments:** Go to `Settings` → `Environments` → `New environment` and create both:
    - `bbs-migration` — **holds all secrets and variables**. Every working job (pre-check, migration, validation) runs here. Do **not** add required reviewers.
    - `bbs-migration-approval` — **holds nothing at all**. Add one or more **Required reviewers** and leave it otherwise empty.
  - **How the approval works:** a tiny `Approve migration` job runs in `bbs-migration-approval` and does nothing but wait for a reviewer. The real Migration job depends on it and runs in `bbs-migration`, so it reads the same single set of secrets as every other stage.
  - **Environment names** must match the `environment` and `approval_environment` workflow inputs (defaults above). Change either input at run time if you use different names.
  -  **Prepare `repos.csv`:** Edit `repos.csv` in the repository root with the repos you want to migrate. The workflow always reads this file; there is no input to point it elsewhere.
   
  
      | Column | Description |
      |--------|-------------|
      | `project-key` | Bitbucket project key (e.g., `MYPROJ`) |
      | `project-name` | Bitbucket project display name |
      | `repo` | Bitbucket repository **slug or display name** - a name such as `Maven Hello World` is resolved to its slug automatically |
      | `github_org` | Target GitHub organization |
      | `github_repo` | Target GitHub repository name |
      | `gh_repo_visibility` | `private`, `internal`, or `public` |

  -  **Prepare `lfs-repos.csv` (optional):** used when detection runs. Leave it with just the header to detect LFS repos automatically, or list the LFS repos yourself using the same columns as `repos.csv`.
  -  **Prepare `large-file-repos.csv` (optional):** used on every run. Leave it with just the header to scan `repos.csv` automatically, or list the large-file repos yourself (same columns as `repos.csv`; repo names or slugs).

**Workflow inputs** (set when you click *Run workflow*):

| Input | Default | Description |
|-------|---------|-------------|
| `environment` | `bbs-migration` | Environment with the secrets and variables |
| `approval_environment` | `bbs-migration-approval` | Environment with the required reviewers |
| `max_concurrent` | `10` | Parallel migrations, 1–10 |
| `verbose` | `false` | Sets `VERBOSE=1` for the migration script (not used by the Git LFS stage) |
| `runner_label` | `ubuntu-24.04` | Runner label, or a JSON array of labels. Pinned to a fixed Ubuntu version rather than `ubuntu-latest`, which moves to Ubuntu 26 from 2026-10-19 ([runner-images#14748](https://github.com/actions/runner-images/issues/14748)) |
| `run_pre_validation` | `true` | Run Stage 0, pre-checks |
| `run_migration` | `true` | Run Stage 1, migration |
| `run_post_validation` | `true` | Run Stage 2, validation |
| `detect_lfs_repos` | `false` | Detect and report Git LFS repos; with `migrate_lfs_repos=false` they are skipped and not migrated. Shows the Git LFS / large files stage |
| `migrate_lfs_repos` | `false` | Migrate the Git LFS repos and copy their LFS objects; turns LFS detection on (see [Large files / Git LFS](#-large-files--git-lfs)) |
| `lfs_max_concurrent` | `2` | Parallel Git LFS object / large-file repo migrations, 1–10 |
| `skip_large_file_repos` | `true` | Skip the large-file repos the repository scan finds (it runs on every run). `false` = attempt them; `gh bbs2gh` rejects files ≥ 400 MiB |
| `migrate_large_file_repos` | `false` | Migrate the large-file repos by converting them to Git LFS — **rewrites history**, separate approval. They are skipped by Migration either way (see [Large files / Git LFS](#-large-files--git-lfs)) |
| `large_file_threshold_mb` | `400` | A repo is a large-file repo if any file in its history is at least this size |
| `large_file_convert_above_mb` | `100` | In those repos, convert every file above this size to Git LFS (max 100) |


---

## 🚀 Quick Start

**Before you begin**, ensure you've completed the [Initial Setup](#-initial-setup):
- ✅ Secrets and variables configured in **one** place (`bbs-migration` environment, or repo level)
- ✅ `bbs-migration` environment created **without** reviewers; `bbs-migration-approval` created **with** reviewers and nothing else
- ✅ repos.csv updated and pushed to the default branch

1. **Trigger the workflow:** Go to `Actions` → `bbs2gh-migration` → Run workflow and set your inputs, then click `Run workflow`.
2. **Review Stage 0 - Pre-checks:** The Pre-check job runs automatically.
      - Go to the job's Summary tab and review the pre-check table
      - Check the uploaded artifact `bbs-prechecks-<run-id>` → `bbs_pr_validation_output-<timestamp>.csv`
      - Open PRs are reported for information only and don't block migration. Bitbucket PRs aren't migrated, so decide whether to merge or close them first.
      - If the open-PR query fails for any repo, the Pre-check job fails and migration doesn't start.
      - The Pre-check job itself doesn't scan for large files. Large-file and LFS repos are found by the separate **Repository scan** job (see [Large files / Git LFS](#-large-files--git-lfs)).
3. **Approve Stage 1 - Migration:** The `Approve migration` job pauses waiting for approval. Go to the workflow run and click `Review deployments` → `Approve to release it`. The Migration job starts once approved.
      - Monitor the live status bar in the job logs: `QUEUE / IN PROGRESS / MIGRATED / FAILED`.
      - Once complete, download artifact `migration-output-csv-<run-id>` → `repo_migration_output-<timestamp>.csv`. Per-repo logs are in `migration-logs-<run-id>`.
      - Confirm every repo shows `Success` in the `Migration_Status` column. Other values are `Failure`, `Failure - Repo Not Found`, `Skipped - Large Files` and `Skipped - Git LFS` (`Pending` if the run was interrupted). Rows missing a required value are skipped with a warning in the log and don't appear in the CSV.
      - The Migration job fails only when no repo migrated. With partial success it passes, and validation runs on the repos that succeeded.
      - The job summary's **Failed** count includes only `Failure` rows, not `Failure - Repo Not Found`; check the per-repo table for those.
4. **Review Stage 2 — Validation:**  The Validation job runs automatically after migration, on repos with status `Success` only. Download artifact `validation-results-<run-id>`, which contains `validation-summary-<timestamp>.md`, `validation-summary-<timestamp>.csv` and `validation-log-<timestamp>.txt`:
      - ✅ All entries show Matching for branches, commit counts, and latest SHAs.
      - **Branch count and the "missing branches" comparison always cover every branch.** The per-branch commit/SHA deep-check covers at most 10 branches: **all** branches when the repo has 10 or fewer, otherwise the **default branch plus 9 others** in no particular order.
      - Discrepancies are reported as warnings. The job fails on them only if `FAIL_ON_VALIDATION_FAILURES=true`.
      - Validation compares Git data only. It doesn't check LFS objects.
5. **Repository scan:** before approving, check its job summary (and the warnings on the run page): large-file repos on every run, Git LFS repos when LFS detection runs, and the size report. **Remove flagged repos from `repos.csv`** for future runs. All CSVs are in the artifact `repo-scan-<run-id>`.
6. **Git LFS / large files (only with `migrate_lfs_repos=true` or `migrate_large_file_repos=true`):** after Migration, the stage's jobs run in the same workflow run.
      - **Git LFS Migration** copies the LFS objects and publishes `lfs-migration-results-<run-id>` → `lfs-migration-output-<timestamp>.csv` plus per-repo logs. Confirm every repo shows `Success` in the `LFS_Status` column.
      - For large-file repos, approve **Approve large-file migration** (`Review deployments`) to start **Large-file Migration**. It publishes `large-file-migration-results-<run-id>` → `large-file-migration-output-<timestamp>.csv`, per-repo logs, `large-file-sha-map-*.csv` (old → new commit SHAs) and the validation results for these repos. Confirm every repo shows `Success`, and tell teams to re-clone them.

7. **Mannequins generation and reclaim:**  After you run a migration, all user activity in the migrated repository (except Git commits) is attributed to placeholder identities called mannequins.
    -  To generate a CSV file with a list of mannequins for an organization, Optionally, to include mannequins that have already been reclaimed, add the --include-reclaimed flag.: 
    `gh bbs2gh generate-mannequin-csv --github-org TARGET_ORG --output mannequins-bbs.csv`
    -  To reclaim generaate mannequins: 
    `gh bbs2gh reclaim-mannequin --github-org TARGET_ORG --csv mannequins-bbs.csv`

---

 
**Next Steps:**
- **More repositories?** Update `repos.csv` and rerun the workflow
- **Partial failures?** Fix the root cause, remove successfully migrated repos from `repos.csv`, and rerun workflow for remaining repos

---

## 🖐 Running manually

The scripts under `scripts/bash/` are the same ones the workflow runs — you can invoke them
directly from a terminal instead of via GitHub Actions. Set the environment variables listed
in [Prerequisites](#️-prerequisites) / `bbs2gh-env-list.txt`, then run each stage in order:

```bash
export BBS_BASE_URL=https://bitbucket.example.com
export BBS_USERNAME=...       # always required by 1_migration.sh
export BBS_PASSWORD=...
export BBS_PAT=...            # or BBS_AUTH_TYPE=Basic, for 0_prechecks.sh and 2_validation.sh
export GH_PAT=...
export SSH_USER=...
export SSH_PRIVATE_KEY_PATH=~/.ssh/id_rsa   # path to an unencrypted key

chmod +x scripts/bash/*.sh
./scripts/bash/0_prechecks.sh -c repos.csv
./scripts/bash/1_migration.sh --csv repos.csv --max-concurrent 5 --target-api-url https://api.github.com
./scripts/bash/2_validation.sh -c repos.csv -b "$BBS_BASE_URL"

# Optional: Git LFS objects / large-file repos (see "Large files / Git LFS")
./scripts/bash/3_lfs_migration.sh --detect --csv repos.csv
./scripts/bash/3_lfs_migration.sh --lfs-csv lfs-repos-<timestamp>.csv \
  --migration-output repo_migration_output-<timestamp>.csv --target-api-url https://api.github.com
```

Use `SSH_PRIVATE_KEY` only for the key's **contents** (the `-----BEGIN ... PRIVATE KEY-----`
text). If `SSH_PRIVATE_KEY` holds a file path, `1_migration.sh` deletes that file after
migrating each repo.

When run by hand, `0_prechecks.sh` also runs its own (slower) large-file scan, which the workflow turns off. `4_large_file_migration.sh --detect` is the faster replacement.
See [Large files / Git LFS](#-large-files--git-lfs).

On Windows, use the PowerShell equivalents instead (`./scripts/powershell/0_prechecks.ps1 -c repos.csv`, etc.; they take the same arguments as the Bash scripts). They differ from the Bash scripts in a few ways:
- `0_prechecks.ps1` removes every double quote from `repos.csv` in the current directory and saves the file in place, on every run, even when `-c` points to a different file.
- `2_validation.ps1` writes `validation-summary.csv` and `validation_summary_<yyyyMMdd>.md`, without a time in the name, so a later run the same day overwrites them.

**Auto-discovery (pre-checks only):** if `repos.csv` is missing, empty, or missing the
`project-key`/`project-name`/`repo` columns, `0_prechecks.sh`/`0_prechecks.ps1` fall back to
discovering every project and repo directly from Bitbucket instead of failing. Scope the
discovery to specific projects with `-p "KEY1,KEY2"`:

```bash
./scripts/bash/0_prechecks.sh -p "MYPROJ,OTHERPROJ"
```

This is useful for an initial readiness sweep before you've hand-built a `repos.csv`. Once
you have a curated CSV (with `github_org`, `github_repo`, `gh_repo_visibility` filled in),
pass it explicitly with `-c` for prechecks, migration, and validation.

---

## 🔤 Repository names vs slugs

`gh bbs2gh` identifies a repository by its **slug**, not its display name. Bitbucket
derives the slug from the name (`Maven Hello World` → `maven-hello-world`,
`solar system` → `solar-system`, `Test21` → `test21`).

You may put **either** form in the `repo` column - the scripts look the repository up
and substitute the real slug, logging what they did:

```
[WARNING] 'Maven Hello World' is a repository NAME, not a slug. Resolved to slug 'maven-hello-world' for BBSMIG.
```

If a value matches no repository at all, the row fails immediately - before any export
is created - and is listed with the valid options:

```
[ERROR] No repository in BBSMIG matches the name or slug 'Hello World Repo'.
[ERROR] Available in BBSMIG: calotracker maven-hello-world solar-system solid-api
```

That row is recorded in the output CSV as `Failure - Repo Not Found` and the rest of the
batch continues.

The Pre-check job does not publish a name → slug table or flag unmatched entries (that step
is commented out in the workflow). Unmatched entries show up only during migration, as
`Failure - Repo Not Found` rows.

---

## 🧬 Large files / Git LFS

### Repositories that use Git LFS

`gh bbs2gh` migrates Git data only. For a repository that uses Git LFS, the migrated GitHub
repo gets the LFS pointer files, but the actual LFS files stay on Bitbucket. The Git LFS stage
copies them afterwards.

**In the workflow**, LFS detection is off by default (`detect_lfs_repos=false`): LFS repos are
then migrated like any other repo, without their LFS objects. With `detect_lfs_repos=true` the
LFS repos found are reported, skipped by Migration (`Skipped - Git LFS`) and not migrated. To
migrate them and copy their objects, run `bbs2gh-migration.yml` with `migrate_lfs_repos=true`
(this turns detection on):

1. The **Detect Git LFS repos** step of the **Repository scan** job finds them.
   The LFS part makes only two API calls per repo.
   - If `lfs-repos.csv` in the repository root has rows, those repos are used and nothing
     is detected.
   - If it has only the header (as shipped), each repo in `repos.csv` is checked with two
     Bitbucket API calls, run in parallel and without cloning anything. A repo counts as an
     LFS repo if Git LFS is enabled for it in Bitbucket, or if the `.gitattributes` file at
     the root of its default branch contains `filter=lfs`.
   - The list is published in the `repo-scan-<run-id>` artifact (`lfs-repos-<timestamp>.csv`,
     same columns as `repos.csv`, plus `lfs-detection-report-<timestamp>.csv` when detected).
     The workflow can't commit it; to reuse or edit the list, copy its rows into `lfs-repos.csv`.
2. **Migration** migrates every repo in `repos.csv` as usual, LFS repos included.
3. **Git LFS Migration** (in the **Git LFS / large files** stage) runs after Migration,
   alongside Validation. For each LFS repo with migration status `Success`, it clones a
   mirror from Bitbucket, downloads all LFS objects (`git lfs fetch --all`) and uploads them
   to the GitHub repo (`git lfs push --all`). `lfs_max_concurrent` (default 2) sets how many
   repos run at once. LFS repos whose migration didn't succeed are recorded as
   `Skipped - Not Migrated`. There is no separate approval: the Migration approval covers it.
   The job is skipped if no LFS repos were found.

`bbs2gh-gitlfs.yml` can also be started by hand from the Actions tab, for example to retry
failed repos or after a run with `run_migration=false`. With `source_run_id` set to a
`bbs2gh-migration` run, it uses that run's `repo-scan-<run-id>` lists and migration results. Without it, it uses `lfs-repos.csv` (or detects LFS
repos from `repos.csv`) and attempts every listed repo.

The GitHub repo must already exist (the stage doesn't create it), and the runner needs disk
space for one mirror clone per parallel repo. `GH_PAT` must be able to push to the target
repos.

**By hand**, run `3_lfs_migration.sh` (or `3_lfs_migration.ps1`, PowerShell 7+) after
migration:

```bash
./scripts/bash/3_lfs_migration.sh --detect --csv repos.csv          # writes lfs-repos-<timestamp>.csv
./scripts/bash/3_lfs_migration.sh --lfs-csv lfs-repos-<timestamp>.csv \
  --migration-output repo_migration_output-<timestamp>.csv           # optional: only repos with status Success
```

Options: `--parallel N` for detection (default 10), `--max-concurrent N` for migration
(default 2, up to 10), `--target-api-url` for GitHub Data Residency. Migration needs `git`
and `git-lfs`. Results go to `lfs-migration-output-<timestamp>.csv` (`LFS_Status`:
`Success`, `Failure` or `Skipped - Not Migrated`; `LFS_Objects`: objects copied) and
`lfs-migration-<project>-<repo>-<timestamp>.txt` logs. The script exits with code 1 if any
repo fails.

### Repositories with large files (not in Git LFS)

`gh bbs2gh` rejects any file of 400 MiB or more, and GitHub refuses new pushes of files over
100 MiB. Repos with such files committed as plain Git objects are migrated by a separate
stage that converts the large files to Git LFS and pushes the result to GitHub directly.

> ⚠️ **Converting rewrites history.** Every commit from the first converted file onward
> gets a new SHA. Open pull requests, forks and existing clones no longer match; teams must
> re-clone. Old → new SHA maps are kept in `large-file-sha-map-*.csv`.

**In the workflow**, large-file repos are found on every run by the **Repository scan** (the
same scan produces the size report), flagged with a warning to remove them from `repos.csv`,
and skipped by Migration (`Skipped - Large Files`) — `skip_large_file_repos=false` attempts
them instead. To migrate them, run `bbs2gh-migration.yml` with `migrate_large_file_repos=true`:

1. The **Repository scan** job scans the repos alongside Pre-check. Approve migration waits
   for it, so on a large Bitbucket the approval prompt appears only after the scan.
   - If `large-file-repos.csv` in the repository root has rows, those repos are used (names
     are resolved to slugs) and nothing is scanned.
   - Otherwise each repo in `repos.csv` is scanned for files of `large_file_threshold_mb`
     (default 400) or more anywhere in its history, in parallel. To keep this fast:
     - repos whose Bitbucket-reported size is under a quarter of the threshold are not cloned
       at all (packed size is compressed, so the margin is deliberate);
     - the others are cloned with `--filter=blob:limit=<threshold>`, so files at or above
       the threshold are never downloaded. If your Bitbucket doesn't support partial clone,
       git falls back to a full clone — slower, but still correct.
   - The list is published in the `repo-scan-<run-id>` artifact (`large-file-repos-<timestamp>.csv`,
     plus `large-file-report-<timestamp>.csv` with every large file found, and
     `repo-size-report-<timestamp>.csv` — see [Repository size report](#repository-size-report)).
2. **Migration** skips these repos and records them as `Skipped - Large Files`. If
   the scan fails, migration isn't approved or started.
3. In the **Git LFS / large files** stage, **Approve large-file migration** waits for a reviewer in `approval_environment`, because
   this stage rewrites history.
4. **Large-file Migration** runs `4_large_file_migration.sh` for each repo:
   clone (branches and tags only) → fetch any existing LFS objects → `git lfs migrate import
   --everything --above=<large_file_convert_above_mb>` → create the GitHub repo with the
   `gh_repo_visibility` from the list → push LFS objects → push branches and tags → set the
   default branch to Bitbucket's. Then it validates the migrated repos with `2_validation.sh`
   and `SKIP_SHA_CHECK=true`: branches and commit counts are compared, SHAs are not.

Notes:
- Files above GitHub's LFS file-size limit (2–5 GB depending on plan) can't be migrated; the
  repo fails with a message in its log.
- One push to GitHub is limited to 2 GB. After conversion the Git data is usually far
  smaller, but a repo whose remaining history still exceeds this fails at the push step.
- If the GitHub repo already exists, the stage pushes into it without force. Re-running is
  safe: the conversion is deterministic, so a repeat produces the same SHAs.
- With `run_migration=false`, the large-file stage still runs (these repos never go through
  `gh bbs2gh`). If the Migration job fails outright, the stage doesn't run.

`bbs2gh-gitlfs.yml` can be started by hand with `migrate_large_files=true` (and
`migrate_lfs_objects=false` if only that part is wanted); `source_run_id` reuses an earlier
run's `repo-scan-<run-id>` lists.

**By hand**, run `4_large_file_migration.sh` (or `4_large_file_migration.ps1`, PowerShell 7+):

```bash
./scripts/bash/4_large_file_migration.sh --detect --csv repos.csv     # writes large-file-repos-, large-file-report- and repo-size-report-<timestamp>.csv
LARGE_FILE_REPOS_CSV=large-file-repos-<timestamp>.csv \
  ./scripts/bash/1_migration.sh --csv repos.csv                       # skips the large-file repos
./scripts/bash/4_large_file_migration.sh --large-csv large-file-repos-<timestamp>.csv
SKIP_SHA_CHECK=true ./scripts/bash/2_validation.sh -c large-file-repos-<timestamp>.csv -b "$BBS_BASE_URL"
```

Options: `--threshold-mb` (default 400), `--prefilter-mb` (default threshold ÷ 4; `0` clones
every repo), `--parallel` (detection, default 4), `--list-only` (resolve a hand-written list
without scanning), `--convert-above-mb` (default 100, max 100), `--max-concurrent` (migration,
default 1, up to 10), `--target-api-url`. Detection needs `git` 2.31+; migration also needs
`git-lfs`. `GH_PAT` must be allowed to create repos in the target org.

### Repository size report

Every repo the large-file scan clones also gets a [git-sizer](https://github.com/github/git-sizer)-style
summary, computed from the same clone (no extra download, nothing to install). It is written to
`repo-size-report-<timestamp>.csv`, included in the `repo-scan-<run-id>` artifact and shown
in the Repository scan job summary. It runs on **every** run, whatever the detection inputs. One row per repo:

| Column | Meaning |
|--------|---------|
| `bitbucket_size_mb` | Size reported by Bitbucket (empty if Bitbucket doesn't report it) |
| `clone_size_mb` | Packed size of the scan's clone (files at or above the threshold are not included) |
| `commits`, `max_history_depth` | Commits on all branches and tags; longest history of any branch or tag |
| `branches`, `tags`, `trees` | Counts |
| `files`, `files_total_mb` | Distinct file versions in the whole history, and their total size |
| `largest_file_mb`, `largest_file_path` | Biggest file in the history |
| `files_over_100mb` | File versions over 100 MB — GitHub rejects pushes of these |
| `files_over_threshold` | File versions at or above `large_file_threshold_mb` |
| `largest_commit_mb`, `largest_commit` | The commit that adds the most file data, and how much |
| `max_path_depth`, `max_path_length` | Deepest folder nesting and longest path |
| `warnings` | GitHub limits the repo hits: files ≥ threshold (`gh bbs2gh` rejects ≥ 400 MiB), files over 100 MB, a commit adding 2 GB or more, a repository of about 40 GB or more |

Sizes are in MiB with two decimals (for example `0.34`), so small repos don't show as `0`. Values prefixed with `>=` are lower bounds: files at or above the threshold are deliberately not
downloaded, so they count as exactly the threshold. Repos that are not cloned (below the
pre-filter size, not found, clone failed) get a row with only the reason in `notes`. With a
threshold below 100 MB, `files_over_100mb` counts only the files that were downloaded.

### Manual large-file scan in pre-checks

`0_prechecks.sh` has an older, slower scan (a full mirror clone of every repo). The workflow
turns it off (`RUN_LARGE_FILE_SCAN=false`), so the `RUN_LARGE_FILE_SCAN` /
`LARGE_FILE_THRESHOLD_MB` variables have no effect there. **Running by hand**, it works:

1. `0_prechecks.sh` scans every repo (on by default; set `RUN_LARGE_FILE_SCAN=false` to
   turn it off) by cloning a mirror and listing every file at or above
   `LARGE_FILE_THRESHOLD_MB` (default `400`). It needs `git` on the machine.
2. It writes `large_files_report-<timestamp>.csv` (one row per file) and
   `large_file_repos-<timestamp>.csv` (one row per repo, the skip-list). Flagged repos get
   `ready_to_migrate=false` in the pre-check CSV.
3. `1_migration.sh` skips the repos in the skip-list and records them as
   `Skipped - Large Files`. It uses `LARGE_FILE_REPOS_CSV` if set, otherwise the newest
   `large_file_repos-*.csv` in the current directory. The list can be in this format or in
   the `repos.csv` format written by `4_large_file_migration.sh`. Set
   `MIGRATE_LARGE_FILE_REPOS=true` to ignore the skip-list and migrate those repos anyway.

---

## 📚 References

1. GitHub CLI | [cli.github.com](https://cli.github.com)
2. gh-bbs2gh extension | [github/gh-gei](https://github.com/github/gh-gei)
3. gh-migration-monitor | [mona-actions/gh-migration-monitor](https://github.com/mona-actions/gh-migration-monitor)
4. Migrate from Bitbucket Server (GitHub Docs) | [docs.github.com – BBS migrations](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrating-from-bitbucket-server-to-github-enterprise-cloud/migrating-repositories-from-bitbucket-server-to-github-enterprise-cloud)


