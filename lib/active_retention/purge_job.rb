module ActiveRetention
  class PurgeJob < ActiveJob::Base
    queue_as :maintenance

    MAX_REENQUEUE_ROUNDS = 10

    def perform(round: 1)
      Rails.application.eager_load! unless Rails.application.config.eager_load

      has_remaining = false

      models_with_retention.each do |model|
        Rails.logger.info "[ActiveRetention] Purging #{model.name} (round #{round})..."

        result = model.cleanup_retention!

        if result&.dig(:skipped)
          Rails.logger.info "[ActiveRetention] Skipped #{model.name} (already locked by another process)."
        else
          Rails.logger.info "[ActiveRetention] Cleaned up #{result[:count]} #{model.name} records."
          has_remaining = true if result[:remaining]
        end
      rescue StandardError => e
        Rails.logger.error "[ActiveRetention] Failed to purge #{model.name}: #{e.message}"
      end

      if has_remaining && round < MAX_REENQUEUE_ROUNDS
        Rails.logger.info "[ActiveRetention] Re-enqueueing (round #{round + 1}/#{MAX_REENQUEUE_ROUNDS}) — models still have expired records."
        self.class.perform_later(round: round + 1)
      elsif has_remaining
        Rails.logger.warn "[ActiveRetention] Reached maximum of #{MAX_REENQUEUE_ROUNDS} rounds. Some expired records remain."
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
