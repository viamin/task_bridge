# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Setup
```bash
bundle install
```

### Running the Application
```bash
ruby bin/task_bridge
# or
ruby lib/task_bridge.rb
```

### View Available Options
```bash
ruby bin/task_bridge --help
```

### Testing
```bash
bundle exec rspec
# Run specific test file
bundle exec rspec spec/lib/omnifocus/service_spec.rb
# Run with focus on specific examples
bundle exec rspec --tag focus
```

### Code Quality
```bash
bundle exec rubocop
bundle exec standard
```

## Architecture Overview

TaskBridge is a Ruby application that synchronizes tasks between multiple productivity services. It supports bidirectional sync between a primary service (typically OmniFocus) and various other services like GitHub, Google Tasks, Asana, Instapaper, and Reclaim.ai.

### Core Components

**Service Architecture**: All services inherit from `Base::Service` (`lib/base/service.rb`), which provides three sync strategies:
- `:two_way` - Full bidirectional sync using `sync_with_primary`
- `:from_primary` - Sync from primary service using `sync_from_primary`
- `:to_primary` - Sync to primary service using `sync_to_primary`

**Item Architecture**: All task-like objects inherit from `Base::SyncItem` (`lib/base/sync_item.rb`), which handles:
- Attribute mapping from service-specific formats to common format
- Sync ID management for linking items across services
- Note parsing to extract sync metadata
- Matching logic to find corresponding items across services

**Service Types**:
- **Provider Services** (`Github`, `Instapaper`, `Asana`): Services that provide items to become tasks in the primary service
- **Task Services** (`Asana`, `GoogleTasks`, `Omnifocus`, `Reclaim`, `Reminders`): Services with task-like objects that sync with the primary service

### Key Files

- `lib/task_bridge.rb` - Main application entry point with CLI option parsing
- `lib/base/service.rb` - Abstract base class for all services
- `lib/base/sync_item.rb` - Abstract base class for all sync items
- `lib/structured_logger.rb` - Logging and sync history management
- `lib/note_parser.rb` - Parses sync metadata from task notes
- `settings.yml` - Default configuration settings

### Service Implementation Pattern

Each service implements:
1. A `Service` class inheriting from `Base::Service`
2. A task/item class inheriting from `Base::SyncItem`
3. Required methods: `friendly_name`, `item_class`, `sync_strategies`, `items_to_sync`
4. Optional methods: `add_item`, `update_item`, `patch_item`, `prune` for cleanup

### Sync Process Flow

1. **Item Collection**: Each service gathers items marked with sync tags
2. **Item Matching**: Items are matched between services using sync IDs or title matching
3. **Sync Direction**: Based on modification timestamps, newer items update older ones
4. **Metadata Management**: Sync IDs and URLs are stored in item notes for future matching
5. **Logging**: All sync operations are logged for debugging and history

### Configuration

- Primary configuration in `settings.yml`
- Service-specific credentials in separate files (e.g., `google_api_client_credentials.json`)
- Environment variables supported via `chamber` gem
- Command-line options override configuration file settings

### Authentication

Each service handles its own authentication:
- **GitHub**: OAuth token generated on first run
- **Google Tasks**: OAuth credentials file + generated token
- **Asana**: Personal access token
- **Reclaim.ai**: API key extracted from browser cookies
- **OmniFocus**: Uses AppleScript (macOS only)
- **Reminders**: Uses AppleScript (macOS only)

### Tag-Based Sync Control

Items are synced based on tags/labels:
- Items with service-specific tags (e.g., "GitHub", "Google Tasks") are synced to that service
- Items with "TaskBridge" tag are eligible for sync
- Personal/work context tags can be configured to control sync scope

### macOS Integration

Includes launchd plist files for automated execution:
- `com.github.viamin.task_bridge.plist` - Hourly sync between 7am-10pm
- `com.github.viamin.task_bridge.cleanup.plist` - Cleanup completed tasks

## Ruby Environment

- Ruby version: 3.1.2
- Uses `frozen_string_literal: true` across all files
- Key gems: `activesupport`, `optimist`, `httparty`, `rb-scpt`, `memo_wise`