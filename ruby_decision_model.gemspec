# frozen_string_literal: true

require_relative "lib/ruby_decision_model/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_decision_model"
  spec.version = RubyDecisionModel::VERSION
  spec.authors = ["Obie Fernandez"]
  spec.email = ["obiefernandez@gmail.com"]

  spec.summary = "Ruby client for decision models such as Typesafe Jev"
  spec.description = "Decision models answer typed questions about a state instead of generating text. " \
                      "ruby_decision_model builds noul (yes/no probability), choice, and score questions, " \
                      "posts them with a state to a decisions endpoint (OpenRouter's /decisions with " \
                      "Typesafe Jev to start), and returns normalized answers with probabilities, " \
                      "confidence, legends, and usage."
  spec.homepage = "https://github.com/obie/ruby_decision_model"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE.txt]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
