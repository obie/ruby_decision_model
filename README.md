# ruby_decision_model

The decision-model interface for Ruby. Decision models answer typed questions
about a state with calibrated probabilities instead of generating text. This gem
talks to them through one `Client` with a provider behind it: OpenRouter by
default, Typesafe's native API as a second door, more providers as labs ship
them. No runtime dependencies beyond the standard library.

## Install

```ruby
gem "ruby_decision_model"
```

## Quick start

```ruby
require "ruby_decision_model"

client = RubyDecisionModel::Client.new

response = client.ask(
  state: { title: "Server returns 500 on checkout", reporter: "support" },
  questions: {
    "urgent" => RubyDecisionModel::Questions.noul("Is this urgent?"),
    "severity" => RubyDecisionModel::Questions.score(
      "How severe is this issue?",
      criteria: ["cosmetic", "minor", "major", "critical"]
    )
  }
)

response["urgent"].noul       # => 0.87
response["severity"].score    # => 2.4
response.usage.input_tokens   # => 120
```

`Client.new` with no arguments reads the environment: `TYPESAFE_API_KEY` selects
Typesafe, otherwise `OPENROUTER_API_KEY` selects OpenRouter. With neither set it
raises `ConfigurationError` naming both. `RubyDecisionModel.client` memoizes one
such default client; assign `nil` to reset it.

## Providers

### OpenRouter (default)

```ruby
# ENV["OPENROUTER_API_KEY"]
client = RubyDecisionModel::Client.new(provider: :open_router)

# or pass the key directly; api_key: alone still means OpenRouter
client = RubyDecisionModel::Client.new(api_key: "sk-or-...")
```

Requests go to `https://openrouter.ai/api/alpha/decisions`. The default model is
`typesafe/jev-1.13`. Usage reports `input_tokens`, `output_tokens`, and `cost`.

### Typesafe native API

```ruby
# ENV["TYPESAFE_API_KEY"]
client = RubyDecisionModel::Client.new(provider: :typesafe)
```

Requests go to `https://api.typesafe.ai/v1/systemone`. The default model is
`jev-latest`. Usage reports `input_tokens` and `output_tokens`; `cost` is `nil`.
Typesafe returns an `x-typesafe-request-id` header, exposed as
`response.request_id` (nil on OpenRouter). Quote it when reporting a problem
to Typesafe.

### Options

```ruby
RubyDecisionModel::Client.new(
  provider: :typesafe,        # :open_router, :typesafe, or a Providers::Base instance
  api_key: nil,               # overrides the provider's env var
  model: nil,                 # nil means the provider default; see aliases below
  base_url: nil,              # overrides the provider base URL
  timeout: 5,                 # open and read timeout in seconds
  retry: { max_retries: 2 },  # RetryPolicy or a Hash of overrides
  transport: nil              # see Transport
)

client.provider   # => #<RubyDecisionModel::Providers::Typesafe ...>
client.model      # => "jev-latest" (resolved after aliasing)
```

Both providers send `User-Agent: ruby_decision_model/<version>`.

### Model aliases

Each provider resolves a few friendly names to its own canonical model name.
Anything not listed passes through untouched. The `model` field on a response
is whatever the provider returned.

| You pass | OpenRouter sends | Typesafe sends |
| --- | --- | --- |
| `nil` | `typesafe/jev-1.13` | `jev-latest` |
| `"jev"` | `typesafe/jev-1.13` | `jev-latest` |
| `"jev-latest"` | `typesafe/jev-1.13` | `jev-latest` |
| `"typesafe/jev-1.13"` | `typesafe/jev-1.13` | `jev-latest` |
| anything else | as given | as given |

### Writing a provider

Subclass `RubyDecisionModel::Providers::Base` and define `name`, `env_var`,
`default_base_url`, `endpoint_path`, `default_model`, and optionally `aliases`
and `reports_cost?`. Override `headers`, `request_body`, or `usage` when the
wire format differs. Pass an instance as `provider:`.

## Questions and answers

Three question types, built with `RubyDecisionModel::Questions`:

```ruby
Questions.noul("Is this spam?")                                  # yes/no probability
Questions.choice("Which team?", criteria: { "billing" => "...", "auth" => "..." })  # up to 255 options
Questions.score("How severe?", criteria: ["cosmetic", "minor", "major"])            # 2 to 10 levels
```

Answers come back typed: `Answers::Noul` (`noul`, `probabilities`),
`Answers::Choice` (`choice`, `confidence`, `probabilities`), and
`Answers::Score` (`score`, `confidence`, `probabilities`, `legend`).
`response.nouls`, `response.choices`, and `response.scores` return the answers
of one type keyed the same way as `response.answers`.

Score `probabilities` and `legend` are keyed by the wire's string level keys
(`"0"`, `"1"`, ...), not by the criteria labels. Choice `probabilities` sum to
approximately 1; treat them as calibrated, not normalized.

## Retries

Retry behaviour follows the official Typesafe SDKs and lives in
`RubyDecisionModel::RetryPolicy`. Pass a policy or a Hash of overrides as
`retry:`.

| Option | Default | Meaning |
| --- | --- | --- |
| `max_retries` | `2` | Retries after the initial attempt |
| `backoff_initial` | `0.5` | First backoff in seconds, doubling each retry |
| `backoff_max` | `5.0` | Backoff ceiling in seconds |
| `backoff_jitter` | `0.25` | Fraction of the backoff randomly subtracted |
| `http_statuses` | `[408, 429] + (500..599)` | Statuses that trigger a retry |
| `respect_retry_after` | `true` | Honor `Retry-After` and `retry-after-ms` |
| `max_retry_after` | `60.0` | Ceiling for a server-supplied delay |
| `retry_connection_errors` | `true` | Retry socket and connection failures |
| `retry_timeouts` | `true` | Retry open and read timeouts |
| `total_timeout` | `30.0` | Budget in seconds across attempts and delays; `nil` disables |

When the next delay would push past `total_timeout`, the client stops and
raises the last error instead of sleeping. The budget governs whether another
attempt starts; an attempt already in flight still runs to its own `timeout`.

Invalid settings (a negative duration, a non-integer `max_retries`, a jitter
outside 0..1, a NaN budget) raise `ConfigurationError` when the client is built.

```ruby
RubyDecisionModel::Client.new(retry: { max_retries: 4, total_timeout: 60.0 })
RubyDecisionModel::Client.new(retry: RubyDecisionModel::RetryPolicy.new(max_retries: 0))
```

## Transport

The client uses `Net::HTTP` by default. Inject `transport:` with any callable
that accepts `url:`, `headers:`, `body:` and returns
`[status, body_string, headers_hash]`. A two-element `[status, body_string]`
return is still accepted and treated as having no headers, which means no
`Retry-After` support and a nil `request_id`.

## Errors

| Error | Meaning |
| --- | --- |
| `ConfigurationError` | No provider could be resolved, missing api_key, unknown provider, or bad `retry:` value |
| `RequestError` | Questions hash was empty |
| `TransportError` (`TimeoutError`) | Network or timeout failure after retries, carries `#cause_error` |
| `ApiError` | Non-2xx response, carries `#status`, `#body`, and `#headers`; the parent of the rest |
| `BadRequest` | 400 |
| `Unauthorized` | 401 |
| `PermissionDenied` | 403 |
| `NotFound` | 404 |
| `PayloadTooLarge` | 413 |
| `UnprocessableEntity` | 422 (never retried) |
| `RateLimited` | 429 (retried) |
| `ServerError` | any 5xx (retried) |
| `Overloaded` | 529, a `ServerError` (retried) |
| `InvalidResponse` | Body wasn't JSON, wasn't a Hash, or an answer was malformed |
| `MissingAnswers` | One or more question ids came back missing or wrong-typed, carries `#missing` |

Status: 0.1.0, API may change.

The companion gem `decide` builds decisions and verdicts on top of this client.

## Releasing

Publishing runs through RubyGems trusted publishing, so no API key is stored
anywhere. To ship a version:

1. Bump `lib/ruby_decision_model/version.rb`.
2. Add the version to `CHANGELOG.md`.
3. Merge to `main`. The Release workflow runs the suite, builds the gem with
   `gem build --strict`, checks the built gem carries every file under
   `lib/`, and pushes it. A version already on RubyGems is skipped, so the
   workflow is safe to re-run.

The same workflow can be started by hand from the Actions tab or with
`gh workflow run release.yml`.
