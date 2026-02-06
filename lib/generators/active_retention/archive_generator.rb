require 'rails/generators/active_record'

module ActiveRetention
  module Generators
    class ArchiveGenerator < ActiveRecord::Generators::Base
      source_root File.expand_path('templates', __dir__)

      def create_migration_file
        @model_name = name.camelize
        @table_name = name.underscore.pluralize
        @archive_table_name = "#{@table_name}_archive"
        migration_template "archive_migration.rb.erb", "db/migrate/create_#{@archive_table_name}.rb"
      end

      private

      def model_columns
        @model_name.constantize.columns.reject { |c| c.name == 'id' }
      end
    end
  end
end
