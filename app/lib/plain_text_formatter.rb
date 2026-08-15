# frozen_string_literal: true

class PlainTextFormatter
  NEWLINE_TAGS_RE = %r{(<br />|<br>|</p>)+}

  attr_reader :text, :local, :with_labeled_links

  alias local? local

  def initialize(text, local, with_labeled_links: false)
    @text               = text
    @local              = local
    @with_labeled_links = with_labeled_links
  end

  def to_s
    if local?
      local_text
    else
      begin
        node = Nokogiri::HTML5.fragment(insert_newlines)
      rescue ArgumentError
        # This can happen if one of the Nokogumbo limits is encountered
        # Unfortunately, it does not use a more precise error class
        # nor allows more graceful handling
        return ''
      end

      # Elements that are entirely removed with our Sanitize config
      node.xpath('.//iframe|.//math|.//noembed|.//noframes|.//noscript|.//plaintext|.//script|.//style|.//svg|.//xmp').remove
      node.text.chomp
    end
  end

  private

  def local_text
    return text unless with_labeled_links

    LabeledLinkParser.rewrite(text) { |entity| entity[:label] }
  end

  def insert_newlines
    text.gsub(NEWLINE_TAGS_RE) { |match| "#{match}\n" }
  end
end
