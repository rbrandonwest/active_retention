# ActiveRetention

Automatic data retention and purging for ActiveRecord models. Define how long records should live, choose what happens when they expire, and let ActiveRetention handle the cleanup.

Built for production use at any scale — includes batch limiting, advisory locking, transactional archiving, and automatic backlog processing.

## Installation

Add the gem to your Gemfile:

```ruby
gem 'active_retention'
```

Then run:

```sh
bundle install
```

ActiveRetention automatically integrates with Rails via a Railtie. No additional setup is needed. See [Configuration](#configuration) if you prefer opt-in inclusion.

## Quick Start

```ruby
class Notification < ApplicationRecord
  has_retention_policy period: 30.days, strategy: :destroy
end
```

```ruby
# Remove all notifications older than 30 days
Notification.cleanup_retention!
# => { count: 42, failed: 0, remaining: false, dry_run: false }
```

## Defining a Retention Policy

Call `has_retention_policy` in any ActiveRecord model to configure how expired records are handled.

```ruby
has_retention_policy(
  period:,              # Required — how long records are kept (e.g. 30.days, 1.year)
  strategy: :destroy,   # Optional — :destroy, :delete_all, or :archive
  column: :created_at,  # Optional — timestamp column used to determine age
  if: nil,              # Optional — lambda to further filter which records are eligible
  batch_limit: 10_000   # Optional — max records processed per cleanup call
)
```

### Options

#### `period` (required)

An `ActiveSupport::Duration` representing the maximum age of a record. Records whose timestamp column is older than `period.ago` are considered expired.

The minimum allowed period is **1 hour** to prevent accidental mass deletion.

```ruby
has_retention_policy period: 90.days
has_retention_policy period: 1.year
has_retention_policy period: 6.hours
```

#### `strategy` (optional, default: `:destroy`)

Determines how expired records are removed.

| Strategy      | Behavior                                                                 | Callbacks | Speed  |
|---------------|--------------------------------------------------------------------------|-----------|--------|
| `:destroy`    | Loads each record and calls `destroy`, one at a time via `find_each`     | Yes       | Slow   |
| `:delete_all` | Bulk deletes matching records by plucking IDs, then issuing `DELETE`      | No        | Fast   |
| `:archive`    | Copies records to an archive table in batches, then deletes the originals| No        | Medium |

```ruby
# Triggers model callbacks and dependent: :destroy associations
has_retention_policy period: 30.days, strategy: :destroy

# Fast bulk delete, skips callbacks entirely
has_retention_policy period: 30.days, strategy: :delete_all

# Preserve historical data before removing from the primary table
has_retention_policy period: 30.days, strategy: :archive
```

**Note on `:destroy`**: If a `before_destroy` callback throws `:abort`, the record is preserved and counted as a failure in the return value. This means records protected by callbacks will never be silently deleted.

#### `column` (optional, default: `:created_at`)

The timestamp column used to determine whether a record has expired. Must be a valid column on the model's table. An `ArgumentError` is raised at boot time if the column does not exist.

```ruby
class Event < ApplicationRecord
  has_retention_policy period: 90.days, column: :occurred_at
end
```

#### `if` (optional)

A lambda that returns an ActiveRecord scope. When provided, only expired records that also match this scope are eligible for cleanup.

The lambda is evaluated in the context of the model's scope, so you can call query methods like `where` directly.

```ruby
class Notification < ApplicationRecord
  has_retention_policy period: 30.days, strategy: :destroy, if: -> { where(read: true) }
end
```

This will only clean up notifications that are both older than 30 days **and** marked as read.

#### `batch_limit` (optional, default: `10_000`)

The maximum number of records that will be processed in a single `cleanup_retention!` call. This prevents any single cleanup run from consuming unbounded time, memory, or database resources.

```ruby
# Process at most 5,000 records per run
has_retention_policy period: 30.days, strategy: :destroy, batch_limit: 5_000

# Large batch for fast delete_all on tables with many expired records
has_retention_policy period: 7.days, strategy: :delete_all, batch_limit: 50_000
```

When the limit is reached, the return value includes `remaining: true` so callers know there are more records to process. The `PurgeJob` automatically re-enqueues itself to handle this (see [Background Job](#background-job)).

## Running Cleanup

### Manual Cleanup

Call `cleanup_retention!` on any model with a retention policy:

```ruby
Notification.cleanup_retention!
# => { count: 42, failed: 0, remaining: false, dry_run: false }
```

The method returns a hash with:

| Key         | Type    | Description |
|-------------|---------|-------------|
| `count`     | Integer | Records actually removed |
| `failed`    | Integer | Records where `destroy` returned false (`:destroy` strategy only) |
| `remaining` | Boolean | `true` if more expired records exist beyond the `batch_limit` |
| `dry_run`   | Boolean | Whether this was a dry run |
| `skipped`   | Boolean | Present and `true` only if another process holds the cleanup lock |
| `reason`    | Symbol  | `:locked` when `skipped` is true |

### Dry Run

Preview how many expired records exist without deleting anything:

```ruby
Notification.cleanup_retention!(dry_run: true)
# => { count: 42, dry_run: true }
```

The `count` in dry run mode reflects the **total** number of expired records, regardless of `batch_limit`.

### Background Job

ActiveRetention ships with `ActiveRetention::PurgeJob`, an ActiveJob class that finds and cleans up all models with retention policies.

```ruby
ActiveRetention::PurgeJob.perform_later
```

The job:
- **Eager-loads** all application models (if not already loaded) to discover every class with a retention policy
- **Iterates** through each configured model and calls `cleanup_retention!`
- **Logs** progress, record counts, and any errors to `Rails.logger`
- **Rescues** errors per-model so that a failure in one model does not halt cleanup of others
- **Skips** models that are already locked by another process (see [Concurrency Safety](#concurrency-safety))
- **Auto-re-enqueues** when any model still has remaining expired records, up to 10 rounds per invocation

The re-enqueue behavior ensures that large backlogs are fully cleared without waiting for the next scheduled run. The 10-round cap prevents infinite loops if records are being created faster than they can be purged.

The job is queued as `:maintenance`. To run it on a recurring schedule, use a scheduler like [sidekiq-cron](https://github.com/sidekiq-cron/sidekiq-cron), [solid_queue](https://github.com/rails/solid_queue), or [whenever](https://github.com/javan/whenever):

```ruby
# Example with sidekiq-cron
Sidekiq::Cron::Job.create(
  name: 'ActiveRetention purge - daily',
  cron: '0 3 * * *',
  class: 'ActiveRetention::PurgeJob'
)
```

## Concurrency Safety

ActiveRetention uses **database-level advisory locks** to prevent concurrent cleanup of the same model. This protects against:
- Duplicate archive rows from two processes archiving the same records
- Attempting to destroy already-deleted records
- Wasted work from overlapping cleanup runs

| Database   | Lock Mechanism                           |
|------------|------------------------------------------|
| PostgreSQL | `pg_try_advisory_lock` / `pg_advisory_unlock` |
| MySQL      | `GET_LOCK` / `RELEASE_LOCK`              |
| SQLite     | Ruby `Mutex` (in-process only)           |

Locks are **non-blocking**: if a lock is already held, `cleanup_retention!` returns immediately with `{ skipped: true, reason: :locked }` instead of waiting. This means the `PurgeJob` never stalls — it simply skips the locked model and moves on.

## Scopes

Declaring a retention policy adds an `expired_records` scope to the model. You can use this scope independently of cleanup:

```ruby
Notification.expired_records
# => ActiveRecord::Relation of all notifications older than 30 days

Notification.expired_records.count
# => 42
```

## Archive Strategy

The `:archive` strategy copies expired records into a separate archive table before deleting the originals. This is useful when you need to enforce retention limits on your primary table but want to preserve historical data for auditing or analytics.

### How It Works

1. Before archiving begins, ActiveRetention verifies the archive table exists. If it doesn't, an `ActiveRetention::ArchiveTableMissing` error is raised with instructions to generate it — no records are touched.
2. Expired records are loaded in batches (up to 500 records or the `batch_limit`, whichever is smaller).
3. Within a database transaction for each batch:
   - Record attributes (except `id`) are inserted into the archive table in sub-batches of 50 rows to avoid oversized SQL statements
   - The original records are deleted from the primary table
   - If either the insert or delete fails, the **entire batch is rolled back** — originals are never lost
4. The archive table automatically receives an `archived_at` timestamp.

### Generating the Archive Table

Use the built-in Rails generator to create a migration for the archive table:

```sh
rails generate active_retention:archive Notification
```

This generates a migration that creates a `notifications_archive` table mirroring all columns from `notifications` (except `id`), plus an `archived_at` timestamp column. The table uses `bigserial` for its own primary key and includes indexes on `created_at` and `archived_at`.

Then run the migration:

```sh
rails db:migrate
```

**Important**: You must run the generator and migration before using `strategy: :archive`. If the archive table is missing, `cleanup_retention!` will raise `ActiveRetention::ArchiveTableMissing` rather than silently failing.

### Archive Table Naming

The archive table name is derived automatically from the model's table name:

| Model Table     | Archive Table            |
|-----------------|--------------------------|
| `notifications` | `notifications_archive`  |
| `events`        | `events_archive`         |
| `audit_logs`    | `audit_logs_archive`     |

## Validation

ActiveRetention validates all configuration at definition time (when your Rails app boots), not at cleanup time. Invalid configuration raises `ArgumentError` immediately:

```ruby
# Raises ArgumentError — column doesn't exist on the table
has_retention_policy period: 30.days, column: :nonexistent

# Raises ArgumentError — unknown strategy
has_retention_policy period: 30.days, strategy: :soft_delete

# Raises ArgumentError — period too short (minimum is 1 hour)
has_retention_policy period: 30.seconds

# Raises ArgumentError — batch_limit must be a positive integer
has_retention_policy period: 30.days, batch_limit: -1
```

## STI Support

Retention configs are defined using `class_attribute`, which means they are inherited by subclasses. If you use Single Table Inheritance, the parent's retention policy applies to all subclasses unless explicitly overridden:

```ruby
class Notification < ApplicationRecord
  has_retention_policy period: 30.days, strategy: :destroy
end

class AdminNotification < Notification
  # Inherits the 30-day destroy policy from Notification
end

class SystemAlert < Notification
  # Override with a longer retention period
  has_retention_policy period: 1.year, strategy: :archive
end
```

## Configuration

### Auto-Include (default: enabled)

By default, ActiveRetention automatically includes itself into all ActiveRecord models via a Railtie. This adds a single `class_attribute` (`retention_config`, defaulting to `nil`) and makes `has_retention_policy` available everywhere. No cleanup runs unless you explicitly call `has_retention_policy` on a model.

If you prefer to opt in per model, disable auto-include in an initializer:

```ruby
# config/initializers/active_retention.rb
ActiveRetention.configure do |config|
  config.auto_include = false
end
```

Then include the module explicitly on each model that needs it:

```ruby
class Notification < ApplicationRecord
  include ActiveRetention::ModelExtension
  has_retention_policy period: 30.days, strategy: :destroy
end
```

## Full Example

```ruby
class AuditLog < ApplicationRecord
  has_retention_policy period: 1.year,
                       strategy: :archive,
                       column: :created_at,
                       batch_limit: 25_000
end

class Session < ApplicationRecord
  has_retention_policy period: 24.hours,
                       strategy: :delete_all,
                       batch_limit: 50_000
end

class Notification < ApplicationRecord
  has_retention_policy period: 30.days,
                       strategy: :destroy,
                       if: -> { where(read: true) }
end
```

```ruby
# Preview what would be cleaned up (reports total, ignores batch_limit)
AuditLog.cleanup_retention!(dry_run: true)
# => { count: 150_204, dry_run: true }

# Run cleanup (processes up to 25,000 per call)
AuditLog.cleanup_retention!
# => { count: 25_000, remaining: true, dry_run: false }

# Or clean up everything via the background job (auto-re-enqueues until clear)
ActiveRetention::PurgeJob.perform_later
```
