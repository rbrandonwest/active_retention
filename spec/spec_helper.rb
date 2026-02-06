require 'active_record'
require 'active_job'
require 'active_retention/model_extension'

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

ActiveRecord::Schema.define do
  create_table :notifications, force: true do |t|
    t.string :title
    t.boolean :active, default: true
    t.timestamps
  end

  create_table :notifications_archive, force: true, id: :integer do |t|
    t.string :title
    t.boolean :active, default: true
    t.datetime :created_at
    t.datetime :updated_at
    t.datetime :archived_at, default: -> { 'CURRENT_TIMESTAMP' }
  end

  create_table :events, force: true do |t|
    t.string :name
    t.datetime :occurred_at
    t.timestamps
  end

  create_table :messages, force: true do |t|
    t.string :body
    t.boolean :important, default: false
    t.timestamps
  end
end

ActiveRecord::Base.include(ActiveRetention::ModelExtension)

class Notification < ActiveRecord::Base
  has_retention_policy period: 30.days, strategy: :destroy
end

class Event < ActiveRecord::Base
  has_retention_policy period: 90.days, strategy: :delete_all, column: :occurred_at
end

# Model with a before_destroy callback that blocks deletion of important records
class Message < ActiveRecord::Base
  has_retention_policy period: 7.days, strategy: :destroy

  before_destroy :prevent_important_deletion

  private

  def prevent_important_deletion
    if important?
      errors.add(:base, "Cannot delete important messages")
      throw(:abort)
    end
  end
end

RSpec.configure do |config|
  config.around(:each) do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
