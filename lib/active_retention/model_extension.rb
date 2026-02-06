require 'active_support/concern'
require 'active_support/core_ext/numeric/time'
require 'zlib'
require 'active_retention/errors'

module ActiveRetention
  module ModelExtension
    extend ActiveSupport::Concern

    MINIMUM_RETENTION_PERIOD = 1.hour
    DEFAULT_BATCH_LIMIT = 10_000
    ARCHIVE_INSERT_BATCH_SIZE = 50

    class_methods do
      def has_retention_policy(period:, strategy: :destroy, **options)
        column = (options[:column] || :created_at).to_s
        batch_limit = options.fetch(:batch_limit, DEFAULT_BATCH_LIMIT)

        unless column_names.include?(column)
          raise ArgumentError, "Unknown column '#{column}' for #{table_name}"
        end

        unless %i[destroy delete_all archive].include?(strategy)
          raise ArgumentError, "Unknown strategy '#{strategy}'. Must be :destroy, :delete_all, or :archive"
        end

        if period < MINIMUM_RETENTION_PERIOD
          raise ArgumentError,
            "Retention period must be at least #{MINIMUM_RETENTION_PERIOD.inspect}. " \
            "A very short period risks accidental mass deletion."
        end

        unless batch_limit.is_a?(Integer) && batch_limit > 0
          raise ArgumentError, "batch_limit must be a positive integer, got #{batch_limit.inspect}"
        end

        self.retention_config = {
          period: period,
          strategy: strategy,
          filter: options[:if],
          column: column,
          batch_limit: batch_limit
        }

        scope :expired_records, -> {
          quoted_column = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(retention_config[:column])}"
          where("#{quoted_column} < ?", retention_config[:period].ago)
        }
      end

      def cleanup_retention!(dry_run: false)
        return unless retention_config

        with_retention_lock do
          perform_cleanup!(dry_run: dry_run)
        end
      end

      private

      def perform_cleanup!(dry_run:)
        scope = expired_records
        scope = scope.merge(scope.instance_exec(&retention_config[:filter])) if retention_config[:filter]

        total_expired = scope.count
        return { count: total_expired, dry_run: true } if dry_run

        batch_limit = retention_config[:batch_limit]

        result = case retention_config[:strategy]
        when :destroy
          perform_destroy_cleanup(scope, batch_limit)
        when :delete_all
          perform_delete_all_cleanup(scope, batch_limit)
        when :archive
          validate_archive_table!
          perform_archive_cleanup(scope, batch_limit)
        end

        result.merge(remaining: total_expired > result[:count])
      end

      def perform_destroy_cleanup(scope, batch_limit)
        destroyed = 0
        failed = 0

        scope.find_each do |record|
          break if destroyed + failed >= batch_limit

          if record.destroy
            destroyed += 1
          else
            failed += 1
          end
        end

        { count: destroyed, failed: failed, dry_run: false }
      end

      def perform_delete_all_cleanup(scope, batch_limit)
        ids = scope.limit(batch_limit).pluck(:id)
        deleted = ids.any? ? where(id: ids).delete_all : 0

        { count: deleted, dry_run: false }
      end

      def perform_archive_cleanup(scope, batch_limit)
        archived = archive_retention!(scope, batch_limit: batch_limit)

        { count: archived, dry_run: false }
      end

      def validate_archive_table!
        archive_table = "#{table_name}_archive"
        unless connection.table_exists?(archive_table)
          raise ActiveRetention::ArchiveTableMissing,
            "Archive table '#{archive_table}' does not exist. " \
            "Run `rails generate active_retention:archive #{name}` to create it."
        end
      end

      def archive_retention!(scope, batch_limit:)
        archive_table = "#{table_name}_archive"
        total_archived = 0

        scope.find_in_batches(batch_size: [500, batch_limit].min) do |batch|
          remaining = batch_limit - total_archived
          batch = batch.first(remaining) if batch.size > remaining

          transaction do
            data = batch.map { |r| r.attributes.except('id') }

            if data.any?
              columns = data.first.keys
              quoted_columns = columns.map { |c| connection.quote_column_name(c) }.join(', ')

              data.each_slice(ARCHIVE_INSERT_BATCH_SIZE) do |chunk|
                values_sql = chunk.map do |row|
                  "(#{columns.map { |c| connection.quote(row[c]) }.join(', ')})"
                end.join(', ')

                sql = "INSERT INTO #{connection.quote_table_name(archive_table)} (#{quoted_columns}) VALUES #{values_sql}"
                connection.execute(sql)
              end
            end

            where(id: batch.map(&:id)).delete_all
            total_archived += batch.size
          end

          break if total_archived >= batch_limit
        end

        total_archived
      end

      # --- Advisory Locking ---

      def with_retention_lock
        adapter = connection.adapter_name.downcase

        case adapter
        when /postgres/
          with_pg_advisory_lock { yield }
        when /mysql/
          with_mysql_lock { yield }
        else
          with_mutex_lock { yield }
        end
      end

      def retention_lock_key
        Zlib.crc32("active_retention:#{table_name}") & 0x7FFFFFFF
      end

      def with_pg_advisory_lock
        locked = connection.select_value("SELECT pg_try_advisory_lock(#{retention_lock_key})")
        return skipped_result unless locked

        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{retention_lock_key})")
        end
      end

      def with_mysql_lock
        result = connection.select_value("SELECT GET_LOCK('active_retention_#{table_name}', 0)")
        return skipped_result unless result == 1

        begin
          yield
        ensure
          connection.execute("SELECT RELEASE_LOCK('active_retention_#{table_name}')")
        end
      end

      def with_mutex_lock
        @_retention_mutex ||= Mutex.new

        if @_retention_mutex.try_lock
          begin
            yield
          ensure
            @_retention_mutex.unlock
          end
        else
          skipped_result
        end
      end

      def skipped_result
        { count: 0, skipped: true, reason: :locked, dry_run: false }
      end
    end

    included do
      class_attribute :retention_config, instance_writer: false, default: nil
    end
  end
end
