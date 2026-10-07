# frozen_string_literal: true

require "json"

module RubyDecisionModel
  module Providers
    # A provider owns everything that differs between decision-model APIs:
    # where requests go, how they are authenticated, which model is the
    # default, which model names are aliases, how the request is encoded, and
    # how the response is read back. Client keeps the public API and
    # delegates these questions here.
    #
    # The defaults speak the System One wire format that Typesafe published
    # with Jev: questions keyed by id, answers keyed by id. A provider whose
    # API differs overrides request_body and normalize_response, translating
    # to and from that shape, so Client only ever sees System One answers.
    class Base
      attr_reader :api_key

      def initialize(api_key: nil, base_url: nil)
        @api_key = api_key || ENV.fetch(env_var, nil)
        @base_url = base_url
      end

      # Identifier used in error messages and by Client#provider.
      def name
        raise NotImplementedError
      end

      def env_var
        raise NotImplementedError
      end

      def default_base_url
        raise NotImplementedError
      end

      def endpoint_path
        raise NotImplementedError
      end

      def default_model
        raise NotImplementedError
      end

      # Map of alias => canonical model name for this provider.
      def aliases
        {}
      end

      # Whether this provider reports a per-request cost in usage.
      def reports_cost?
        false
      end

      # Read timeout in seconds when Client gets timeout: nil. The open
      # timeout stays at Client::DEFAULT_OPEN_TIMEOUT.
      def default_timeout
        5
      end

      # Whether requests may carry images. Client refuses images: for a
      # provider that says no, before anything goes over the wire.
      def supports_images?
        false
      end

      # Response header carrying the provider's request id, or nil.
      # Typesafe's, which 0.1.0 read for every provider and System One
      # servers that follow Typesafe send too. Vendors with their own header
      # override it.
      def request_id_header
        "x-typesafe-request-id"
      end

      # Whether a request without an API key is meaningful. Self-hosted
      # servers often run without auth.
      def requires_api_key?
        true
      end

      # Values from env files often carry stray whitespace.
      def base_url
        (@base_url || default_base_url).to_s.strip.chomp("/")
      end

      # The model is passed for providers that put it in the path.
      def url(_model = nil)
        "#{base_url}#{endpoint_path}"
      end

      def api_key?
        !(api_key.nil? || api_key.to_s.strip.empty?)
      end

      # Raises ConfigurationError naming whatever is missing.
      def validate!
        return unless requires_api_key? && !api_key?

        raise ConfigurationError, "api_key is required for #{name}: pass api_key: or set #{env_var}"
      end

      # True when validate! would pass. Used to pick a provider from the
      # environment.
      def configured?
        validate!
        true
      rescue ConfigurationError
        false
      end

      # Nil or blank means the provider default. Known aliases resolve to the
      # provider's canonical name. Anything else passes through untouched.
      def resolve_model(model)
        return default_model if model.nil? || model.to_s.strip.empty?

        aliases.fetch(model.to_s, model.to_s)
      end

      def headers
        headers = {
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "ruby_decision_model/#{VERSION}"
        }
        # Keys read from files often end in a newline, which Net::HTTP
        # rejects in a header.
        headers["Authorization"] = "Bearer #{api_key.to_s.strip}" if api_key?
        headers
      end

      # Client passes images: only when the caller supplied some, so a
      # subclass that does not take images can keep a three-keyword
      # signature.
      def request_body(model:, state:, questions:, images: nil)
        body = { "model" => model, "state" => state, "questions" => questions }
        body["images"] = images if images
        JSON.generate(body)
      end

      # Turns a parsed success body into the System One shape Client reads:
      # a Hash with "answers" keyed by question id, plus "id", "model", and
      # "usage". `questions` is the Hash the caller asked, for providers that
      # need it to map answers back. Noul answers that arrive without a
      # probability split get one.
      def normalize_response(parsed, questions:)
        fill_noul_probabilities(parsed)
      end

      # The vendor's reason for a failed request, read from the error body,
      # or nil. Appended to the ApiError message. Knows the shapes the
      # supported APIs use:
      #   {"error": {"message": ...}}      OpenAI, Perplexity, OpenRouter
      #   {"errors": [{"message": ...}]}   Cloudflare
      #   {"detail": [{"loc", "msg"}]}     Typesafe and other FastAPI servers
      #   {"message": ...}                 Databricks REST
      def error_message(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? vendor_text(error_text(parsed)) : nil
      rescue JSON::ParserError, EncodingError
        nil
      end

      def usage(parsed)
        raw = parsed.is_a?(Hash) && parsed["usage"].is_a?(Hash) ? parsed["usage"] : {}

        Response::Usage.new(
          input_tokens: Integer(raw["input_tokens"], exception: false),
          output_tokens: Integer(raw["output_tokens"], exception: false),
          cost: reports_cost? ? Float(raw["cost"], exception: false) : nil
        )
      end

      # Keeps the API key out of logs and error output.
      def inspect
        "#<#{self.class.name} name=#{name.inspect} base_url=#{base_url.inspect} api_key=#{api_key? ? '[REDACTED]' : 'nil'}>"
      end

      # Applies non-nil overrides in place. Used when a caller hands Client a
      # provider instance together with api_key: or base_url:.
      def configure(api_key: nil, base_url: nil)
        @api_key = api_key unless api_key.nil?
        @base_url = base_url unless base_url.nil?
        self
      end

      private

      ERROR_MESSAGE_LIMIT = 500

      def error_text(parsed)
        error = parsed["error"]
        return error if error.is_a?(String)
        return error["message"].to_s if error.is_a?(Hash) && error["message"]

        errors = parsed["errors"]
        if errors.is_a?(Array) && errors.any?
          return errors.map { |item| item.is_a?(Hash) ? item["message"] || item.to_s : item.to_s }.join("; ")
        end

        detail = parsed["detail"]
        return detail if detail.is_a?(String)
        return detail.map { |item| detail_text(item) }.join("; ") if detail.is_a?(Array) && detail.any?

        (parsed["message"] || parsed["error_message"])&.to_s
      end

      def detail_text(item)
        return item.to_s unless item.is_a?(Hash)

        location = Array(item["loc"]).join(".")
        location.empty? ? item["msg"].to_s : "#{location}: #{item['msg']}"
      end

      # Vendor-supplied text bound for an exception message, which tends to
      # end up in logs: blank becomes nil, the API key is masked in case a
      # vendor echoes it, and the length is capped.
      def vendor_text(text)
        # Net::HTTP hands back binary bodies; a proxy's error page can carry
        # bytes that are not UTF-8, which strip and gsub would raise on.
        text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        # Control characters could forge log lines or drive a terminal when
        # the vendor echoes caller input; each run becomes one space.
        text = text.gsub(/[[:cntrl:]]+/, " ").strip
        return nil if text.empty?

        key = api_key.to_s.strip
        text = text.gsub(key, "[REDACTED]") if key.length >= 8
        text.length > ERROR_MESSAGE_LIMIT ? "#{text[0, ERROR_MESSAGE_LIMIT]}..." : text
      end

      # Several APIs answer a noul with the probability alone. Fill in the
      # two-way split Jev sends so Answers::Noul#probabilities reads the same
      # everywhere.
      def noul_probabilities(answer)
        return answer unless answer.is_a?(Hash) && answer["type"] == "noul"
        return answer if answer["probabilities"].is_a?(Hash) && !answer["probabilities"].empty?

        probability = answer["noul"]
        return answer unless probability.is_a?(Numeric)

        answer.merge("probabilities" => { "true" => probability.to_f, "false" => 1.0 - probability.to_f })
      end

      def fill_noul_probabilities(parsed)
        return parsed unless parsed.is_a?(Hash) && parsed["answers"].is_a?(Hash)

        parsed.merge("answers" => parsed["answers"].transform_values { |answer| noul_probabilities(answer) })
      end
    end
  end
end
