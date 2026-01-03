# Branch Work Status: web_sync

## Current state
- Branch: `web_sync` (tracking `origin/web_sync`)
- Prepared changes (intended for commit):
  - `lib/google_tasks/service.rb` injects `tasks_service` and `authorization` for easier testing.
  - `spec/lib/google_tasks/service_spec.rb` updated to use injected service + auth doubles.
  - `spec/lib/omnifocus/service_spec.rb` and `spec/lib/reminders/service_spec.rb` expanded with better doubles and richer `items_to_sync` coverage.
  - `spec/lib/asana/service_spec.rb` adds `friendly_name` and `sync_strategies` expectations.
  - `spec/spec_helper.rb` enables SimpleCov when `COVERAGE=1` or `SIMPLECOV=1`.
  - New specs: `spec/lib/base/service_spec.rb`, `spec/lib/google_tasks/base_cli_spec.rb`, `spec/lib/reclaim/service_spec.rb`, `spec/lib/task_bridge_spec.rb`, `spec/lib/task_bridge_web/service_spec.rb`
  - New fixtures: `spec/fixtures/600_prentiss_project.json`, `spec/fixtures/600_prentiss_tasks.json`, `spec/fixtures/shopping_list_tasks.json`, `spec/fixtures/taskbridge_project.json`
  - `.gitignore` updated to ignore local artifacts (`.simplecov`, `simplecov_mcp.log`, `config/master.key`, `db/*.sqlite3*`).
  - `WORK_STATUS.md` refreshed.
- Remaining untracked file (not part of this change set): `TODO.md`

## Work done (so far)
- Added dependency injection for Google Tasks service + authorization to make unit tests more deterministic.
- Expanded Omnifocus and Reminders service specs to avoid Appscript calls and improve coverage of sync selection behavior.
- Added basic Asana service metadata expectations.
- Added opt-in coverage wiring in the spec helper.
- Created new fixtures and spec files for additional services and web sync coverage.
- Added base service coverage for core sync decisions and metadata updates.

## Work that likely remains
- Run the relevant specs (or full suite) to validate the new behavior and fixtures.
- Verify that the new fixtures are used where intended or prune if they were only exploratory.
