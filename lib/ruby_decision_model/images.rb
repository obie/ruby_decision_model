# frozen_string_literal: true

module RubyDecisionModel
  # Builds the base64 data URLs that Client#ask takes as images:. Every
  # provider that reads images wants them embedded; none fetch a remote URL.
  module Images
    CONTENT_TYPES = {
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".webp" => "image/webp",
      ".gif" => "image/gif"
    }.freeze

    module_function

    def data_url(bytes, content_type:)
      raise ArgumentError, "content_type must be an image/* type, got #{content_type.inspect}" unless content_type.to_s.start_with?("image/")

      # pack("m0") is strict base64 without the base64 gem, which leaves the
      # default gems in Ruby 3.4.
      "data:#{content_type};base64,#{[bytes].pack('m0')}"
    end

    # Reads a file and infers its type from the extension.
    def from_file(path, content_type: nil)
      content_type ||= CONTENT_TYPES[File.extname(path.to_s).downcase]
      raise ArgumentError, "cannot infer an image type for #{path}; pass content_type:" if content_type.nil?

      data_url(File.binread(path), content_type: content_type)
    end
  end
end
