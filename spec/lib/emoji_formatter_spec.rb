# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiFormatter do
  let!(:emoji) { Fabricate(:custom_emoji, shortcode: 'coolcat') }

  def preformat_text(str)
    TextFormatter.new(str).to_s
  end

  describe '#to_s' do
    subject { described_class.new(text, emojis).to_s }

    let(:emojis) { [emoji] }

    context 'when given text that is not marked as html-safe' do
      let(:text) { 'Foo' }

      it 'raises an argument error' do
        expect { subject }.to raise_error ArgumentError
      end
    end

    context 'when given text with an emoji shortcode at the start' do
      let(:text) { preformat_text(':coolcat: Beep boop') }

      it 'converts the shortcode to an image tag' do
        expect(subject).to include('<img rel="emoji" draggable="false" width="16" height="16" class="emojione custom-emoji" alt=":coolcat:"')
      end
    end

    context 'when given text with an emoji shortcode in the middle' do
      let(:text) { preformat_text('Beep :coolcat: boop') }

      it 'converts the shortcode to an image tag' do
        expect(subject).to include('Beep <img rel="emoji" draggable="false" width="16" height="16" class="emojione custom-emoji" alt=":coolcat:"')
      end
    end

    context 'when given text with concatenated emoji shortcodes' do
      let(:text) { preformat_text(':coolcat::coolcat:') }

      it 'converts both shortcodes to image tags' do
        expect(subject.scan('alt=":coolcat:"').size).to eq 2
        expect(subject).to_not include(':coolcat::coolcat:')
      end
    end

    context 'when given text with an emoji shortcode directly after alphanumeric characters' do
      let(:text) { preformat_text('Beep:coolcat: あ:coolcat:') }

      it 'converts the shortcodes to image tags' do
        expect(subject).to include('Beep<img rel="emoji"')
        expect(subject).to include('あ<img rel="emoji"')
      end
    end

    context 'when given text with an emoji shortcode followed by an ASCII alphanumeric character' do
      let(:text) { preformat_text(':coolcat:boop') }

      it 'does not touch the shortcode' do
        expect(subject).to include(':coolcat:boop')
        expect(subject).to_not include('<img')
      end
    end

    context 'when given text with an unknown shortcode before a known one' do
      let(:text) { preformat_text(':unknown::coolcat:') }

      it 'converts only the known shortcode' do
        expect(subject).to include(':unknown:<img rel="emoji"')
      end
    end

    context 'when given text with an emoji shortcode at the end' do
      let(:text) { preformat_text('Beep boop :coolcat:') }

      it 'converts the shortcode to an image tag' do
        expect(subject).to include('boop <img rel="emoji" draggable="false" width="16" height="16" class="emojione custom-emoji" alt=":coolcat:"')
      end
    end
  end
end
