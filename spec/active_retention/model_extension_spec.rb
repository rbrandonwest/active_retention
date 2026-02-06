require 'spec_helper'

RSpec.describe ActiveRetention::ModelExtension do
  describe ".has_retention_policy" do
    it "sets retention_config on the model" do
      expect(Notification.retention_config).to include(
        period: 30.days,
        strategy: :destroy,
        column: "created_at",
        batch_limit: 10_000
      )
    end

    it "supports a custom column" do
      expect(Event.retention_config[:column]).to eq("occurred_at")
    end

    it "defaults batch_limit to 10_000" do
      expect(Notification.retention_config[:batch_limit]).to eq(10_000)
    end

    it "accepts a custom batch_limit" do
      model = Class.new(ActiveRecord::Base) do
        self.table_name = 'notifications'
        has_retention_policy period: 30.days, batch_limit: 500
      end
      expect(model.retention_config[:batch_limit]).to eq(500)
    end

    it "raises on an invalid column" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 30.days, column: :nonexistent
        end
      }.to raise_error(ArgumentError, /Unknown column/)
    end

    it "raises on an invalid strategy" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 30.days, strategy: :unknown
        end
      }.to raise_error(ArgumentError, /Unknown strategy/)
    end

    it "raises when period is dangerously short" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 0.seconds
        end
      }.to raise_error(ArgumentError, /Retention period must be at least/)
    end

    it "raises when period is below the minimum threshold" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 30.minutes
        end
      }.to raise_error(ArgumentError, /Retention period must be at least/)
    end

    it "accepts a period at exactly the minimum threshold" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 1.hour
        end
      }.not_to raise_error
    end

    it "raises on invalid batch_limit" do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'notifications'
          has_retention_policy period: 30.days, batch_limit: -1
        end
      }.to raise_error(ArgumentError, /batch_limit must be a positive integer/)
    end
  end

  describe ".expired_records" do
    it "returns records older than the retention period" do
      old = Notification.create!(title: "old", created_at: 40.days.ago)
      new_record = Notification.create!(title: "new", created_at: 5.days.ago)

      expired = Notification.expired_records
      expect(expired).to include(old)
      expect(expired).not_to include(new_record)
    end

    it "uses the configured column for expiration" do
      old = Event.create!(name: "old", occurred_at: 100.days.ago)
      new_event = Event.create!(name: "new", occurred_at: 5.days.ago)

      expired = Event.expired_records
      expect(expired).to include(old)
      expect(expired).not_to include(new_event)
    end

    it "includes records at the retention boundary due to strict less-than" do
      boundary = Notification.create!(title: "boundary", created_at: 30.days.ago)

      expired = Notification.expired_records
      expect(expired).to include(boundary)
    end
  end

  describe ".cleanup_retention!" do
    context "with :destroy strategy" do
      it "removes old records and keeps new ones" do
        old = Notification.create!(created_at: 40.days.ago)
        new_record = Notification.create!(created_at: 5.days.ago)

        Notification.cleanup_retention!

        expect(Notification.exists?(old.id)).to be false
        expect(Notification.exists?(new_record.id)).to be true
      end

      it "returns the count of destroyed records" do
        Notification.create!(created_at: 40.days.ago)
        Notification.create!(created_at: 50.days.ago)
        Notification.create!(created_at: 5.days.ago)

        result = Notification.cleanup_retention!
        expect(result[:count]).to eq(2)
        expect(result[:dry_run]).to be false
      end

      it "fires model callbacks" do
        normal = Message.create!(body: "normal", created_at: 10.days.ago)
        important = Message.create!(body: "important", important: true, created_at: 10.days.ago)

        Message.cleanup_retention!

        expect(Message.exists?(normal.id)).to be false
        expect(Message.exists?(important.id)).to be true
      end

      it "reports failed destroys separately from successes" do
        Message.create!(body: "normal", created_at: 10.days.ago)
        Message.create!(body: "important", important: true, created_at: 10.days.ago)

        result = Message.cleanup_retention!

        expect(result[:count]).to eq(1)
        expect(result[:failed]).to eq(1)
        expect(result[:dry_run]).to be false
      end

      it "reports zero failures when all destroys succeed" do
        Notification.create!(created_at: 40.days.ago)

        result = Notification.cleanup_retention!
        expect(result[:failed]).to eq(0)
      end
    end

    context "with :delete_all strategy" do
      it "bulk deletes expired records" do
        old = Event.create!(name: "old", occurred_at: 100.days.ago)
        new_event = Event.create!(name: "new", occurred_at: 5.days.ago)

        result = Event.cleanup_retention!

        expect(Event.exists?(old.id)).to be false
        expect(Event.exists?(new_event.id)).to be true
        expect(result[:count]).to eq(1)
      end
    end

    context "with :archive strategy" do
      before do
        Notification.retention_config[:strategy] = :archive
      end

      after do
        Notification.retention_config[:strategy] = :destroy
      end

      it "moves expired records to the archive table and deletes originals" do
        old = Notification.create!(title: "archived", created_at: 40.days.ago)
        Notification.create!(title: "kept", created_at: 5.days.ago)

        result = Notification.cleanup_retention!

        expect(Notification.exists?(old.id)).to be false
        archived = ActiveRecord::Base.connection.select_all("SELECT * FROM notifications_archive")
        expect(archived.rows.length).to eq(1)
        expect(result[:count]).to eq(1)
      end

      it "preserves all original column values in the archive" do
        Notification.create!(title: "my title", active: false, created_at: 40.days.ago)

        Notification.cleanup_retention!

        row = ActiveRecord::Base.connection.select_one("SELECT title, active FROM notifications_archive LIMIT 1")
        expect(row["title"]).to eq("my title")
        expect(row["active"]).to eq(0).or eq(false)
      end

      it "raises ArchiveTableMissing when the archive table does not exist" do
        Event.retention_config[:strategy] = :archive

        Event.create!(name: "old", occurred_at: 100.days.ago)

        expect { Event.cleanup_retention! }.to raise_error(
          ActiveRetention::ArchiveTableMissing,
          /events_archive.*does not exist/
        )

        expect(Event.count).to eq(1)
      ensure
        Event.retention_config[:strategy] = :delete_all
      end

      it "rolls back the batch if the archive insert fails" do
        old = Notification.create!(title: "should survive", created_at: 40.days.ago)

        ActiveRecord::Base.connection.drop_table(:notifications_archive)

        begin
          Notification.cleanup_retention!
        rescue StandardError
          # Expected to fail
        end

        expect(Notification.exists?(old.id)).to be true
      ensure
        ActiveRecord::Base.connection.create_table :notifications_archive, id: :integer, force: true do |t|
          t.string :title
          t.boolean :active, default: true
          t.datetime :created_at
          t.datetime :updated_at
          t.datetime :archived_at, default: -> { 'CURRENT_TIMESTAMP' }
        end
      end

      it "archives many records correctly with INSERT chunking" do
        60.times { |i| Notification.create!(title: "record_#{i}", created_at: 40.days.ago) }

        result = Notification.cleanup_retention!

        expect(result[:count]).to eq(60)
        expect(Notification.expired_records.count).to eq(0)

        archived = ActiveRecord::Base.connection.select_all("SELECT * FROM notifications_archive")
        expect(archived.rows.length).to eq(60)
      end
    end

    context "with batch_limit" do
      it "caps :destroy strategy to batch_limit records" do
        Notification.retention_config[:batch_limit] = 2

        5.times { Notification.create!(created_at: 40.days.ago) }

        result = Notification.cleanup_retention!

        expect(result[:count]).to eq(2)
        expect(result[:remaining]).to be true
        expect(Notification.count).to eq(3)
      ensure
        Notification.retention_config[:batch_limit] = 10_000
      end

      it "caps :delete_all strategy to batch_limit records" do
        Event.retention_config[:batch_limit] = 2

        5.times { Event.create!(name: "old", occurred_at: 100.days.ago) }

        result = Event.cleanup_retention!

        expect(result[:count]).to eq(2)
        expect(result[:remaining]).to be true
        expect(Event.count).to eq(3)
      ensure
        Event.retention_config[:batch_limit] = 10_000
      end

      it "caps :archive strategy to batch_limit records" do
        Notification.retention_config[:strategy] = :archive
        Notification.retention_config[:batch_limit] = 2

        5.times { Notification.create!(title: "old", created_at: 40.days.ago) }

        result = Notification.cleanup_retention!

        expect(result[:count]).to eq(2)
        expect(result[:remaining]).to be true
        expect(Notification.count).to eq(3)

        archived = ActiveRecord::Base.connection.select_all("SELECT * FROM notifications_archive")
        expect(archived.rows.length).to eq(2)
      ensure
        Notification.retention_config[:strategy] = :destroy
        Notification.retention_config[:batch_limit] = 10_000
      end

      it "reports remaining: false when all expired records are processed" do
        Notification.create!(created_at: 40.days.ago)

        result = Notification.cleanup_retention!

        expect(result[:remaining]).to be false
      end
    end

    context "with dry_run" do
      it "returns the total expired count without deleting" do
        Notification.create!(created_at: 40.days.ago)
        Notification.create!(created_at: 50.days.ago)

        result = Notification.cleanup_retention!(dry_run: true)

        expect(result).to eq({ count: 2, dry_run: true })
        expect(Notification.count).to eq(2)
      end
    end

    context "with a filter" do
      it "only cleans up records matching the filter" do
        Notification.retention_config[:filter] = -> { where(active: false) }

        old_active = Notification.create!(created_at: 40.days.ago, active: true)
        old_inactive = Notification.create!(created_at: 40.days.ago, active: false)

        Notification.cleanup_retention!

        expect(Notification.exists?(old_active.id)).to be true
        expect(Notification.exists?(old_inactive.id)).to be false
      ensure
        Notification.retention_config[:filter] = nil
      end
    end

    context "when no retention config is set" do
      it "returns nil" do
        model = Class.new(ActiveRecord::Base) { self.table_name = 'notifications' }
        expect(model.cleanup_retention!).to be_nil
      end
    end

    context "when there are no expired records" do
      it "returns a zero count for :destroy strategy" do
        Notification.create!(created_at: 5.days.ago)

        result = Notification.cleanup_retention!
        expect(result[:count]).to eq(0)
        expect(result[:failed]).to eq(0)
        expect(result[:remaining]).to be false
      end

      it "returns a zero count for :delete_all strategy" do
        Event.create!(name: "new", occurred_at: 5.days.ago)

        result = Event.cleanup_retention!
        expect(result[:count]).to eq(0)
        expect(result[:remaining]).to be false
      end
    end

    context "with concurrent cleanup (advisory locking)" do
      it "returns skipped result when lock is already held" do
        # Grab the mutex that SQLite adapter falls back to
        mutex = Mutex.new
        Notification.instance_variable_set(:@_retention_mutex, mutex)

        # Hold the lock from another thread
        mutex.lock

        result = Notification.cleanup_retention!

        expect(result[:skipped]).to be true
        expect(result[:reason]).to eq(:locked)
        expect(result[:count]).to eq(0)
      ensure
        mutex.unlock if mutex.owned?
        Notification.instance_variable_set(:@_retention_mutex, nil)
      end

      it "does not include skipped key in a normal (unlocked) result" do
        Notification.create!(created_at: 40.days.ago)

        result = Notification.cleanup_retention!

        expect(result).not_to have_key(:skipped)
      end
    end
  end
end
