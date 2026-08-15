# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LabeledLinkParser do
  describe '.extract_entities_with_indices' do
    subject(:entities) { described_class.extract_entities_with_indices(text) }

    context 'with a labeled HTTP link' do
      let(:text) { 'See [the example](http://example.com/path).' }

      it 'extracts the label, URL, and full syntax range' do
        expect(entities).to contain_exactly(
          label: 'the example',
          url: 'http://example.com/path',
          indices: [4, 42]
        )
      end
    end

    context 'with parentheses in the URL' do
      let(:text) { '[article](https://en.wikipedia.org/wiki/Diaspora_(software))' }

      it 'keeps balanced parentheses in the URL' do
        expect(entities.first).to include(
          label: 'article',
          url: 'https://en.wikipedia.org/wiki/Diaspora_(software)'
        )
      end
    end

    context 'with multiple labeled links' do
      let(:text) { '[one](https://one.example) [two](https://two.example)' }

      it 'extracts each link' do
        expect(entities.pluck(:label)).to eq %w(one two)
      end
    end

    context 'with an unsupported URL scheme' do
      let(:text) { '[label](javascript:alert(1))' }

      it { is_expected.to be_empty }
    end

    context 'with an empty label' do
      let(:text) { '[](https://example.com)' }

      it { is_expected.to be_empty }
    end

    context 'with a multiline label' do
      let(:text) { "[first\nsecond](https://example.com)" }

      it { is_expected.to be_empty }
    end

    context 'with a relative URL' do
      let(:text) { '[label](/about)' }

      it { is_expected.to be_empty }
    end

    context 'with an excessively long URL' do
      let(:text) { "[label](https://example.com/#{'a' * 4096})" }

      it { is_expected.to be_empty }
    end
  end

  describe '.rewrite' do
    subject { described_class.rewrite(text) { |entity| entity[:label] } }

    let(:text) { 'See [the example](https://example.com).' }

    it 'replaces the full syntax' do
      expect(subject).to eq 'See the example.'
    end
  end
end
