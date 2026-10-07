# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

task default: :test

# Live calls against real decision-model APIs, so it never runs in CI or as
# part of the default task. Each provider whose credentials are in the
# environment gets one request with a noul, a noul with criteria, a choice,
# and a score question, and the answers are printed for a human to judge.
#
#   rake smoke                                     every configured provider
#   rake smoke TARGETS=open_router:clef,perplexity provider[:model] pairs
#   rake smoke SMOKE_IMAGE=photo.png               also send an image where supported
desc "Live smoke test against each configured provider (needs real keys)"
task :smoke do
  $LOAD_PATH.unshift File.expand_path("lib", __dir__)
  require "ruby_decision_model"

  rdm = RubyDecisionModel
  targets =
    if ENV["TARGETS"].to_s.strip.empty?
      rdm::Providers.names.filter_map { |name| [name, nil] if rdm::Providers.build(name).configured? }
    else
      ENV["TARGETS"].split(",").map { |pair| pair.strip.split(":", 2).then { |name, model| [name.to_sym, model] } }
    end
  abort "smoke: no provider configured; set a provider's keys or TARGETS=provider[:model]" if targets.empty?

  state = { title: "Checkout returns 500 for every customer",
            body: "Since 09:10 UTC every checkout attempt fails with a server error. Revenue is blocked.",
            reporter: "support" }
  questions = {
    "outage" => rdm::Questions.noul("Does this ticket describe a production outage?"),
    "urgent" => rdm::Questions.noul("Is this urgent?", criteria: { "true" => "Needs action within the hour",
                                                                   "false" => "Can wait for normal triage" }),
    "team" => rdm::Questions.choice("Which team should handle this?",
                                    criteria: { "billing" => "Invoices, refunds, pricing",
                                                "platform" => "Outages, errors, and infrastructure",
                                                "design" => "Layout and copy" }),
    "severity" => rdm::Questions.score("How severe is the customer impact?",
                                       criteria: ["No impact", "Minor", "Major", "Critical"])
  }
  image = ENV["SMOKE_IMAGE"].to_s.empty? ? nil : rdm::Images.from_file(ENV["SMOKE_IMAGE"])

  failures = 0
  targets.each do |name, model|
    label = model ? "#{name}:#{model}" : name.to_s
    begin
      client = rdm::Client.new(provider: name, model: model)
      images = image && client.provider.supports_images? ? [image] : nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.ask(state: state, questions: questions, images: images)
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

      puts "ok    #{label}  model=#{response.model.inspect}  #{elapsed}ms#{images ? '  +image' : ''}"
      puts format("      outage=%.3f urgent=%.3f team=%s (%.2f) severity=%.2f (%.2f)",
                  response["outage"].noul, response["urgent"].noul, response["team"].choice,
                  response["team"].confidence, response["severity"].score, response["severity"].confidence)
      usage = response.usage
      puts "      usage in=#{usage.input_tokens.inspect} out=#{usage.output_tokens.inspect} " \
           "cost=#{usage.cost.inspect}  id=#{response.id.inspect}  request_id=#{response.request_id.inspect}"
    rescue rdm::Error => e
      failures += 1
      puts "FAIL  #{label}  #{e.class.name.split('::').last}: #{e.message}"
      puts "      refused: #{e.refused.join(', ')}" if e.respond_to?(:refused) && e.refused.any?
    end
  end

  abort "smoke: #{failures} of #{targets.size} failed" if failures.positive?
end

# Release tooling, the single-gem shape of the terret repo's rake release
# tasks. The gemspec is the one source of name and version; nothing here
# hardcodes either. The release workflow drives these three tasks in order.
namespace :release do
  gemspec = -> { Gem::Specification.load(Dir["*.gemspec"].first) }

  published = lambda do |spec|
    require "open-uri"
    require "json"
    body = URI.open("https://rubygems.org/api/v1/versions/#{spec.name}.json", &:read)
    JSON.parse(body).any? { |v| v["number"] == spec.version.to_s }
  rescue OpenURI::HTTPError
    false # 404 => the gem has never been published, so there is nothing to skip
  end

  desc "Build the gem into pkg/ with --strict (proof the gemspec is valid). " \
       "Reversible, pkg/ is gitignored, and the local half of a release; " \
       "release:push is the irreversible half."
  task :build do
    require "fileutils"
    spec = gemspec.call
    FileUtils.rm_rf("pkg")
    FileUtils.mkdir_p("pkg")
    # --strict escalates any spec warning to a build failure.
    sh "gem build #{File.basename(spec.loaded_from)} --strict --output pkg/#{spec.name}-#{spec.version}.gem"
  end

  desc "Print publish=true when the gemspec's version is not yet on RubyGems " \
       "and publish=false when it is. The release workflow reads this to decide " \
       "whether to fetch credentials and push at all."
  task :status do
    puts "publish=#{!published.call(gemspec.call)}"
  end

  desc "Push pkg/<gem>-<version>.gem to RubyGems. A version already published " \
       "is skipped, so a re-run is safe. The release workflow runs this with a " \
       "short-lived key from trusted publishing; by hand it needs RubyGems MFA."
  task :push do
    spec = gemspec.call
    gem_file = "pkg/#{spec.name}-#{spec.version}.gem"
    abort "release:push: #{gem_file} is missing, run `rake release:build` first" unless File.exist?(gem_file)

    if published.call(spec)
      puts "skip  #{spec.name} #{spec.version} (already on RubyGems)"
      next
    end

    puts "push  #{gem_file}"
    sh "gem push #{gem_file}"
  end
end
