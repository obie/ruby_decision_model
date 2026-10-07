# ruby_decision_model

The decision-model interface for Ruby. Decision models answer typed questions
about a state with calibrated probabilities instead of generating text. This gem
talks to them through one `Client` with a provider behind it. OpenRouter is the
default. Typesafe (Jev), OpenAI (gpt-6-luna), Cloudflare (Clef), Perplexity
(pplx-decider), and Databricks (`ai_decide`) each have a native provider, and
any server that speaks the System One API (Ollama, strands-decider, the
autojev server) works through `:system_one`. Your questions and answers keep
one shape whichever provider serves them. No runtime dependencies beyond the
standard library.

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

`Client.new` with no arguments reads the environment.
`RUBY_DECISION_MODEL_PROVIDER` names a provider outright (`openai`,
`cloudflare`, and so on, in any case, with `-` or `_`), and an `api_key:` passed without `provider:` goes
to that provider. Without it, `TYPESAFE_API_KEY` selects Typesafe,
then `OPENROUTER_API_KEY` selects OpenRouter, then `SYSTEM_ONE_BASE_URL`
selects a System One server. General-purpose credentials such as
`OPENAI_API_KEY` or `CLOUDFLARE_API_TOKEN` never pick a provider on their own,
since plenty of apps hold them for other reasons. With nothing usable set,
`Client.new` raises `ConfigurationError` naming the variables it checked.
`RubyDecisionModel.client` memoizes one such default client; assign `nil` to
reset it.

Switching vendors is a configuration change:

```ruby
RubyDecisionModel::Client.new(provider: :openai)       # gpt-6-luna
RubyDecisionModel::Client.new(provider: :perplexity)   # pplx-decider-v1.1-27b
RubyDecisionModel::Client.new(provider: :open_router, model: "clef")
```

## Providers

### OpenRouter (default)

```ruby
# ENV["OPENROUTER_API_KEY"]
client = RubyDecisionModel::Client.new(provider: :open_router)

# or pass the key directly; api_key: alone means OpenRouter
# unless RUBY_DECISION_MODEL_PROVIDER names another provider
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
`response.request_id`. Quote it when reporting a problem to Typesafe.

### OpenAI Decisions API

```ruby
# ENV["OPENAI_API_KEY"]
client = RubyDecisionModel::Client.new(provider: :openai)
```

Requests go to `https://api.openai.com/v1/decisions`. The API is in public beta
as of October 2026, so its wire format may still change. The default model is
`gpt-6-luna`. OpenAI's wire format differs from System One, so the
provider translates both ways and your questions stay the same:

- `state` becomes `input`. A String passes through as is. Anything else is
  sent as JSON text, because the API takes no structured input.
- `noul` becomes a `predicate`. A noul with `true`/`false` criteria becomes a
  boolean `choice` so the descriptions reach the model, and the answer comes
  back as a noul.
- Choice criteria become `choices` and score criteria become `levels`.
- Answers arrive as an array and are rebuilt keyed by question id, with
  probability Hashes and a score `legend` built from your criteria.

When the model declines a question the client raises `MissingAnswers` with
that id in `#refused`; the other answers are on `#answers`. Usage reports
tokens with no cost. OpenAI's response carries no id today, so `response.id`
is nil unless OpenAI starts sending one. `response.request_id` reads
`x-request-id`.

### Cloudflare Workers AI (Clef)

```ruby
# ENV["CLOUDFLARE_API_TOKEN"] (or CLOUDFLARE_AUTH_TOKEN) and ENV["CLOUDFLARE_ACCOUNT_ID"]
client = RubyDecisionModel::Client.new(provider: :cloudflare, model: "clef-flash")

# or configure the provider directly
provider = RubyDecisionModel::Providers::Cloudflare.new(api_key: "...", account_id: "...")
client = RubyDecisionModel::Client.new(provider: provider)
```

Requests go to
`https://api.cloudflare.com/client/v4/accounts/<account_id>/ai/run/@cf/cloudflare/<model>`.
The default model is `clef`; `clef-flash` is the smaller, faster one. The body
is System One. The provider unwraps Cloudflare's `{"result": ...}` envelope,
and a body with `"success": false` raises `InvalidResponse` carrying
Cloudflare's error text. The account id and model end up in the URL path, so
both are checked when the client is built. The account id may hold letters,
digits, `-`, and `_`; surrounding whitespace is stripped. The model must start
with a letter or digit and may also hold `.`, `-`, and `_`. Anything else
raises `ConfigurationError`.
Usage reports tokens with no cost, and `response.request_id` is the `cf-ray`
header.

### Perplexity (pplx-decider)

```ruby
# ENV["PERPLEXITY_API_KEY"]
client = RubyDecisionModel::Client.new(provider: :perplexity)
```

Requests go to `https://api.perplexity.ai/v1/decisions`. The default model is
`pplx-decider-v1.1-27b`; `pplx-decider-v1-27b` also works. The body is System
One. `response.request_id` reads `x-request-id`.

### Databricks `ai_decide`

```ruby
# ENV["DATABRICKS_HOST"] and ENV["DATABRICKS_TOKEN"]
client = RubyDecisionModel::Client.new(provider: :databricks)
```

Requests go to `<host>/api/2.0/ai-functions/ai-decide`. `ai_decide` is a
Databricks beta: a workspace admin has to enable it, and its REST shape may
still change. The workspace serves one managed model, so
`client.model` is nil and passing `model:` raises `ConfigurationError`. The
provider reads answers from the `response` wrapper. Databricks reports no
usage, so every usage field is nil.

### System One servers (Ollama, local models)

```ruby
# ENV["SYSTEM_ONE_BASE_URL"], and ENV["SYSTEM_ONE_API_KEY"] if the server wants one
client = RubyDecisionModel::Client.new(provider: :system_one, base_url: "http://localhost:11434", model: "nimble")
```

Anything that serves Typesafe's API at `/v1/systemone` works here: the autojev
server shipped with pplx-decider's weights, strands-decider's local server,
and hosted lookalikes. Pydantic AI's docs say Ollama 0.35 and later serves it
too, with models such as `nimble` and `tev1`. The base URL has no
`/v1` suffix and needs its `http://` or `https://` and a host. It is checked
when the first request is built rather than in `Client.new`, so a `base_url:`
passed to the client can replace an unusable `SYSTEM_ONE_BASE_URL`; a bad one
raises `ConfigurationError` from `ask`. The API key and model are optional; without a key no
`Authorization` header is sent, and without a model the body has no `model`
field. The environment variable names match Pydantic AI's.

### Options

```ruby
RubyDecisionModel::Client.new(
  provider: :typesafe,        # a name from Providers.names, or a Providers::Base instance
  api_key: nil,               # overrides the provider's env var
  model: nil,                 # nil means the provider default; see aliases below
  base_url: nil,              # overrides the provider base URL
  timeout: nil,               # seconds; nil means the provider's read default and a 5s open timeout
  retry: { max_retries: 2 },  # RetryPolicy or a Hash of overrides
  transport: nil              # see Transport
)

client.provider   # => #<RubyDecisionModel::Providers::Typesafe ...>
client.model      # => "jev-latest" (resolved after aliasing)
```

Every provider sends `User-Agent: ruby_decision_model/<version>`.

The default read timeout is 5 seconds for Typesafe, OpenRouter, and
Cloudflare, whose models answer in well under a second. OpenAI, Perplexity,
Databricks, and System One servers default to 30, since Perplexity documents
responses of up to 23 seconds on large inputs and a local server may load the
model on the first request. Connecting gets 5 seconds either way. A number
passed as `timeout:` sets both, as in 0.1.0. Through OpenRouter, pass a
longer `timeout:` yourself for large inputs to slower models.

### Model aliases

Each provider resolves a few friendly names to its own canonical model name,
so one short name follows a model from OpenRouter to its vendor's API and
back. OpenRouter slugs also resolve on the vendor's own provider. Anything
not listed passes through untouched, which is how you reach models without an
alias, such as `liquid/d1` on OpenRouter. The `model` field on a response is
whatever the provider returned.

| You pass | OpenRouter sends | Native provider sends |
| --- | --- | --- |
| `nil` | `typesafe/jev-1.13` | that provider's default |
| `"jev"`, `"jev-latest"` | `typesafe/jev-1.13` | `jev-latest` (Typesafe) |
| `"typesafe/jev-1.13"`, `"~typesafe/jev-latest"` | as given | `jev-latest` (Typesafe) |
| `"luna"`, `"gpt-6-luna"` | `openai/gpt-6-luna-decisions` | `gpt-6-luna` (OpenAI) |
| `"openai/gpt-6-luna-decisions"`, `"openai/gpt-6-luna"`, `"gpt-6-luna-decisions"` | as given | `gpt-6-luna` (OpenAI) |
| `"clef"`, `"clef-flash"` | `cloudflare/clef`, `cloudflare/clef-flash` | as given (Cloudflare) |
| `"cloudflare/clef"`, `"cloudflare/clef-flash"` | as given | `clef`, `clef-flash` (Cloudflare) |
| `"@cf/cloudflare/clef"`, `"@cf/cloudflare/clef-flash"` | as given | `clef`, `clef-flash` (Cloudflare) |
| `"pplx-decider"` | `perplexity/pplx-decider-v1-27b` | `pplx-decider-v1.1-27b` (Perplexity) |
| `"pplx-decider-v1-27b"` | `perplexity/pplx-decider-v1-27b` | as given (Perplexity) |
| `"perplexity/pplx-decider-v1-27b"` | as given | `pplx-decider-v1-27b` (Perplexity) |
| anything else | as given | as given |

OpenRouter carries pplx-decider v1 only, so `"pplx-decider"` means v1 there
and v1.1 on Perplexity's own API.

### Writing a provider

Subclass `RubyDecisionModel::Providers::Base` and define `name`, `env_var`,
`default_base_url`, `endpoint_path`, and `default_model`. Optional hooks:
`aliases`, `reports_cost?`, `supports_images?`, `request_id_header`,
`requires_api_key?`, `default_timeout`, `error_message`, and `validate!`. When the wire format differs from
System One, override `request_body` to encode and `normalize_response` to turn
the parsed body back into System One answers keyed by question id; the
OpenAI provider shows both directions. Override `url(model)` when the model
belongs in the path. Pass an instance as `provider:`.

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
approximately 1; treat them as calibrated, not normalized. Noul
`probabilities` are always `{"true" => p, "false" => 1 - p}`. Most providers
send only the probability, and the client fills in the split.

## Images

OpenAI, Cloudflare, Perplexity, and System One servers read images. Pass them
as base64 data URLs; no provider fetches a remote URL.

```ruby
photo = RubyDecisionModel::Images.from_file("damage.jpg")
# or RubyDecisionModel::Images.data_url(bytes, content_type: "image/png")

client.ask(
  state: "Customer says the screen arrived cracked.",
  questions: { "damaged" => RubyDecisionModel::Questions.noul("Is there visible damage?") },
  images: [photo]
)
```

Each provider puts them where its API expects: `input_image` parts for
OpenAI, the `images` field for Cloudflare and System One servers, and
`image_url` parts inside `state` for Perplexity. Typesafe, OpenRouter, and
Databricks don't take images, so the client raises `RequestError` before
sending. Size and count limits vary by vendor and are enforced server side.

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
| `retry_timeouts` | `true` | Retry open, read, and write timeouts |
| `total_timeout` | `30.0` | Budget in seconds across attempts and delays; `nil` disables |

When the next delay would push past `total_timeout`, the client stops and
raises the last error instead of sleeping. The budget governs whether another
attempt starts; an attempt already in flight still runs to its own `timeout`.
With the 30 second read timeout that OpenAI, Perplexity, Databricks, and
System One servers default to, an attempt that times out uses the whole
default budget, so it is not retried. Pass `retry: { total_timeout: 90.0 }`
if you would rather wait for a retry.

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
| `ConfigurationError` | No provider could be resolved, a missing key or setting (api_key, account_id, base_url), unknown provider, a `model:` Databricks can't take, or bad `retry:` value |
| `RequestError` | Questions hash was empty, images were not data URLs or went to a provider that doesn't read them, or state or questions could not be encoded as JSON (original error on `#cause`) |
| `TransportError` (`TimeoutError`) | Network or timeout failure after retries, carries `#cause_error` |
| `ApiError` | Non-2xx response, carries `#status`, `#body`, and `#headers`. The message ends with the vendor's own reason when the body has one |
| `Unauthorized` | 401 |
| `PayloadTooLarge` | 413 |
| `UnprocessableEntity` | 422 (never retried) |
| `RateLimited` | 429 (retried) |
| `Overloaded` | 529 (retried) |
| `InvalidResponse` | Body wasn't JSON, wasn't a Hash, or an answer was malformed (including a noul outside 0..1 or an id answered twice) |
| `MissingAnswers` | One or more question ids came back missing, wrong-typed, or refused. Carries `#missing`, `#refused` (the subset the provider declined), and `#answers` |

Status: 0.2.0, API may change.

The companion gem `decide` builds decisions and verdicts on top of this client.

## Releasing

Publishing runs through RubyGems trusted publishing, so no API key is stored
anywhere. To ship a version:

1. Bump `lib/ruby_decision_model/version.rb`.
2. Add the version to `CHANGELOG.md`.
3. Run `rake smoke` with whatever provider keys you have. It makes one live
   request per configured provider and prints the answers. CI never runs it.
   `TARGETS=open_router:clef,open_router:luna` picks provider and model
   pairs, and `SMOKE_IMAGE=photo.png` adds an image where supported.
4. Merge to `main`. The Release workflow runs the suite, builds the gem with
   `gem build --strict`, checks the built gem carries every file under
   `lib/`, and pushes it. A version already on RubyGems is skipped, so the
   workflow is safe to re-run.

The same workflow can be started by hand from the Actions tab or with
`gh workflow run release.yml`.
