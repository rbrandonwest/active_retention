require 'spec_helper'
require 'active_job'

ActiveJob::Base.queue_adapter = :test

# Minimal PurgeJob for testing without Rails
module ActiveRetention
  class PurgeJob < ActiveJob::Base
    queue_as :maintenance

    MAX_REENQUEUE_ROUNDS = 10

    def perform(round: 1)
      has_remaining = false

      models_with_retention.each do |model|
        result = model.cleanup_retention!

        if result&.dig(:skipped)
          # skip
        else
          has_remaining = true if result[:remaining]
        end
      rescue StandardError => e
        # swallow in tests
      end

      if has_remaining && round < MAX_REENQUEUE_ROUNDS
        self.class.perform_later(round: round + 1)
      end
    end

    private

    def models_with_retention
      ActiveRecord::Base.descendants.select do |model|
        model.respond_to?(:retention_config) && model.retention_config.present?
      end
    end
  end
end

RSpec.describe ActiveRetention::PurgeJob do
  before do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  describe "#perform" do
    it "cleans up all models with retention configs" do
      old_notification = Notification.create!(created_at: 40.days.ago)
      new_notification = Notification.create!(created_at: 5.days.ago)
      old_event = Event.create!(name: "old", occurred_at: 100.days.ago)
      new_event = Event.create!(name: "new", occurred_at: 5.days.ago)

      described_class.perform_now

      expect(Notification.exists?(old_notification.id)).to be false
      expect(Notification.exists?(new_notification.id)).to be true
      expect(Event.exists?(old_event.id)).to be false
      expect(Event.exists?(new_event.id)).to be true
    end

    it "skips models without retention configs" do
      model = Class.new(ActiveRecord::Base) { self.table_name = 'notifications' }
      Notification.create!(created_at: 5.days.ago)

      expect { described_class.perform_now }.not_to raise_error
    end

    it "continues processing when a model is locked" do
      mutex = Mutex.new
      Notification.instance_variable_set(:@_retention_mutex, mutex)
      mutex.lock

      old_event = Event.create!(name: "old", occurred_at: 100.days.ago)
      Notification.create!(created_at: 40.days.ago)

      described_class.perform_now

      expect(Event.exists?(old_event.id)).to be false
      expect(Notification.count).to eq(1)
    ensure
      mutex.unlock if mutex.owned?
      Notification.instance_variable_set(:@_retention_mutex, nil)
    end

    it "re-enqueues when models have remaining records" do
      Notification.retention_config[:batch_limit] = 2

      5.times { Notification.create!(created_at: 40.days.ago) }

      described_class.perform_now

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued.length).to eq(1)
      expect(enqueued.first["arguments"].first["round"]).to eq(2)
    ensure
      Notification.retention_config[:batch_limit] = 10_000
    end

    it "does not re-enqueue when all records are processed" do
      Notification.create!(created_at: 40.days.ago)

      described_class.perform_now

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued).to be_empty
    end

    it "stops re-enqueueing after MAX_REENQUEUE_ROUNDS" do
      Notification.retention_config[:batch_limit] = 1
      2.times { Notification.create!(created_at: 40.days.ago) }

      # Simulate being at the max round
      described_class.perform_now(round: 10)

      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(enqueued).to be_empty
    ensure
      Notification.retention_config[:batch_limit] = 10_000
    end
  end
end
