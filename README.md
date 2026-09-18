# ruby_decision_model

Decision models answer typed questions about a state with calibrated probabilities,
instead of generating text. This gem is a dependency-free Ruby client for them,
starting with OpenRouter's `/decisions` endpoint and Typesafe Jev.

## Install

```ruby
gem "ruby_decision_model"
```

## Usage

```ruby
require "ruby_decision_model"

client = RubyDecisionModel::Client.new(api_key: ENV["OPENROUTER_API_KEY"])

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
response.usage.cost           # => 0.0012
```

## Errors

| Error | Meaning |
| --- | --- |
| `ConfigurationError` | Missing api_key, model, or base_url |
| `RequestError` | Questions hash was empty |
| `TransportError` (`TimeoutError`) | Network or timeout failure |
| `ApiError` (`Unauthorized`, `PayloadTooLarge`, `RateLimited`) | Non-2xx response, carries `#status` and `#body` |
| `InvalidResponse` | Body wasn't JSON, wasn't a Hash, or an answer was malformed |
| `MissingAnswers` | One or more question ids came back missing or wrong-typed, carries `#missing` |

Status: 0.0.1, API may change.

The companion gem `ruby_dm` builds decisions and verdicts on top of this client.
