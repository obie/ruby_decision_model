---
created: 2026-10-07T04:54:27Z
branch: main
trigger: manual
restored: false
topic: decision-providers-hardening
---

# Handoff: 0.2.0 shipped with five new decision-model providers; 0.2.1 hardening is next

## Goal
Keep ruby_decision_model a vendor-agnostic client for decision models (typed noul/choice/score questions answered with calibrated probabilities). 0.2.0 added the models that shipped after Typesafe's Jev. The next piece of work is the 0.2.1 hardening list that review deferred.

## Current State
- **Released:** 0.2.0 is on RubyGems (published 2026-10-07 04:03 UTC). It went out via PR #22, squash-merged as `5154d43` on `main`, and the Release workflow pushed it through trusted publishing.
- **Providers now:** `:open_router` (default), `:typesafe`, `:openai` (Decisions API, gpt-6-luna, translated both ways from System One), `:cloudflare` (Clef, Clef-flash on Workers AI), `:perplexity` (pplx-decider-v1.1-27b), `:databricks` (ai_decide REST), and `:system_one` (any `/v1/systemone` server, e.g. Ollama 0.35+, autojev, strands-decider).
- **Features also shipped:** `images:` on `ask` (data URLs, `RubyDecisionModel::Images`), refusals on `MissingAnswers#refused`, cross-provider aliases, per-provider timeouts (5s or 30s read, 5s open, write follows read), vendor error text in `ApiError` messages (key masked, control chars stripped, capped at 500), `RUBY_DECISION_MODEL_PROVIDER`, and `rake smoke`.
- **Tests:** 199 tests, green on Ruby 3.2, 3.3, 3.4 and 4.0. CI runs `bundle exec rake` on `.ruby-version`, 3.2, 3.3 and 3.4.
- **Verified live:**
  - Through OpenRouter: Jev, Clef, Clef-flash, gpt-6-luna and pplx-decider.
  - Cloudflare's native Workers AI endpoint (one call through the Cloudflare MCP), which confirmed the `{"result": ...}` envelope.
- **Not verified live:**
  - The native OpenAI, Perplexity and Databricks endpoints; no keys exist in this environment.
  - System One servers, because local Ollama is 0.18 and the server isn't running.
- **Uncommitted work:** none. The feature branch `feat/new-decision-providers` still exists on GitHub, since the repo doesn't auto-delete merged branches.

## Key Decisions
- **System One is the canonical internal shape.** Providers translate to and from it through `request_body` and `normalize_response`, so `Client`, `Answers` and `decide` stay vendor-neutral. Nothing else needed changing to add OpenAI's different wire format.
- **Only decision-model-specific settings pick a provider from the environment.** These are `TYPESAFE_API_KEY`, `OPENROUTER_API_KEY` and `SYSTEM_ONE_BASE_URL`. `OPENAI_API_KEY`, `CLOUDFLARE_API_TOKEN` and the Databricks vars never pick one, because apps hold them for other reasons. `RUBY_DECISION_MODEL_PROVIDER` names any provider, and `api_key:` passed alone goes to that provider.
- **Ambiguous vendor responses fail closed.** Duplicate ids, duplicate probability values (compared as strings) and a noul outside 0..1 all raise `InvalidResponse`. Silently picking one would hand callers a wrong answer with no error.
- **0.1.0 custom providers keep working:**
  - `Client#request_url` checks `Method#parameters`, so a zero-arity or keyword-only `url` still works.
  - `request_body` gets `images:` only when images are present.
  - `Base#request_id_header` defaults to `x-typesafe-request-id`.
- **Cloudflare, Perplexity, OpenAI, Databricks and System One get no provider-specific kwargs on `Client.new`.** Pass a provider instance instead, for example `Providers::Cloudflare.new(account_id:)`.
- **The System One URL check runs in `#url` at request time, not in `validate!`.** That lets a client's `base_url:` replace an unusable `SYSTEM_ONE_BASE_URL`.
- **These were left as is on purpose:**
  - `http://` base URLs are allowed.
  - A refusal raises `MissingAnswers` and keeps the good answers on `#answers`.
  - OpenRouter keeps a 5s timeout even for vendor-routed models; the README tells users to pass `timeout:`.
  - A 30s attempt that times out uses the whole 30s retry budget, as documented.
- **No `TODOS.md`.** The repo doesn't use one; follow-ups live in the PR #22 body and in this file.

## Modified Files
No uncommitted changes. For reference, 0.2.0 (`5154d43`) touched:
- **New:**
  - `lib/ruby_decision_model/images.rb`
  - `lib/ruby_decision_model/providers/{openai,cloudflare,perplexity,databricks,system_one}.rb`
  - `test/openai_provider_test.rb`
  - `test/vendor_providers_test.rb`
- **Changed:**
  - `lib/ruby_decision_model/{client,errors,providers,retry_policy,version}.rb`
  - `lib/ruby_decision_model/providers/{base,open_router,typesafe}.rb`
  - `lib/ruby_decision_model.rb`
  - `test/{client,providers,retry}_test.rb`, `test/test_helper.rb`
  - `Rakefile`, `README.md`, `CHANGELOG.md`, `ruby_decision_model.gemspec`

## Failed Approaches
- **`require "base64"`** is a bundled gem from Ruby 3.4 on and would add a runtime dependency. Use `[bytes].pack("m0")`.
- **`minitest/mock` / `Object#stub`** were removed in minitest 6. The bundle pins minitest ~> 5.0, so CI was fine, but unbundled runs failed. `test/test_helper.rb` has a hand-rolled `with_net_http` helper instead.
- **`Net::HTTP.stub` without removing the method first** triggers "method redefined" warnings under `-w`. The helper calls `remove_method` before redefining.
- **The ship skill's Codex blocks** use a cleanup trap that the local dcg hook blocks. Use a fixed scratchpad directory for `_OUTSIDE_TMP` instead.
- **`gstack-docs-candidate snapshot --docs a b`** fails. Repeat the flag: `--docs a --docs b`.
- **`codex review --base main`** only diffs tracked files, so it never saw the new untracked provider files. Its result also came back unverified. Commit before running it, or use the adversarial `codex exec` with the diff and new files in the prompt.
- **The scheme check in `SystemOne#validate!`** broke env selection, because `from_env` uses `configured?`. It moved to `#url`.
- **The first duplicate-value check** compared raw values, so `true` and `"true"` slipped past and then collided on `to_s` keys. It now compares `to_s`.

## Files to Read
- `CHANGELOG.md`: the 0.2.0 entry is the user-facing summary.
- `README.md`: the provider sections, model alias table, Images, Errors table, and Releasing steps (which include `rake smoke`).
- `lib/ruby_decision_model/providers/base.rb`: the provider contract and hooks.
- `lib/ruby_decision_model/providers/openai.rb`: the most complex translation.
- `lib/ruby_decision_model/client.rb`: resolution, retries, response handling.
- PR #22 body: https://github.com/obie/ruby_decision_model/pull/22 (review history, decisions, the full follow-up list).
- Companion consumer: `/Users/obie/projects/decide/lib/decide/askers/decision_model.rb`.

## Next Steps
1. Run `rake smoke` with real keys for the providers nobody has verified live: `OPENAI_API_KEY` with `RUBY_DECISION_MODEL_PROVIDER=openai`, `PERPLEXITY_API_KEY`, and `DATABRICKS_HOST` plus `DATABRICKS_TOKEN`. For example: `rake smoke TARGETS=openai,perplexity,databricks`.
2. 0.2.1 hardening, in rough priority order:
   - Mask API keys shorter than 8 characters in vendor error text.
   - On the OpenAI path, raise `RequestError` for noul criteria that aren't `{"true","false"}` instead of dropping them.
   - Give `InvalidResponse` a `#refused` (or report refusals) when a malformed answer and a refusal share a response.
   - Sanitize the JSON parser message for non-JSON 2xx bodies in `Client#parse_success`. This is pre-existing since 0.1.0.
   - Parse `DATABRICKS_HOST` with URI, dropping any query or fragment and matching the scheme case-insensitively.
   - Decide how Perplexity should treat an Array state once images are attached.
   - Use positional OpenAI matching only when the answer count equals the question count.
   - Add range validation for choice and score fields, and detect Symbol/String question id collisions. Both are pre-existing.
   - Consider a per-attempt overall deadline and a response size cap.
3. README debt from the docs audit:
   - Name `Client#open_timeout`.
   - Say that `timeout:` also sets the write timeout.
   - Add `configured?` to the hook list.
   - Document Databricks `error_message` handling and the scheme it adds to a bare host.
   - Document `Images` raising `ArgumentError`.
   - Document OpenAI raising `RequestError` when instructions are missing.
4. In the `decide` gem, pass `MissingAnswers#answers` and `#refused` through instead of collapsing to `AskFailed`, and update its gemspec description, which still says "Typesafe Jev via OpenRouter".
5. Optional cleanups (advisories from review):
   - Name the timeout constants instead of repeating 5 and 30.
   - Add a `selection_env_var` hook so `Providers.env_var_for` stops special-casing System One.
   - Drop the now-redundant `without_provider_env` helper.
   - Simplify `OpenAI#normalize_response` and the Cloudflare pattern checks.
6. Delete the merged remote branch `feat/new-decision-providers` if wanted.

## Open Questions
- Should `http://` base URLs carrying an API key be rejected, except on loopback? It was left open on purpose, but security review flagged it.
- Should refusals stay all-or-nothing (`MissingAnswers`), or should `ask` get a `partial: true` mode that returns good answers plus a refused list?
- Should OpenRouter's default timeout depend on the model, at 30s for vendor-routed slugs?
- Ollama's System One support is cited only from Pydantic AI's docs. Confirm it against Ollama's own docs or a 0.35+ server before advertising it more strongly.
