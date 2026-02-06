require_relative "lib/active_retention/version"

Gem::Specification.new do |spec|
  spec.name          = "active_retention"
  spec.version       = ActiveRetention::VERSION
  spec.authors       = ["Ray West"]
  spec.email         = ["ray@example.com"]

  spec.summary       = "Automatic data retention and purging for ActiveRecord models."
  spec.description   = "Define retention policies on ActiveRecord models to automatically " \
                        "destroy, delete, or archive expired records. Includes batch limiting, " \
                        "advisory locking, transactional archiving, and background job support."
  spec.homepage      = "https://github.com/raywest/active_retention"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "LICENSE", "README.md"]
  end

  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord",  ">= 6.1"
  spec.add_dependency "activesupport", ">= 6.1"
  spec.add_dependency "activejob",     ">= 6.1"

  spec.add_development_dependency "rspec",   "~> 3.12"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "rake",    "~> 13.0"
end
