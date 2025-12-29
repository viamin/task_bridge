# Issue #149: Duplicate Tasks Appearing in Asana After Sync

## Summary

This document investigates the root causes of duplicate tasks appearing in Asana when syncing shopping lists (or other lists with repeated item titles) between OmniFocus and Asana.

## Problem Statement

When syncing a Shopping List between OmniFocus and Asana, multiple copies of the same item appear in Asana. This is particularly problematic for lists that naturally contain repeated items (e.g., "Milk" purchased weekly), where completed tasks with the same title may be reactivated or new duplicates created.

## Root Cause Analysis

### The Matching Algorithm

The core issue lies in how items are matched between services. The matching logic in `lib/base/sync_item.rb:65-76` uses a two-step approach:

1. **Sync ID matching** (preferred): Looks for stored sync IDs in task notes (e.g., `asana_id: 1234567890`)
2. **Title matching** (fallback): Case-insensitive exact title comparison

```ruby
def find_matching_item_in(collection)
  return if collection.blank?

  external_id = :"#{collection.first.provider.underscore}_id"
  service_id = :"#{provider.underscore}_id"
  id_match = collection.find { |item|
    (item.id && (item.id == try(external_id))) ||
    (item.try(service_id) && (item.try(service_id) == id))
  }
  return id_match if id_match

  collection.find do |item|
    friendly_title_matches(item)
  end
end
```

**Critical Issue**: The `.find` method returns the **FIRST** match, which is problematic when multiple items share the same title.

### The Completed Task Window

Asana fetches tasks completed within the last 7 days (`lib/asana/service.rb:312-314`):

```ruby
def completed_since_timestamp
  Chronic.parse("1 week ago").iso8601
end
```

This means recently completed tasks are included in the matching pool, creating opportunities for incorrect pairing.

### Duplicate Creation Scenarios

#### Scenario 1: Wrong Pairing Leaves Items Unmatched

1. OmniFocus has: "Milk" (active, no sync ID yet)
2. Asana has:
   - "Milk" #1 (completed 3 days ago)
   - "Milk" #2 (active, previously synced from OmniFocus)
3. During sync:
   - OmniFocus "Milk" title-matches Asana "Milk" #1 (first match in collection)
   - Both are now "paired"
   - Asana "Milk" #2 remains **UNMATCHED**
4. Unmatched Asana items are created in OmniFocus
5. **Result**: A duplicate "Milk" appears in OmniFocus

#### Scenario 2: Completed Task Gets Updated Instead of Creating New

1. "Milk" completed in Asana (within last 7 days)
2. User creates new "Milk" in OmniFocus
3. New OmniFocus "Milk" has no sync ID
4. Title matching pairs it with the completed Asana "Milk"
5. The completed task gets updated (potentially uncompleted)
6. **Result**: Unexpected behavior - completed tasks "reappear"

#### Scenario 3: Multiple Active Items With Same Title

1. User intentionally creates two "Milk" tasks in OmniFocus (different shopping trips)
2. First sync: "Milk" #1 creates Asana task
3. Second sync: "Milk" #2 tries to find a match
4. It matches "Milk" #1 by title (wrong item)
5. **Result**: Updates wrong task instead of creating new one

### Sync IDs Not Added During Updates (Compounding Problem)

A critical compounding issue: **sync IDs are not added when updating existing items** by default.

Looking at `settings.yml:11`:
```yaml
update_ids_for_existing_items: false
```

When a NEW item is created via `add_item`, sync IDs are always added:
```ruby
# lib/asana/service.rb:73
update_sync_data(external_task, new_task.id, new_task.url)  # Always called
```

But when an EXISTING item is updated via `update_item`, sync IDs are conditional:
```ruby
# lib/asana/service.rb:113
update_sync_data(...) if options[:update_ids_for_existing]  # Only if option enabled!
```

This creates a compounding problem:

1. New OmniFocus "Milk" has no sync ID (it's brand new)
2. Title matches completed Asana "Milk"
3. `update_item` is called, reactivating the Asana task
4. **No sync ID is added** because `update_ids_for_existing: false`
5. Next sync: OmniFocus "Milk" still has no sync ID
6. Title matching happens again → same problem repeats indefinitely

Items that match by title **never graduate to sync ID matching** unless `update_ids_for_existing` is enabled. They're stuck relying on fragile title matching forever.

### Completed Tasks Get Reactivated

When a new OmniFocus task title-matches a completed Asana task, the update payload includes completion status (`lib/asana/task.rb:71-81`):

```ruby
def from_external(external_item)
  {
    completed: external_item.completed?,  # <-- Sends false for active tasks
    # ...
  }.compact
end
```

This means the completed Asana task gets **reactivated** - it's not just a metadata update, the task literally comes back from the dead. This is the "zombie task" behavior described in the issue.

### The Pairing Flow

The sync process in `lib/base/service.rb:44-79` follows this pattern:

```ruby
def sync_with_primary(primary_service)
  primary_items = primary_service.items_to_sync(tags: [friendly_name])
  service_items = items_to_sync(tags: options[:tags])
  item_pairs = paired_items(primary_items, service_items)
  unmatched_primary_items = primary_items - item_pairs.to_a.flatten
  unmatched_service_items = service_items - item_pairs.to_a.flatten

  # Update paired items (older with newer)
  item_pairs.each { |pair| ... }

  # Create unmatched primary items in service
  unmatched_primary_items.each { |item| add_item(item) unless skip_create?(item) }

  # Create unmatched service items in primary
  unmatched_service_items.each { |item| primary_service.add_item(item) unless skip_create?(item) }
end
```

The problem emerges in the pairing step: incorrect pairing leaves legitimate items unmatched, causing them to be created as "new" items.

## Key Files and Line Numbers

| Component | File | Lines |
|-----------|------|-------|
| Item matching | `lib/base/sync_item.rb` | 65-76 |
| Title comparison | `lib/base/sync_item.rb` | 82-84 |
| Two-way sync | `lib/base/service.rb` | 44-79 |
| Item pairing | `lib/base/service.rb` | 174-186 |
| Skip create logic | `lib/base/service.rb` | 164-169 |
| Completed task filter | `lib/asana/service.rb` | 312-314 |
| Asana items_to_sync | `lib/asana/service.rb` | 34-54 |
| Sync ID update (conditional) | `lib/asana/service.rb` | 113 |
| Update IDs setting | `settings.yml` | 11 |
| Asana from_external | `lib/asana/task.rb` | 71-81 |

## Proposed Solutions

### Option 1: Prefer Sync ID Matching, Require for Updates (Recommended)

Modify the matching logic to be stricter:
- If a sync ID exists on the source item, only match by sync ID
- If no sync ID, allow title matching but only for creating new items (not updating)

```ruby
def find_matching_item_in(collection, strict: false)
  return if collection.blank?

  external_id = :"#{collection.first.provider.underscore}_id"
  service_id = :"#{provider.underscore}_id"

  # If we have a sync ID, only match by ID
  has_sync_id = try(external_id).present?

  id_match = collection.find { |item|
    (item.id && (item.id == try(external_id))) ||
    (item.try(service_id) && (item.try(service_id) == id))
  }
  return id_match if id_match

  # Only fall back to title matching if we don't have a sync ID
  # or if not in strict mode
  return nil if has_sync_id || strict

  collection.find { |item| friendly_title_matches(item) }
end
```

### Option 2: Exclude Completed Items from Title Matching

Only allow completed items to match via sync ID, never by title:

```ruby
collection.find do |item|
  friendly_title_matches(item) && item.incomplete?
end
```

### Option 3: Add Deduplication Setting Per List/Project

Add a configuration option to disable title matching for specific projects:

```yaml
# settings.yml
asana:
  projects:
    "Shopping List":
      matching_strategy: :sync_id_only
```

### Option 4: Smarter Title Matching

Consider additional attributes when title matching:
- Completion status
- Creation date proximity
- Project/section

```ruby
def find_best_title_match(collection)
  candidates = collection.select { |item| friendly_title_matches(item) }
  return nil if candidates.empty?

  # Prefer incomplete items
  incomplete = candidates.select(&:incomplete?)
  return incomplete.first if incomplete.any?

  # If all completed, prefer most recently completed
  candidates.max_by(&:completed_at)
end
```

### Option 5: Reduce Completed Task Window

Reduce `completed_since` from 1 week to a shorter period (e.g., 1 day) to minimize the chance of matching old completed tasks:

```ruby
def completed_since_timestamp
  Chronic.parse("1 day ago").iso8601
end
```

This reduces the window but doesn't eliminate the core issue.

### Option 6: Always Add Sync IDs on Title Match (Implemented)

When items are paired by title (not by sync ID), always add sync IDs so future syncs use ID matching. This "graduates" title-matched pairs to ID-matched pairs.

**Implementation:** In each service's `update_item`, detect title matches by checking if the external task lacks our sync ID:

```ruby
# If external_task doesn't have our sync ID, this was a title match
# Add sync ID so future syncs use ID matching instead of title matching
matched_by_title = external_task.try(:asana_id).blank?
if matched_by_title || options[:update_ids_for_existing]
  update_sync_data(external_task, asana_task.id, asana_task.url)
end
```

Applied to: Asana, OmniFocus, Reclaim, Reminders services.

### Option 7: Exclude Items with Sync IDs from Title Matching (Implemented)

Only allow title matching if **NEITHER** item has a sync_id for the other service. Items that are already linked to something (have a sync_id) should only match by ID, never by title.

**Rationale:** If an item has a sync_id, it's already linked to another item. It shouldn't be "stolen" by a new item via title matching.

```ruby
def find_matching_item_in(collection)
  return if collection.blank?

  external_id = :"#{collection.first.provider.underscore}_id"
  service_id = :"#{provider.underscore}_id"
  id_match = collection.find { |item| ... }
  return id_match if id_match

  # Only allow title matching if we don't have their sync ID
  return if try(external_id).present?

  collection.find do |item|
    # Only match items that don't have our sync ID
    friendly_title_matches(item) && item.try(service_id).blank?
  end
end
```

**Scenarios:**

| Source Item | Target Item | Title Match? | Outcome |
|-------------|-------------|--------------|---------|
| no sync_id | no sync_id | ✓ Yes | Link them (first sync) |
| has sync_id | has sync_id (matching) | N/A | ID match succeeds |
| no sync_id | has sync_id (to other) | ✗ No | Create new target |
| has sync_id (stale) | no sync_id | ✗ No | Create new target |
| has sync_id | has sync_id (non-matching) | ✗ No | Both linked elsewhere |

## Implemented Solution

### Option 6: Always Add Sync IDs on Title Match ✓

**Status:** Implemented in commit `325a88e`

Changes made to `update_item` in:
- `lib/asana/service.rb`
- `lib/omnifocus/service.rb`
- `lib/reclaim/service.rb`
- `lib/reminders/service.rb`

### Option 7: Exclude Items with Sync IDs from Title Matching ✓

**Status:** Implemented

Changes made to `find_matching_item_in` in:
- `lib/base/sync_item.rb`

### How They Work Together

1. **First sync of new items:** Both lack sync IDs → title match allowed → they get linked and sync IDs added
2. **Future syncs of linked items:** Both have sync IDs → ID match succeeds → no title matching needed
3. **New item with same title:** New item has no sync ID, but old item has sync ID → title match blocked → new item created separately
4. **Each new "Buy milk" creates a fresh task** instead of reactivating old completed ones

### Future Enhancements

- **Option 3:** Add per-project matching strategy settings for users who want stricter control

## Testing Recommendations

Add specs for `find_matching_item_in` covering:
1. Multiple items with same title (active and completed)
2. Items with sync IDs vs without
3. Mixed scenarios with partial sync ID coverage
4. Edge cases: whitespace differences, case sensitivity

## Conclusion

The duplicate task issue stemmed from two interrelated problems:

1. **Title matching was too permissive**: Items with sync IDs (already linked to other items) could still be matched by title, causing new items to "steal" existing links.

2. **Sync IDs not added during updates**: With `update_ids_for_existing: false` (the default), items matched by title never got sync IDs added. They remained stuck on fragile title matching forever.

### Implemented Fix

Two complementary changes were made:

1. **Option 6 - Always add sync IDs on title match**: When `update_item` detects a title match (external task lacks our sync ID), it now adds the sync ID. This ensures title-matched pairs "graduate" to ID matching.

2. **Option 7 - Exclude items with sync IDs from title matching**: Title matching now only occurs if NEITHER item has a sync_id for the other service. Items already linked to something can only be matched by ID.

Together, these ensure:
- First-time syncs work via title matching
- Subsequent syncs use reliable ID matching
- New items with duplicate titles create new tasks instead of hijacking existing linked pairs
