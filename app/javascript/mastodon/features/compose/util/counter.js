import { length } from 'stringz';

import { urlRegex } from './url_regex';

const urlPlaceholderChars = 23;
const maxLabeledLinkUrlChars = 4096;
const urlPlaceholder = `$2${'x'.repeat(urlPlaceholderChars)}`;
const labeledLinkRegex =
  /\[([^\][\r\n]+)\]\((https?:\/\/[^\s<>()\\]+(?:\([^\s<>()\\]*\)[^\s<>()\\]*)*)\)/giu;

function countableLabeledLinks(inputText) {
  return inputText.replace(labeledLinkRegex, (match, label, url) => {
    if (length(url) > maxLabeledLinkUrlChars) {
      return 'x'.repeat(length(match));
    }

    try {
      const parsedUrl = new URL(url);
      if (!['http:', 'https:'].includes(parsedUrl.protocol) || !parsedUrl.hostname || !label.trim()) {
        return match;
      }

      return 'x'.repeat(Math.max(length(label), urlPlaceholderChars));
    } catch {
      return match;
    }
  });
}

export function countableText(inputText) {
  return countableLabeledLinks(inputText)
    .replace(urlRegex, urlPlaceholder)
    .replace(/(^|[^/\w])@(([a-z0-9_]+)@[a-z0-9.-]+[a-z0-9]+)/ig, '$1@$3');
}
