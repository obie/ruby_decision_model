# Changelog

## 0.2.0 - 2026-10-06

The decision models that shipped after Jev, behind the same `Client`.

- Added providers `:openai` (OpenAI Decisions API, `gpt-6-luna`),
  `:cloudflare` (Clef and Clef-flash on Workers AI), `:perplexity`
  (`pplx-decider-v1.1-27b` and `pplx-decider-v1-27b`), `:databricks`
  (`ai_decide` over REST), and `:system_one` (any server speaking
  `/v1/systemone`: Ollama, the autojev server, strands-decider, and others).
- The OpenAI provider translates both ways between System One and OpenAI's
  wire format. Questions, answers, and `Answers::*` types are unchanged for
  callers. A noul with true/false criteria goes out as a boolean choice and
  comes back as a noul.
- `Client#ask` takes `images:`, an array of base64 data URLs. Each provider
  places them where its API expects. Providers that don't read images raise
  `RequestError` before sending. Added `RubyDecisionModel::Images.data_url`
  and `.from_file`.
- Refused questions (OpenAI) raise `MissingAnswers` as before, with the new
  `#refused` listing the ids the provider declined.
- Noul `probabilities` are always `{"true" => p, "false" => 1 - p}`. Jev,
  Clef, pplx-decider, and most System One servers send only the probability,
  so the client fills in the split. A noul with junk `probabilities` now gets
  the split instead of `{}`, and a noul outside 0..1 raises
  `InvalidResponse`.
- State or questions that cannot be encoded as JSON (invalid UTF-8, `NaN`,
  nesting deeper than 100 levels) raise `RequestError`, with the original
  error on `#cause`.
- `RUBY_DECISION_MODEL_PROVIDER` names a provider from the environment ahead
  of key detection (any case; `-` reads as `_`), and
  `Client.new(api_key: ...)` sends that key to the named provider rather
  than OpenRouter. `SYSTEM_ONE_BASE_URL` joins detection after
  `TYPESAFE_API_KEY` and `OPENROUTER_API_KEY`. Keys like `OPENAI_API_KEY` do
  not select a provider by themselves.
- New aliases. On OpenRouter: `luna` and `gpt-6-luna` resolve to
  `openai/gpt-6-luna-decisions`, `clef` and `clef-flash` to the
  `cloudflare/` slugs, and `pplx-decider` to
  `perplexity/pplx-decider-v1-27b`. Native providers accept the OpenRouter
  slugs for their own models. Typesafe accepts `~typesafe/jev-latest`.
- Each provider names its own request id header: `x-request-id` on OpenAI
  and Perplexity, `cf-ray` on Cloudflare, and `x-typesafe-request-id`
  everywhere else, as in 0.1.0.
- `timeout:` now defaults to `nil`, meaning the provider's read timeout: 5
  seconds for Typesafe, OpenRouter, and Cloudflare, 30 for OpenAI,
  Perplexity, Databricks, and System One servers, with a 5 second open
  timeout. Passing a number sets both, as before. The write timeout, which
  bounds image uploads, follows the read timeout, and a write timeout is
  retried and raised as `TimeoutError` like the other two. In 0.1.0 an
  explicit `timeout: nil` meant no limit at all; it now means these
  defaults. Added `Client#open_timeout`.
- `ApiError` messages end with the vendor's reason when the error body has
  one, for example `api error (status 400): Invalid model 'x'.` The client
  reads OpenAI, Perplexity, and OpenRouter `error.message`, Cloudflare
  `errors[].message`, FastAPI `detail[].msg` (Typesafe), and Databricks
  `message`. The API key is masked if a vendor echoes it, and the text is
  capped at 500 characters. `#body` is unchanged.
- API keys are stripped before they go into the `Authorization` header, so
  a key read from a file with its trailing newline works.
- Added `rake smoke`, an opt-in live check against every provider whose keys
  are set. CI never runs it.
- Provider hooks for authors: `normalize_response`, `supports_images?`,
  `request_id_header`, `requires_api_key?`, `default_timeout`,
  `error_message`, `validate!`, `configured?`, and `url(model)`. Base sends
  `Authorization` only when a key is present. Providers written against
  0.1.0 keep working: a `url` override without the model argument is still
  called without it.

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
