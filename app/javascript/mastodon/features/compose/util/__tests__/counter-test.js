import { countableText } from '../counter';

describe('countableText', () => {
  test('counts a labeled link with a short label as 23 characters', () => {
    expect(countableText('[label](https://example.com)')).toHaveLength(23);
  });

  test('counts a labeled link with a long label by its label length', () => {
    const label = 'a'.repeat(30);

    expect(countableText(`[${label}](https://example.com)`)).toHaveLength(30);
  });

  test('counts Unicode labels by grapheme cluster', () => {
    const label = '🏳️‍⚧️'.repeat(24);

    expect(countableText(`[${label}](https://example.com)`)).toHaveLength(24);
  });

  test('supports balanced parentheses in the URL', () => {
    expect(countableText('[article](https://en.wikipedia.org/wiki/Diaspora_(software))')).toHaveLength(23);
  });

  test('does not apply labeled-link counting to unsupported schemes', () => {
    expect(countableText('[label](javascript:alert(1))')).toBe('[label](javascript:alert(1))');
  });

  test('does not shorten an excessively long target URL', () => {
    const text = `[label](https://example.com/${'a'.repeat(4096)})`;

    expect(countableText(text)).toHaveLength(text.length);
  });
});
