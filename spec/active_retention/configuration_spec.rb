require 'spec_helper'
require 'active_retention/configuration'

# Set up the configure method without loading the Railtie
module ActiveRetention
  class << self
    attr_accessor :configuration
  end

  def self.configure
    self.configuration ||= Configuration.new
    yield(configuration)
  end

  self.configuration ||= Configuration.new
end

RSpec.describe ActiveRetention::Configuration do
  describe "#auto_include" do
    it "defaults to true" do
      config = ActiveRetention::Configuration.new
      expect(config.auto_include).to be true
    end

    it "can be set to false via configure block" do
      original = ActiveRetention.configuration.auto_include

      ActiveRetention.configure do |config|
        config.auto_include = false
      end

      expect(ActiveRetention.configuration.auto_include).to be false
    ensure
      ActiveRetention.configuration.auto_include = original
    end
  end

  describe "opt-in include" do
    it "works when included directly on a model" do
      model = Class.new(ActiveRecord::Base) do
        self.table_name = 'notifications'
        include ActiveRetention::ModelExtension
        has_retention_policy period: 30.days, strategy: :destroy
      end

      expect(model.retention_config).to include(
        period: 30.days,
        strategy: :destroy
      )
      expect(model).to respond_to(:cleanup_retention!)
    end
  end
end
