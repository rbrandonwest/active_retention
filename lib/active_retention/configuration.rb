module ActiveRetention
  class Configuration
    attr_accessor :auto_include

    def initialize
      @auto_include = true
    end
  end
end
