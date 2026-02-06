require "active_retention/version"
require "active_retention/errors"
require "active_retention/configuration"
require "active_retention/model_extension"
require "active_retention/purge_job"

module ActiveRetention
  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  self.configuration = Configuration.new

  class Railtie < Rails::Railtie
    initializer "active_retention.model_extension" do
      if ActiveRetention.configuration.auto_include
        ActiveSupport.on_load(:active_record) do
          include ActiveRetention::ModelExtension
        end
      end
    end
  end
end
