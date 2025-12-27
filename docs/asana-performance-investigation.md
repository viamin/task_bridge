# Asana Sync Performance Investigation

Investigation for [GitHub Issue #148](https://github.com/viamin/task_bridge/issues/148)

## Current Implementation Analysis

### How Asana Sync Works Today

The Asana service (`lib/asana/service.rb`) currently:

1. **Fetches all projects** via `list_projects()` (line 157-163)
2. **Fetches all tasks per project** via `list_project_tasks(project_gid)` (line 202-212)
   - Returns ALL tasks, including completed ones
3. **Fetches subtasks individually** via `list_task_sub_items(task_gid)` for each parent task (line 215-225)
4. **Creates/updates tasks individually** via `add_item()` and `update_item()`

### Performance Issues Identified

| Issue | Impact | Current Behavior |
|-------|--------|------------------|
| No completion filtering | High | Fetches ALL tasks including completed |
| Individual subtask calls | Medium | N+1 API calls for tasks with subtasks |
| No date-based filtering | Medium | Full sync every time |
| No batch operations | Medium | Individual API calls for mutations |

---

## Asana API Optimization Opportunities

### 1. Filter Completed Tasks with `completed_since`

**Availability:** All Asana users

The Asana API supports a `completed_since` parameter on task list endpoints. Setting `completed_since=now` returns only incomplete tasks.

**Current code** (`lib/asana/service.rb:202-212`):
```ruby
def list_project_tasks(project_gid)
  query = {
    query: {
      opt_fields: Task.requested_fields.join(",")
    }
  }
  # ...
end
```

**Proposed optimization:**
```ruby
def list_project_tasks(project_gid)
  query = {
    query: {
      opt_fields: Task.requested_fields.join(","),
      completed_since: "now"  # Only return incomplete tasks
    }
  }
  # ...
end
```

**Estimated impact:** Could reduce API response size by 50-90% depending on completed task ratio.

**Consideration:** This would only sync incomplete tasks. If bidirectional completion sync is needed, additional logic would be required to track recently completed tasks.

---

### 2. Use `modified_since` for Incremental Sync

**Availability:** All Asana users

The API supports `modified_since` to only fetch tasks modified after a given timestamp.

**Implementation approach:**
1. Store last sync timestamp (already have `min_sync_interval` and `StructuredLogger`)
2. Pass `modified_since` parameter on subsequent syncs
3. First sync (no stored timestamp) fetches all tasks

**Proposed code:**
```ruby
def list_project_tasks(project_gid, since: nil)
  query = {
    query: {
      opt_fields: Task.requested_fields.join(","),
      completed_since: "now"
    }
  }
  query[:query][:modified_since] = since.iso8601 if since.present?
  # ...
end
```

**Estimated impact:** After initial sync, subsequent syncs could be 80-95% faster.

**Known limitations:**
- Some users have reported issues with `modified_since` + section filtering
- Completed tasks may have edge case behaviors

---

### 3. Batch API for Mutations

**Availability:** All Asana users

Asana provides a Batch API at `POST /batch` that allows up to **10 actions per request**.

**Key characteristics:**
- Actions execute in parallel (no guaranteed order)
- Output of one action cannot be input to another
- Each action counts against rate limits individually
- Only for POST/PUT/DELETE operations (not GET)

**Use cases in TaskBridge:**
- Batch create multiple tasks
- Batch update multiple tasks
- Batch section moves

**Example batch request:**
```ruby
def batch_create_tasks(tasks)
  actions = tasks.first(10).map do |task|
    {
      method: "POST",
      relative_path: "/tasks",
      data: Task.from_external(task)
    }
  end

  HTTParty.post("#{base_url}/batch", authenticated_options.merge({
    body: { data: { actions: actions } }.to_json
  }))
end
```

**Estimated impact:** Could reduce create/update API calls by up to 10x for batch operations.

---

### 4. Search API (Premium Only)

**Availability:** Premium Asana users only

The `GET /workspaces/{workspace_gid}/tasks/search` endpoint provides advanced filtering:
- Filter by completion status
- Filter by modified date
- Filter by assignee
- Filter by custom fields

**Limitation:** Non-premium users receive `402 Payment Required`.

**Note:** If premium, this could replace multiple project task list calls with a single search.

---

## Comparison with Other Services

| Service | Date Filtering | Completion Filtering | Batch API |
|---------|---------------|---------------------|-----------|
| **Asana** | `modified_since` (not used) | `completed_since` (not used) | Yes (not used) |
| **GitHub** | `since` ✅ (uses 2 days ago) | `state` parameter | No |
| **Google Tasks** | `showCompleted`, `updatedMin` (not used) | `showHidden` (not used) | No |
| **Instapaper** | N/A | By folder (archive vs unread) | No |

**GitHub already implements date filtering** at `lib/github/service.rb:95`:
```ruby
since: Chronic.parse("2 days ago").iso8601
```

This pattern could be applied to Asana.

---

## Recommended Optimization Strategy

### Phase 1: Quick Wins (Low effort, high impact)

1. **Add `completed_since: "now"` filter**
   - File: `lib/asana/service.rb`
   - Method: `list_project_tasks`
   - Impact: Immediate reduction in data fetched

2. **Add `modified_since` filter**
   - Leverage existing `StructuredLogger` for last sync time
   - Only fetch tasks modified since last successful sync

### Phase 2: Medium Effort

3. **Implement batch API for mutations**
   - Batch task creation when syncing multiple items
   - Batch updates for multiple task changes
   - Limit: 10 operations per batch

4. **Optimize subtask fetching**
   - Consider if subtasks can be included via `opt_fields` expansion
   - Or batch subtask requests

### Phase 3: Architecture Improvements

5. **Apply patterns to Google Tasks**
   - Add `updatedMin` parameter for incremental sync
   - Add `showCompleted=false` if not syncing completed

6. **Standardize incremental sync across services**
   - Create base class method for tracking last sync
   - Implement in all API-based services

---

## Implementation Notes

### Rate Limiting Considerations

Asana has rate limits that count per-action even in batch requests. The optimizations above should **reduce** rate limit pressure by:
- Fetching fewer tasks (completion/date filters)
- Making fewer individual requests (batch API)

### Caching

The current implementation uses `memo_wise` for caching within a sync cycle. This is good but doesn't help across sync cycles. Consider:
- Caching task lists locally with timestamps
- Only refreshing cache when `modified_since` returns changes

### Error Handling

When implementing batch API:
- Individual actions can fail while others succeed
- Response includes status per action
- Need to handle partial failures gracefully

---

## References

- [Asana Batch API Documentation](https://developers.asana.com/docs/batch-requests)
- [Asana Tasks API Reference](https://developers.asana.com/reference/tasks)
- [Get Tasks for Project](https://developers.asana.com/reference/gettasksforproject)
- [Dates and Times in Asana API](https://developers.asana.com/docs/dates-and-times)
- [Forum: Batch API Discussion](https://forum.asana.com/t/introducing-the-batch-api/17748)
