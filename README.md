# Apache Hop – Proof of Concept (PoC) Notes

> **Status:** in progress — living document, will be updated as we move forward with the migration.

> **Author:** Sofia Arancibia (Id90 Travel)

> **Last updated:** September 1, 2026 (GitHub Actions review + future-improvements notes added)

## Purpose of this document

Record the experience of installing, configuring, and testing **Apache Hop** as a possible replacement for **Pentaho Data Integration (PDI/Kettle)** for our ETL processes, using the `CruiseBookings` flow (reading booking XML files → staging → final) as a test case. The goal is to share what we've learned so far with the team — including the stumbling blocks, not just what worked — so it serves as a reference when we evaluate a broader migration.

This document will keep growing over future iterations (more migrated pipelines, performance benchmarks, architecture decisions, etc.).

---

## 1. Context: what is Apache Hop?

Apache Hop ("Hop Orchestration Platform") is an Apache Software Foundation project, born as a fork/evolution of **Pentaho Kettle (PDI)**, created largely by the same original Kettle team. The terminology shifts slightly but the concepts map very closely:

| Pentaho / Kettle | Apache Hop |
|---|---|
| Job (`.kjb`) | Workflow (`.hwf`) |
| Transformation (`.ktr`) | Pipeline (`.hpl`) |
| Step | Transform |
| Job entry | Action |
| Spoon (design GUI) | Hop Gui |
| Carte (execution server) | Hop Server |
| Repository | Project / Environment |

"Apache Hop software is released under the Apache License v2.0 and is overseen by a self-selected team of active contributors to the project."

---

## 2. Installation and initial setup

Apache Hop officially supports two distinct installation paths — Docker for Hop Server, and the standalone client distribution for Hop Gui. This document describes only the installation via Docker.

### 2.1. Hop Server (via Docker)

To test the execution server, we used the official `apache/hop` Docker image. Per the official Docker documentation, this image supports two modes:

- **Short-lived containers**: run a single pipeline or workflow and then exit (configured via env vars like `HOP_FILE_PATH`, `HOP_PROJECT_FOLDER`, `HOP_RUN_CONFIG`, etc., with the project folder mounted as a volume).
- **Long-lived containers**: start a Hop Server that stays up waiting for incoming work — this is the mode we used.


Pull apache/hop Docker Image:

```
docker pull apache/hop
```

For our test we ran it without overriding the credentials, mapping the container's default port 8080 to a free local port:

```
docker run -p 8081:8080 apache/hop   # 8080 was already taken locally, mapped to 8081 instead
```

The server exposes its [status UI](https://hop.apache.org/manual/latest/hop-server/index.html#:~:text=2.715%20seconds%20%5B%20%202.714%22%20%5D-,CONNECT%20TO%20THE%20HOP%20SERVER%20UI,-To%20connect%20to) at:

```
http://localhost:8080/hop/status
```

**Default credentials:** `cluster` / `cluster` (both username and password) when `HOP_SERVER_USER`/`HOP_SERVER_PASS` aren't set. Basic Auth is enabled by default and **cannot currently be disabled through configuration** (per an [open discussion](https://github.com/apache/hop/discussions/5993) in the Hop repo, it requires a source code change). For production, this should always be overridden with the `HOP_SERVER_USER` / `HOP_SERVER_PASS` environment variables at container startup, as shown above.

> ⚠️ **Important:** Hop Server is only the remote execution engine — **it does not let you design** workflows/pipelines from the browser. For that you need Hop Gui (see below) or, alternatively, Hop Web (which needs to be deployed separately on top of Apache Tomcat).

### 2.2. Hop Gui (design client)

We downloaded the `apache-hop-client-2.18.1` distribution (Windows build) and run it locally via `hop-gui.bat`.

**Key requirement: Java 21 (64-bit).** This version of Hop is not compatible with Java 8 (startup fails with `Unrecognized option: --add-opens`, a typical symptom of trying to run Java 9+ module flags on an old JVM). **Adoptium** builds are also flagged as incompatible in the official docs — we used **Microsoft OpenJDK 21** instead.

Once the correct JDK is on `PATH`/`JAVA_HOME`, `hop-gui.bat` launches the design interface without issues.

### 2.3. Project and environment

When creating the first project, Hop asks whether you want to attach it to a **lifecycle environment** (an optional layer for managing different variables per stage — dev/test/prod — without touching the workflow/pipeline itself). For this first PoC we chose to **skip it** (it's not mandatory and can be added later); the base project was enough to develop and test with.

> 🔁 **Revisited in Round 2** (see [Section 7](#7-round-2-containerizing-for-production)) — once we needed a real dev vs. production split for the containerized MVP, we did adopt this feature, combined with Hop's **System Variables**, since environments alone don't solve credential handling (more on why below).

![Project Properties](./images/1_create-project.png)

![Lifecycle Environment](./images/2_lifecycle-project.png)
---

## 3. ETL migration: from Pentaho to Hop

### 3.1. The import tool

Hop ships with a dedicated wizard (**Import code to Hop**, also available as the `hop-import` CLI) built specifically to convert Kettle/PDI projects. It automatically:

- Converts `.kjb` → `.hwf` (workflows) and `.ktr` → `.hpl` (pipelines).
- Copies the rest of the project's files as-is.
- Can import variables from `kettle.properties`, connections from `shared.xml`, and credentials from `jdbc.properties`, if those paths are provided.
- On completion, produces a summary (workflows/pipelines/files converted, connections saved) and a `connections.csv` flagging connections that **share the same name but have different configurations** (only one is kept — you need to manually review which ones got overwritten).

**Configuration used:**
- Import into an existing project + the project already created was selected (with this, "Import to folder" is intentionally disabled — the two are mutually exclusive, not a bug).
- `Skip folders in the source` **unchecked** — important, because leaving it checked (the default) only imports loose files at the root of the source folder, ignoring subfolders. Our Pentaho ETL was organized into subfolders, so leaving it checked would have imported an incomplete project with no visible error.

![Import Code to Hop](./images/3_import-from-kettle.png)

![Default Run Configuration Not Set](./images/3-a_import-from-kettle.png)

**Result of the first run:** 2 jobs, 4 transformations, 8 misc files, 2 database connections imported.

![Import Summary](./images/3-b_import-from-kettle.png)

### 3.2. Bug found: `${PROJECT_HOME}` gets corrupted by repeated imports

When retrying the import more than once, we started seeing a "folder doesn't exist" error with the path duplicated several times over (`.../CruiseBookings/etl-hop/CruiseBookings/etl-hop/CruiseBookings/etl-hop/...`). This is a known, reported bug in the official repo ([apache/hop#2865](https://github.com/apache/hop/issues/2865)): the import wizard overwrites the project's `${PROJECT_HOME}` variable with the destination folder used in that run, instead of keeping the real project home. Each additional run of the wizard "dirties" the variable a bit more.

**Mitigation:** verify/reset the project's "Home folder" (Projects → Edit) and reopen the project (or restart Hop Gui) before retrying an import, to force the variable to reload cleanly from the saved config. Since there's no upstream fix, the safest long-term rule is simply **not to re-run the wizard against an already-migrated project** — if more Pentaho content needs to come in, import it into a scratch folder and copy the resulting files in by hand instead.

---

## 4. Building the flow (workflow + pipeline)

### 4.1. Replacing the FTP step

> ℹ️ **Note:** The original Pentaho job looked for the bookings file on an FTP server. For this PoC we moved forward with a local copy of a few of the files just to test an end-to-end flow

🔜 **SELECTED FOR A SECOND ITERATION**


### 4.2. Collecting files from a folder

An important distinction that caused confusion: **"Get files from result" is a pipeline transform**, it doesn't exist as a workflow action. On the workflow side, the equivalent is the **"Add filenames to result"** action, which adds files (by folder + wildcard/regex) to the workflow's "result list" — an internal collection (`Result.getResultFiles()`) that other actions/pipelines can later consume.

On the pipeline side, the **"Get files from result"** transform is the counterpart that reads that list and turns it into rows (`filename`, `path`, `type`, `origin`, etc.). Important detail: **this transform only has data when the pipeline is executed from the workflow** (via the "Pipeline" action) — testing it in an isolated preview always returns "No preview rows found," because that result context doesn't exist outside that execution chain.

### 4.3. Reading the XML (`Get data from XML`)

Final configuration that worked:
- `XML source is defined in a field` + `XML source is a filename` both checked.
- **`get XML source from a field` → the `path` field** (not `filename`). This was a non-obvious trap: the `filename` field coming out of "Files from result" only carries the bare file name with no directory — Hop interprets it as a path relative to the process's working directory (the Hop client's install folder, not the project), and fails with `FileNotFoundException`. The `path` field carries the full absolute path.
- `Loop XPath`: must match the actual structure of the source XML (in our case, `/Invoices/Invoice` — inherited as-is from the import, but **it's worth always confirming it with the "Get XPath nodes" button** against a real file rather than assuming the imported value is correct).
- We recommend unchecking `Do not raise an error if no files` while debugging — with that option checked, any file-not-found issue is **silently swallowed** instead of surfacing as an error, which makes diagnosis much harder.

With this configuration, the pipeline correctly processed the 5 XML files → 959 rows → written to Parquet (`Parquet File Output`).

### 4.4. Moving the already-processed files

This was the part that took the most debugging time. The **Move files** action has an option called **"Copy previous results to args"** which, by its name, looks like the natural way to chain it after "Add filenames to result." **It isn't.** Looking at the action's source code, that option specifically reads `Result.getRows()` (data rows, like what a `Copy rows to result` transform inside a pipeline would leave) — a completely separate collection from `Result.getResultFiles()`, which is what "Add filenames to result" populates. That's why, no matter how many times "Add filenames to result" was repeated before "Move files," the file count always came back `0`.

**The configuration that actually works** — bypass the "result" mechanism entirely and use the action's static grid instead:
- **General** tab → the `Files/Folders` grid, with a row where `File/Folder source`, `File/Folder destination`, and `Wildcard (RegExp)` are filled in directly (same folder/pattern as "Add filenames to result").
- **Destination file** tab → `Destination is a file` **unchecked** (so the grid's destination is treated as a folder, preserving each file's original name — not as a single file to rename).
- The `Move to folder` section is not used in this approach — it's a separate fallback mechanism, specifically tied to the `If destination file exists = "Move source file to folder"` dropdown, not a general-purpose way to move multiple files.

![Workflow](./images/cruise_bookings.svg)

![Pipeline](./images/cruises_process_booking_files_into_stg.svg)

### 4.5. Pending stage

🚧 **WORK IN PROGRESS**

The `staging_to_final` pipeline (the next step in the flow, staging → final tables) is being build.

---

## 5. General gotchas / lessons learned about the tool

A list of non-obvious behaviors worth the team knowing upfront, so we don't lose time rediscovering them:

- **A single click on the canvas opens the action/transform picker by default.** This can be changed to "double-click only" in the **Configuration** perspective → `Use double click on canvas?` option. Worth turning on from day one — it removes a fair amount of friction. ❌ **not working on windows**
- **A grayed-out `Preview` button in a transform dialog** usually means a required field is missing (typically a field-selection dropdown) — not a bug, worth checking the config before assuming it's broken.
- **Java must be 21 (64-bit)**, not just any recent version — and avoid Adoptium builds.
- Importing from Pentaho is **not a one-click process**: particular considerations needed for each case 📆 **consider for time estimations**
- Hop's official documentation is solid for the general flow but **has gaps on edge cases** (we had to dig into GitHub issues and even source code for some actions to understand specific behaviors, like "Move files" and "Table output" — see [Section 7.5](#75-bug-found-table-output-field--is-required-and-couldnt-be-found)). Worth factoring into troubleshooting time estimates.
- For debugging a pipeline/workflow, raising the logging level to **Detailed** (or **Debugging**) in the run dialog gives much better visibility than the "Basic" log. There's also the **Execution Information** perspective (`Ctrl+Shift+I`) to inspect result rows/files per action after a run, though it requires an "Execution Information Location" to be configured.
- **Hop does not automatically expose OS/shell environment variables as `${VARIABLE}`** — this surprised us in Round 2 and is worth knowing early (see [Section 7.4](#74-parameterizing-credentials-the-right-way)).

---

## 6. Early conclusions on the future migration

With the caveat that this is just a first migrated flow (not representative of the full complexity of our Pentaho ETLs), some initial impressions:

**In favor:**
- The conceptual overlap with Kettle is high — anyone already familiar with Pentaho PDI orients themselves quickly in Hop; the learning curve is more about "where things live" than about new concepts.
- The import tool automates a large chunk of the mechanical conversion work (file formats, basic structure), which meaningfully reduces effort compared to rewriting everything by hand.
- **Update (Round 2):** the same project can be packaged into a Docker image and run unattended, headless, with no Hop Server — see [Section 7](#7-round-2-containerizing-for-production). This validates that a git-driven, containerized production model is technically viable, not just a local PoC.

**Things to keep in mind / risks:**
- Migration is **not 100% automatic** — every imported pipeline/workflow needs a non-trivial manual review (connections, XPaths, file-field mapping, etc.). For a large volume of ETLs, this implies a meaningful QA effort, not just "run the import and done."
- There are known, active bugs in the current version (e.g., the `${PROJECT_HOME}` issue with repeated imports) worth having mapped out before scaling this process to more pipelines, to avoid re-diagnosing them each time.
- Community support (GitHub discussions/issues) is active, but official documentation doesn't always cover edge cases — budget non-trivial research/debugging time into the team's initial adoption curve. Round 2 added two more examples of this (Table output field mapping, credential/variable handling).
- We've validated the container runs headless end-to-end, but **haven't yet evaluated performance at real production volumes, nor integration into a real cloud environment** (VPC access, secrets management, scheduling, monitoring) — see [Section 7.6](#76-what-still-needs-infra) for the concrete open questions.

**Suggested next steps:**
1. Migrate and validate the `staging_to_final` pipeline.
2. Migrate a second, more complex flow (ideally one with multiple database connections) to properly exercise the `shared.xml`/`jdbc.properties` handling in the import, which wasn't fully exercised in this first case.
3. Confirm cloud provider (AWS or GCP) with Infra so the production execution path (scheduler + credentials + VPC access) can be finalized — see [Section 7.6](#76-what-still-needs-infra).
4. Estimate migration effort at scale (time per migrated pipeline + QA) based on what we've learned here, to properly size the full project.

---

## 7. Round 2: containerizing for production

Round 1 proved the migration itself works. Round 2 asks a different question: **how would this actually run in production**, day after day, without anyone opening Hop Gui by hand — analogous to Tableau Desktop vs. Tableau Server, but explicitly *not* the same thing, since Hop has no hosted/managed equivalent.

The direction we're testing: instead of standing up a persistent Hop Server, **bake the whole project into a Docker image on every push to `main`, and run that image once a day via a scheduler** — no server to patch, monitor or keep alive between runs.

### 7.1. Project restructure

The project was reorganized so the git repo root doubles as `${PROJECT_HOME}` — **for both** the local Hop Gui project and the Docker image. We initially tried keeping two separate project homes (local project rooted at `hop-mvp/`, Docker rooted at the repo root) and it caused real pain: `metadata/` can only physically live in one place, so every time one side needed it, the other lost it (this is what was behind the "`BETA-CONN` disappeared" scare — see the gotcha below). Unifying both to the same home folder removed the whole class of problem.

```
ApacheHop-PoC/              <- ${PROJECT_HOME} for BOTH local dev and Docker, and the Docker build context
├── .github/workflows/      <- CI, must live at the repo root or GitHub won't see it
├── Dockerfile
├── .dockerignore
├── .gitignore
├── .env.dev.example
├── .env.dev               <- personal, gitignored, never committed
├── load-vars.ps1          <- registers DB_* variables locally, on the dev's machine (see 7.4)
├── load-vars.sh           <- same idea, runs INSIDE the container at startup (see 7.4)
├── project-config.json    <- the ONE project config, used by local Hop Gui and Docker alike
├── metadata/               <- connections, run configs, etc. (rdbms/BETA-CONN.json, pipeline-run-configuration/local.json, ...)
├── apache-hop-client-2.18.1/   <- gitignored; each dev extracts their own client here (see 7.4)
└── hop-mvp/                <- just the ETLs now, no project-config.json of its own
    └── ETLs/Cruises/
        ├── Bookings/
        │   ├── cruise_bookings_main.hwf
        │   ├── cruise_bookings_src_to_raw.hpl
        │   ├── cruise_booking_raw_to_staging.hpl
        │   └── cruise_bookings_staging_to_final.hpl
        └── Invoices/
```

Project name in Hop Gui (local): `ApacheHop-PoC`, home folder = repo root. Project name inside the Docker container: `ApacheHop-mvp` (see 7.2) — different name, same physical layout, which is the property we actually care about (what you test locally is what runs in the container).

> ⚠️ **Gotcha:** a *pipeline run configuration* named `local` also lives in `metadata/` (as a `pipeline-run-configuration` metadata object, not a file you'd think to look for) and is **not created automatically** — it's the engine (Native Local Pipeline Engine) a workflow uses when it opens a pipeline. Running a workflow before this exists fails with `Unable to find the specified pipeline run configuration 'local'`. Create it once via **Metadata perspective → Pipeline Run Configuration → New**, name `local`, engine *Native Local Pipeline Engine*.

### 7.2. Dockerfile — baking the project, no server, no volume mount

Based on the [official Docker image docs](https://hop.apache.org/tech-manual/latest/docker-container.html). The image copies the whole repo in at build time instead of mounting it at runtime:

```dockerfile
FROM apache/hop:2.18.1

# Alpine base — apk, not apt-get. Default user is "hop", not root, so package installs need
# a USER root / USER hop bracket.
USER root
RUN apk add --no-cache jq
USER hop

COPY --chown=hop:hop ./ /files

USER root
RUN chmod +x /files/load-vars.sh
USER hop

ENV HOP_PROJECT_FOLDER=/files
ENV HOP_PROJECT_NAME=ApacheHop-mvp
ENV HOP_RUN_CONFIG=local

# Runs before project registration and before the workflow/pipeline starts — patches the
# container's own hop-config.json with credentials from the environment (see 7.4).
ENV HOP_CUSTOM_ENTRYPOINT_EXTENSION_SHELL_FILE_PATH=/files/load-vars.sh

ENV HOP_FILE_PATH=/files/hop-mvp/ETLs/Cruises/Bookings/cruise_bookings_main.hwf
```

`HOP_FILE_PATH` needs the full `hop-mvp/` prefix to match the real folder layout — easy to get wrong (we did) if you edit this after moving files around locally without rebuilding to check; `docker run --rm --entrypoint find <image> /files -maxdepth 3` is the fastest way to confirm what actually got baked in versus what the Dockerfile assumes.

`.dockerignore` keeps the image clean: git history, any stray `apache-hop-client*.zip` (the exact kind of large file that caused the 774 MiB git push failure — see `.gitignore`), real `.env*` files, and a scratch `PoC - tool/` folder not needed at runtime.

### 7.3. GitHub Actions — build once, push automatically

A workflow triggers on every push to `main`: build the image, push it to **GHCR** (GitHub's own container registry). This is deliberately the "starter" registry — it needs zero cloud credentials or OIDC setup, so it doesn't block on the AWS/GCP decision. Once a cloud is confirmed with Infra, this same job gets a second push step to the cloud's native registry (Artifact Registry or ECR) via OIDC — see Section 7.6.

Worth noting: `docker build` only ever reads the committed `Dockerfile` — none of the Round 2 credential changes (`load-vars.sh`, the Alpine/`jq`/`USER root` steps) need anything from CI at build time, because credentials are injected later, at `docker run` time, not baked into the image. So the workflow itself needed no changes to keep up with the Dockerfile work in this section.

> ⚠️ **Bug found: GHCR rejects an uppercase repository name in the tag.** `ghcr.io/${{ github.repository }}/hop-etl:latest` failed with `invalid tag ... repository name must be lowercase`, because `github.repository` is `arancibia-s/ApacheHop-PoC` — GHCR (like all OCI registries) requires the full image path to be lowercase, and the repo name itself isn't. **Fix:** switched to `github.repository_owner` (already lowercase) instead of `github.repository`, dropping the repo-name segment from the image path entirely: `ghcr.io/${{ github.repository_owner }}/hop-etl`. (For a setup that needs to keep the repo name as a grouping segment — e.g. one namespace hosting images for several repos — the alternative is an explicit lowercasing step, `echo "REPO_LC=${GITHUB_REPOSITORY,,}" >> "$GITHUB_ENV"`, and referencing `${{ env.REPO_LC }}` in the tags.)

✅ **Confirmed working end-to-end**: after that fix, the workflow ran successfully on push to `main` — image built and pushed to GHCR under `ghcr.io/arancibia-s/hop-etl:latest` and `ghcr.io/arancibia-s/hop-etl:<sha>`.

**🔜 Future improvements (not yet applied, low priority):**
- Add an explicit `docker/setup-buildx-action@v3` step before the build-push step. `ubuntu-latest` runners already have Buildx, so the build works without it today, but adding it explicitly is Docker's own recommended practice and unlocks layer caching — useful here since the `apk add jq` layer never changes but currently gets rebuilt on every run.
- Set `provenance: false` on the `docker/build-push-action` step. By default it publishes a provenance attestation alongside the image, which shows up in GHCR as an extra "unknown/unknown" manifest next to the real tags — harmless, but noisy to look at for this simple MVP job.

### 7.4. Parameterizing credentials the right way

Our first instinct — parameterize the connection with `${DB_HOST}`/`${DB_PASSWORD}` and rely on `docker run --env-file` to supply them — **doesn't work on its own**. Apache Hop does **not** automatically expose OS/shell/Docker environment variables as `${VARIABLE}`; there's an open, unresolved [feature request](https://github.com/apache/hop/issues/6967) asking for exactly this, confirming it isn't native today. Variables have to be explicitly registered through one of Hop's own mechanisms first (its **System Variables**, stored in `config/hop-config.json` inside the Hop client installation — outside the git repo, per machine, never committed, never baked into the image).

The connection (`BETA-CONN`) itself uses `${DB_HOST}`, `${DB_PORT}`, `${DB_NAME}`, `${DB_USER}`, `${DB_PASSWORD}` in its fields. What differs is *how* those get registered:

**Locally — `load-vars.ps1` (git-committed, no secrets in it):** each dev copies `.env.dev.example` to `.env.dev` (gitignored, real BETA credentials, personal), then runs `.\load-vars.ps1` once. The script finds their own Hop client install automatically (any `apache-hop-client-*` folder next to the script, or `$env:HOP_CLIENT_HOME` if it lives elsewhere) and registers the five variables into that installation's `hop-config.json`. This replaced our first idea of just telling everyone to click through **Configuration perspective → System Variables** by hand — that doesn't scale to a team (every teammate re-doing manual GUI steps, easy to typo, nothing to review in a PR).

> ⚠️ **Bug found: `hop-conf.bat -sv` doesn't reliably persist (v2.18.1, Windows).** Our first version of `load-vars.ps1` shelled out to `hop-conf.bat -sv VAR=Value`, exactly per its own `--help` output. It ran with **zero errors**, printed a "N variables registradas" success message, and touched the file's timestamp — but the variable was never actually in the file afterwards, confirmed by inspecting `hop-config.json` directly (three separate attempts, including the documented `-cfg` flag to pin the target file explicitly). We never found a working combination of flags. **Workaround:** `load-vars.ps1` now edits `hop-config.json` directly with PowerShell's `ConvertFrom-Json`/`ConvertTo-Json` instead of shelling out to `hop-conf.bat` at all — the same thing Hop Gui's System Variables screen does under the hood, just scripted. This has been reliable in testing; if your team hits this differently on macOS/Linux (`hop-conf.sh`), it's worth re-testing the CLI there before assuming it's fixed.

**In Docker — confirmed working, using the fallback, not `HOP_CONFIG_OPTIONS`:** given the `hop-conf` CLI reliability issue found above, we went straight to `HOP_CUSTOM_ENTRYPOINT_EXTENSION_SHELL_FILE_PATH` instead of trusting `HOP_CONFIG_OPTIONS`/`hop-conf.sh` blind — official docs confirm this script "runs before your Hop project is registered ... and before your Hop workflow or pipeline gets kicked off," exactly the window we need. `load-vars.sh` (same idea as `load-vars.ps1`, bash + `jq` instead of PowerShell) patches the container's own `/opt/hop/config/hop-config.json` (found via `docker run --entrypoint find ... -name hop-config.json` — it's *not* under `/files`, it belongs to the Hop installation baked into the base image at `/opt/hop`) using values passed at `docker run --env-file .env.dev` time, never baked into the image. Confirmed end-to-end: `BETA-CONN` connected and 959 rows landed in `staging.cruise_bookings_hop` from inside the container.

Two things worth knowing if you're setting this up fresh:
- The base `apache/hop` image is **Alpine**, not Debian (`apt-get` doesn't exist — use `apk add --no-cache jq`), and its default user is `hop`, not root, so installing packages needs a `USER root` / `USER hop` bracket in the Dockerfile.
- The default `hop-config.json` inside a fresh container has `"variables": null` rather than an empty array — a `jq` filter that assumes it's already a list breaks with `Cannot iterate over null`. `(.variables //= [])` at the start of the filter fixes it.

> ⚠️ **Bug found: `Insert/Update` to `final` dies under Docker Desktop networking, but not locally.** Running the same `cruise_bookings_staging_to_final` pipeline that writes to `staging` cleanly hangs for ~2 minutes on the row-by-row `Insert/Update` step against `final`, then dies with `java.io.EOFException` / "An I/O error occurred while sending to the backend." Partial rows get *processed* (314 of 905 in one run) but **none get committed** — the transaction is lost when the connection drops, so `final` ends up with 0 new rows even though the log shows progress. Confirmed **not** a pipeline/query problem: the identical pipeline run locally in Hop Gui (same machine, same BETA database) does not hang or drop. This points at Docker Desktop's network path from the container out to an external Postgres host, not at Hop or the ETL logic. Since production won't run through Docker Desktop's NAT — it'll run inside the actual cloud VPC, presumably with a much more direct path to the DB — we're not spending more time chasing this locally. **This needs to be specifically re-tested once real cloud networking exists** (see point 2 in [7.6](#76-what-still-needs-infra)), before assuming the production path is fine just because the credential mechanism is.

`HOP_ENVIRONMENT_NAME` / `HOP_ENVIRONMENT_CONFIG_FILE_NAME_PATHS` (the Docker-native "create a lifecycle environment" variables) turned out to be a red herring for this specific problem — per the docs, they *create* an environment registration at container startup rather than select a pre-existing one, and don't help with keeping secrets out of committed files. We're not using them for credential handling.

### 7.5. Bug found: Table Output `Field [] is required and couldn't be found`

Hit while wiring a `Table Output` transform to write to the BETA (test) database in parallel with the existing file output. Traced to the actual Hop source (`TableOutput.processRow`, inherited from Kettle):

```java
data.valuenrs[i] = getInputRowMeta().indexOfValue( meta.getFieldStream()[i] );
if ( data.valuenrs[i] < 0 ) {
  throw new KettleStepException(... "TableOutput.Exception.FieldRequired", meta.getFieldStream()[i] );
}
```

The `[]` in the error is a **blank "Stream field" entry in the Table Output step's own field-mapping grid** ("Database fields" tab), not a missing field somewhere upstream. `Parquet File Output` tolerated the same blank-named field silently; `Table Output` validates the mapping explicitly and doesn't.

**Fix:** open the source step (`Get Booking data from xml file`), Preview it and check for a blank column header — that's usually where the phantom field originates (an incomplete row in the XML field-definition grid). Fix it there, then re-generate the Table Output mapping with **Get Fields** instead of patching it by hand.

### 7.6. What still needs Infra

This MVP deliberately proves the mechanism only — it doesn't resolve anything that depends on a real cloud decision. Where things stand:

- ✅ **Local credential flow validated end-to-end**: parameterized connection, `load-vars.ps1` registering variables from a personal `.env.dev`, and a real pipeline writing rows to the BETA table — no hardcoded credentials anywhere in git. This part is done and repeatable by any teammate.
- ✅ **Same flow validated inside Docker**: `load-vars.sh` + `HOP_CUSTOM_ENTRYPOINT_EXTENSION_SHELL_FILE_PATH` (see [7.4](#74-parameterizing-credentials-the-right-way)), credentials passed via `docker run --env-file`, confirmed by 959 rows landing in `staging` from inside the container.
- ✅ **CI (GitHub Actions → GHCR) confirmed working**: every push to `main` builds the image and pushes it to `ghcr.io/arancibia-s/hop-etl` under `:latest` and `:<sha>` (see [7.3](#73-github-actions--build-once-push-automatically)).
- ⏳ **Not yet validated: whether the container's network path can sustain a longer-running DB operation** — the `Insert/Update` step to `final` dies on Docker Desktop's network path but not locally (see the bug callout in 7.4). Point 2 below needs to specifically re-test this once real VPC networking exists, not just assume it's fine.

Still open, and dependent on Infra:

1. **Cloud provider (AWS or GCP)** — not yet confirmed; determines which of the two production paths below gets implemented.
2. **VPC access for the scheduled compute** (ECS Fargate / Cloud Run Job) — subnet, security group/firewall, and whether a VPC endpoint / Private Service Connect is needed to pull the image without public internet egress.
3. **Credentials and identity in production** — the OIDC trust between GitHub Actions and the cloud (to push without static keys) and the real database credentials via Secrets Manager / Secret Manager, replacing the local `.env.dev` approach used in this MVP.
4. **Cost of the network connector in GCP** — Cloud Run Jobs needs a Serverless VPC Connector with a fixed monthly cost even for a once-a-day job; AWS's EventBridge + Fargate is pay-per-run with no fixed cost.
5. **Observability and alerting** — where a failed daily run should notify the team (CloudWatch Alarms / Cloud Monitoring → Slack or email), replacing today's manual monitoring.

The daily scheduler itself (EventBridge Scheduler + ECS Fargate, or Cloud Scheduler + Cloud Run Jobs) and the manual on-demand trigger (a `workflow_dispatch` GitHub Action reusing the same OIDC role) are designed conceptually but not yet implemented — both are next once the points above are settled.

---

*Document in progress — recommended to revisit periodically as the PoC advances.*
