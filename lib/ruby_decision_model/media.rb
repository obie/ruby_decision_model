# frozen_string_literal: true

require_relative "images"

module RubyDecisionModel
  # Builds the base64 data URLs that Client#ask takes as images:, audio:, and
  # videos:. Images has the image-only version of the same helpers.
  module Media
    CONTENT_TYPES = Images::CONTENT_TYPES.merge(
      ".wav" => "audio/wav",
      ".mp3" => "audio/mpeg",
      ".mp4" => "video/mp4",
      ".webm" => "video/webm"
    ).freeze

    module_function

    def data_url(bytes, content_type:)
      unless content_type.to_s.start_with?("image/", "audio/", "video/")
        raise ArgumentError, "content_type must be an image/*, audio/*, or video/* type, got #{content_type.inspect}"
      end

      # pack("m0") is strict base64 without the base64 gem, which leaves the
      # default gems in Ruby 3.4.
      "data:#{content_type};base64,#{[bytes].pack('m0')}"
    end

    # Reads a file and infers its type from the extension.
    def from_file(path, content_type: nil)
      content_type ||= CONTENT_TYPES[File.extname(path.to_s).downcase]
      raise ArgumentError, "cannot infer a media type for #{path}; pass content_type:" if content_type.nil?

      data_url(File.binread(path), content_type: content_type)
    end
  end
end
