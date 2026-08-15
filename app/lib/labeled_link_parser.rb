# frozen_string_literal: true

class LabeledLinkParser
  MAX_URL_LENGTH = 4096

  LINK_PATTERN = %r{
    \[
      (?<label>[^\[\]\r\n]+)
    \]
    \(
      (?<url>
        https?://
        [^\s<>()\\]+
        (?:\([^\s<>()\\]*\)[^\s<>()\\]*)*
      )
    \)
  }ix

  class << self
    def extract_entities_with_indices(text)
      return [] if text.blank?

      text.to_enum(:scan, LINK_PATTERN).filter_map do
        match = Regexp.last_match
        next if match[:label].strip.blank? || !valid_url?(match[:url])

        {
          label: match[:label],
          url: match[:url],
          indices: [match.char_begin(0), match.char_end(0)],
        }
      end
    end

    def rewrite(text)
      result = +''
      last_index = extract_entities_with_indices(text).reduce(0) do |index, entity|
        result << text[index...entity[:indices].first]
        result << yield(entity)
        entity[:indices].last
      end

      result << text[last_index..]
    end

    private

    def valid_url?(url)
      return false if url.length > MAX_URL_LENGTH

      uri = Addressable::URI.parse(url)
      %w(http https).include?(uri.scheme&.downcase) && uri.host.present?
    rescue Addressable::URI::InvalidURIError
      false
    end
  end
end
