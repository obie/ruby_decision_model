# Changelog

## Unreleased

- `ApiError` carries `#request_id` and `#endpoint`. The request id was only
  ever reachable on a successful response, which is the one case nobody needs
  it for; the README asks you to quote it when reporting a problem.
- `Response#headers` keeps every header the transport returned, and
  `Response#header(name)` looks one up without regard to case. Rate-limit
  counters and anything else the client does not interpret used to be dropped
  on the floor.
- Added `RubyDecisionModel::Headers.fetch`, the case-insensitive header lookup
  both the response and the retry policy use.
- `Response.new` takes `headers:` in place of `request_id:`; `#request_id`
  still reads the same value.

## 0.1.0 - 2026-09-18

Provider-neutral release. One `Client`, two providers behind it.

- Added `RubyDecisionModel::Providers` with `Base`, `OpenRouter`, and
  `Typesafe`. A provider owns base URL, endpoint path, auth, default model,
  model aliases, and usage parsing. `Client` delegates to it.
- `Client.new` takes `provider:` (`:open_router`, `:typesafe`, or a
  `Providers::Base` instance). With no provider and no `api_key:`, the
  environment decides: `TYPESAFE_API_KEY` first, then `OPENROUTER_API_KEY`,
  otherwise `ConfigurationError` naming both. `api_key:` alone still means
  OpenRouter. `model:` defaults to the provider's model. `base_url:` overrides
  the provider base. `client.provider` and `client.model` are readable.
- Added `RubyDecisionModel.client`, a memoized default client, and
  `RubyDecisionModel.client = nil` to reset it.
- Model aliases: `jev` and `jev-latest` resolve to `typesafe/jev-1.13` on
  OpenRouter; `typesafe/jev-1.13` and `jev` resolve to `jev-latest` on
  Typesafe. Other names pass through.
- Both providers send `User-Agent: ruby_decision_model/<version>`.
- Added `RubyDecisionModel::RetryPolicy` matching the official Typesafe SDKs:
  `max_retries: 2`, exponential backoff from 0.5s capped at 5s with 25%
  jitter, retry on 408, 429, and 5xx, `Retry-After` and `retry-after-ms`
  honored up to 60s, connection errors and timeouts retried, and a
  `total_timeout: 30.0` budget across attempts and delays. `Client` accepts
  `retry:` as a policy or a Hash of overrides. Jitter uses an injectable
  `random:`. Invalid settings raise `ConfigurationError` at construction.
- Transport contract now returns `[status, body, headers]`. Two-element
  returns are still accepted.
- Added `Response#request_id` (from `x-typesafe-request-id`, nil on
  OpenRouter) and `Response#nouls`, `#choices`, `#scores`.
- Added `UnprocessableEntity` (422) and `Overloaded` (529). `ApiError` now
  carries `#headers`.
- Usage `cost` is `nil` on Typesafe, which does not report it.
- `Client::DEFAULT_BASE_URL`, `DEFAULT_MODEL`, `MAX_ATTEMPTS`, `RETRYABLE_STATUSES`,
  and `RETRYABLE_EXCEPTIONS` remain as compatibility aliases. They now read from
  the OpenRouter provider and the default `RetryPolicy`, so `MAX_ATTEMPTS` is 3
  and `RETRYABLE_STATUSES` covers 408, 429, and every 5xx.

## 0.0.1 - 2026-09-18

Initial release. Client and question builders for OpenRouter's `/decisions`
endpoint with Typesafe Jev as the first backend. Supports noul, choice, and
score questions, normalized answers, retry on transient errors, and a typed
error hierarchy.
