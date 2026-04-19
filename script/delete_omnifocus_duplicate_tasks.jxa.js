/*
 * Delete duplicate OmniFocus tasks from a project.
 *
 * Usage:
 *   # dry run:
 *   osascript -l JavaScript script/delete_omnifocus_duplicate_tasks.jxa.js
 *   # remove all duplicates:
 *   osascript -l JavaScript script/delete_omnifocus_duplicate_tasks.jxa.js -- --execute
 *  # remove with a limit of 100 per run:
 *   osascript -l JavaScript script/delete_omnifocus_duplicate_tasks.jxa.js -- --execute --limit 100
 *
 * Defaults target the HuntHelper:HuntHelper project and group tasks by the
 * GitHub issue/PR number encoded in titles like "hunthelper-#3655: ...".
 * Dry run is the default. Use --execute to delete.
 */

ObjC.import("Foundation");

function run(argv) {
  const args = parseArgs(argv);
  const app = Application("OmniFocus");
  const doc = app.defaultDocument;
  const logPath = args.log || defaultLogPath(args.project);

  const project = findProject(doc, args.project, args.folder);
  if (!project) {
    throw new Error(`Project not found: ${args.folder ? `${args.folder}:` : ""}${args.project}`);
  }

  const plan = buildDeletionPlan(project, args);
  log(logPath, `\n${new Date().toISOString()} ${args.execute ? "EXECUTE" : "DRY RUN"}`);
  log(logPath, `Project: ${args.folder ? `${args.folder}:` : ""}${args.project}`);
  log(logPath, `Issue tasks: ${plan.issueTaskCount}`);
  log(logPath, `Duplicate groups: ${plan.groups.length}`);
  log(logPath, `Delete candidates: ${plan.toDelete.length}`);
  log(logPath, `Keepers: ${plan.keepers.length}`);

  printPlanSummary(plan, args);

  if (!args.execute) {
    console.log(`Dry run only. Add --execute to delete candidates. Log: ${logPath}`);
    return;
  }

  const candidates = args.limit ? plan.toDelete.slice(0, args.limit) : plan.toDelete;
  log(logPath, `Deleting this run: ${candidates.length}${args.limit ? ` (limit ${args.limit})` : ""}`);

  let deleted = 0;
  let failed = 0;
  for (const row of candidates) {
    try {
      app.delete(row.ref);
      deleted += 1;
      log(logPath, `DELETED ${deleted}/${candidates.length} id=${row.id} key=${row.key} name=${row.name}`);
      if (deleted % args.progressEvery === 0) {
        console.log(`Deleted ${deleted}/${candidates.length}`);
      }
      if (args.pauseMs > 0) delay(args.pauseMs / 1000.0);
    } catch (error) {
      failed += 1;
      log(logPath, `ERROR id=${row.id} key=${row.key} name=${row.name} error=${error}`);
      console.log(`ERROR deleting ${row.id}: ${error}`);
    }
  }

  log(logPath, `Finished. Deleted=${deleted}, failed=${failed}`);
  console.log(`Finished. Deleted=${deleted}, failed=${failed}. Log: ${logPath}`);
}

function parseArgs(argv) {
  const args = {
    execute: false,
    folder: "HuntHelper",
    project: "HuntHelper",
    limit: null,
    log: null,
    pauseMs: 0,
    progressEvery: 25,
    includeCompleted: true,
    includeDropped: false
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--") continue;

    switch (arg) {
      case "--execute":
        args.execute = true;
        break;
      case "--folder":
        args.folder = argv[++i];
        break;
      case "--project":
        args.project = argv[++i];
        break;
      case "--limit":
        args.limit = parseInt(argv[++i], 10);
        if (!Number.isFinite(args.limit) || args.limit < 1) throw new Error("--limit must be a positive integer");
        break;
      case "--log":
        args.log = argv[++i];
        break;
      case "--pause-ms":
        args.pauseMs = parseInt(argv[++i], 10);
        if (!Number.isFinite(args.pauseMs) || args.pauseMs < 0) throw new Error("--pause-ms must be a non-negative integer");
        break;
      case "--progress-every":
        args.progressEvery = parseInt(argv[++i], 10);
        if (!Number.isFinite(args.progressEvery) || args.progressEvery < 1) throw new Error("--progress-every must be a positive integer");
        break;
      case "--include-dropped":
        args.includeDropped = true;
        break;
      case "--active-only":
        args.includeCompleted = false;
        args.includeDropped = false;
        break;
      case "--help":
        printHelp();
        $.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return args;
}

function findProject(doc, projectName, folderName) {
  const projects = doc.flattenedProjects.whose({ name: projectName })();
  for (const project of projects) {
    if (!folderName) return project;
    try {
      const folder = project.folder();
      if (folder && folder.name() === folderName) return project;
    } catch (_error) {
      // Project has no folder.
    }
  }
  return null;
}

function buildDeletionPlan(project, args) {
  const taskSpec = project.flattenedTasks;
  const refs = taskSpec();
  const ids = taskSpec.id();
  const names = taskSpec.name();
  const completed = taskSpec.completed();
  const dropped = taskSpec.dropped();
  const modified = taskSpec.modificationDate();
  const created = taskSpec.creationDate();

  const rows = [];
  for (let i = 0; i < ids.length; i += 1) {
    if (!args.includeCompleted && completed[i]) continue;
    if (!args.includeDropped && dropped[i]) continue;

    const name = names[i] || "";
    const issue = name.match(/^(.*?)-#(\d+):/);
    if (!issue) continue;

    rows.push({
      ref: refs[i],
      id: ids[i],
      name,
      key: `issue:${issue[1].toLowerCase()}#${issue[2]}`,
      completed: Boolean(completed[i]),
      dropped: Boolean(dropped[i]),
      modified: modified[i],
      created: created[i]
    });
  }

  const byKey = {};
  for (const row of rows) {
    if (!byKey[row.key]) byKey[row.key] = [];
    byKey[row.key].push(row);
  }

  const groups = Object.values(byKey)
    .filter((group) => group.length > 1)
    .sort((a, b) => b.length - a.length || a[0].key.localeCompare(b[0].key));

  const keepers = [];
  const toDelete = [];
  for (const group of groups) {
    group.sort(compareKeeperCandidates);
    keepers.push(group[0]);
    toDelete.push(...group.slice(1));
  }

  return {
    issueTaskCount: rows.length,
    groups,
    keepers,
    toDelete
  };
}

function compareKeeperCandidates(a, b) {
  const aActive = !a.completed && !a.dropped;
  const bActive = !b.completed && !b.dropped;
  if (aActive !== bActive) return aActive ? -1 : 1;

  const modifiedDiff = timeValue(b.modified) - timeValue(a.modified);
  if (modifiedDiff !== 0) return modifiedDiff;

  const createdDiff = timeValue(b.created) - timeValue(a.created);
  if (createdDiff !== 0) return createdDiff;

  return a.id.localeCompare(b.id);
}

function timeValue(date) {
  return date ? date.getTime() : 0;
}

function printPlanSummary(plan, args) {
  console.log(`Issue tasks: ${plan.issueTaskCount}`);
  console.log(`Duplicate groups: ${plan.groups.length}`);
  console.log(`Delete candidates: ${plan.toDelete.length}`);
  if (args.limit) console.log(`Run limit: ${args.limit}`);

  for (const group of plan.groups.slice(0, 20)) {
    const keeper = group[0];
    console.log(`\n${keeper.key}: count=${group.length}`);
    console.log(`  KEEP ${state(keeper)} ${keeper.id} ${dateString(keeper.modified)} ${keeper.name}`);
    for (const row of group.slice(1, Math.min(group.length, 6))) {
      console.log(`  DEL  ${state(row)} ${row.id} ${dateString(row.modified)} ${row.name}`);
    }
    if (group.length > 6) console.log(`  ... ${group.length - 6} more delete candidates`);
  }
}

function state(row) {
  if (row.dropped) return "DROPPED";
  if (row.completed) return "DONE";
  return "OPEN";
}

function dateString(date) {
  return date && date.toISOString ? date.toISOString() : String(date);
}

function defaultLogPath(projectName) {
  const cwd = $.NSFileManager.defaultManager.currentDirectoryPath.js;
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  return `${cwd}/log/omnifocus-dedupe-${projectName}-${stamp}.log`;
}

function log(path, message) {
  const line = `${message}\n`;
  const fileManager = $.NSFileManager.defaultManager;
  const nsPath = $(path).stringByExpandingTildeInPath;
  const dir = nsPath.stringByDeletingLastPathComponent;

  fileManager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(dir, true, $(), null);
  if (!fileManager.fileExistsAtPath(nsPath)) {
    $(line).writeToFileAtomicallyEncodingError(nsPath, true, $.NSUTF8StringEncoding, null);
    return;
  }

  const handle = $.NSFileHandle.fileHandleForWritingAtPath(nsPath);
  handle.seekToEndOfFile;
  handle.writeData($(line).dataUsingEncoding($.NSUTF8StringEncoding));
  handle.closeFile;
}

function printHelp() {
  console.log(`Delete duplicate OmniFocus tasks from a project.

Defaults:
  --folder HuntHelper --project HuntHelper

Options:
  --execute          Delete tasks. Without this, only prints a dry run.
  --limit N          Delete at most N tasks this run. Re-run to continue.
  --log PATH         Write progress to PATH.
  --pause-ms N       Pause after each delete.
  --progress-every N Print progress every N deletions.
  --active-only      Only consider active tasks as duplicate candidates.
  --include-dropped  Also delete duplicate dropped tasks.
`);
}
