# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostStatusService do
  let(:account) { Fabricate(:account, username: 'ruridot') }
  let(:recipient) { Fabricate(:account) }

  before do
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::StatusUpdateDistributionWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
  end

  it 'allows normal independent media and poll posts' do
    media = Fabricate(:media_attachment, account: account)
    media_status = described_class.new.call(account, text: 'Independent media', media_ids: [media.id], spoiler_text: 'CW', visibility: :unlisted)
    poll_status = described_class.new.call(account, text: 'Independent poll', poll: { options: %w(One Two), expires_in: 3_600 })

    expect(media_status).to be_persisted
    expect(media.reload.status_id).to eq media_status.id
    expect(media_status.spoiler_text).to eq 'CW'
    expect(poll_status.poll.options).to eq %w(One Two)
  end

  it 'rejects uninvited mentions before status, links, quote or distribution effects' do
    media = Fabricate(:media_attachment, account: account)
    quoted_status = Fabricate(:status, account: recipient)

    allow(ProcessLinksService).to receive(:new).and_call_original
    allow(Quote).to receive(:create).and_call_original
    expect do
      described_class.new.call(account, text: "Hello @#{recipient.acct}", quoted_status: quoted_status, media_ids: [media.id])
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(account.statuses.reload).to be_empty
    expect(media.reload.status_id).to be_nil
    expect(ProcessLinksService).to_not have_received(:new)
    expect(Quote).to_not have_received(:create)
    expect(DistributionWorker).to_not have_received(:perform_async)
    expect(ActivityPub::DistributionWorker).to_not have_received(:perform_async)
  end

  it 'does not use client allowed_mentions as authorization' do
    expect do
      described_class.new.call(account, text: "Hello @#{recipient.acct}", allowed_mentions: [recipient.id])
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'rejects mixed allowed and uninvited resolved recipients before publishing' do
    recipient.follow!(account)
    uninvited = Fabricate(:account)

    expect do
      described_class.new.call(account, text: "@#{recipient.acct} @#{uninvited.acct} Hello")
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(account.statuses.reload).to be_empty
    expect(DistributionWorker).to_not have_received(:perform_async)
  end

  it 'does not publish when the current follow lookup fails' do
    allow(Follow).to receive(:exists?).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect do
      described_class.new.call(account, text: "@#{recipient.acct} Hello")
    end.to raise_error(ActiveRecord::ConnectionNotEstablished)

    expect(account.statuses.reload).to be_empty
    expect(DistributionWorker).to_not have_received(:perform_async)
  end

  it 'does not publish when the current source mention lookup fails' do
    incoming = Fabricate(:status, account: recipient)
    mentions = incoming.active_mentions
    allow(incoming).to receive(:active_mentions).and_return(mentions)
    allow(mentions).to receive(:exists?).and_raise(ActiveRecord::ConnectionNotEstablished)

    expect do
      described_class.new.call(account, text: 'Reply', thread: incoming)
    end.to raise_error(ActiveRecord::ConnectionNotEstablished)

    expect(account.statuses.reload).to be_empty
    expect(DistributionWorker).to_not have_received(:perform_async)
  end

  context 'with a remote follower' do
    let(:recipient) { Fabricate(:account, username: 'remote_follower', domain: 'example.test', protocol: :activitypub) }

    before { recipient.follow!(account) }

    it 'allows its resolved mention at creation and edit' do
      status = described_class.new.call(account, text: "@#{recipient.acct} Hello")

      UpdateStatusService.new.call(status, account.id, text: "@#{recipient.acct} Changed")

      expect(status.reload.text).to eq "@#{recipient.acct} Changed"
      expect(status.mentions.reload.pluck(:account_id)).to eq [recipient.id]
      expect(status.edits.ordered.pluck(:text)).to eq ["@#{recipient.acct} Hello", "@#{recipient.acct} Changed"]
    end
  end

  it 'allows invited replies and their self-reply continuations through actual routing' do
    incoming = Fabricate(:status, account: recipient)
    Fabricate(:mention, status: incoming, account: account)
    reply = described_class.new.call(account, text: 'Invited reply', thread: incoming)
    continuation = described_class.new.call(account, text: 'Continuation', thread: reply)

    expect(continuation).to be_persisted
    expect(continuation.in_reply_to_account_id).to eq recipient.id
  end

  it 'checks quote authors before creating their silent access mention' do
    recipient.follow!(account)
    quoted_status = Fabricate(:status, account: recipient)
    status = described_class.new.call(account, text: 'An allowed quote', quoted_status: quoted_status)

    expect(status.quote).to be_persisted
    expect(status.mentions.find_by(account: recipient)).to be_silent
  end

  context 'when mention resolution cannot find an account' do
    let(:resolver) { instance_double(ResolveAccountService, call: nil) }

    before { allow(ResolveAccountService).to receive(:new).and_return(resolver) }

    it 'rejects ruridot rather than publishing unresolved addressing text' do
      expect do
        described_class.new.call(account, text: '@missing@example.test Hello')
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(account.statuses.reload).to be_empty
    end

    it 'preserves unresolved mention behavior for other local accounts' do
      status = described_class.new.call(Fabricate(:account), text: '@missing@example.test Hello')

      expect(status).to be_persisted
    end

    it 'rejects a resolver error instead of silently publishing' do
      allow(resolver).to receive(:call).and_raise(Webfinger::Error)

      expect do
        described_class.new.call(account, text: '@missing@example.test Hello')
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(account.statuses.reload).to be_empty
    end
  end

  it 'rejects addressing an unapproved local account' do
    recipient.user.update!(approved: false)

    expect do
      described_class.new.call(account, text: "@#{recipient.acct} Hello")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'rejects addressing an unavailable account' do
    recipient.suspend!

    expect do
      described_class.new.call(account, text: "@#{recipient.acct} Hello")
    end.to raise_error(ActiveRecord::RecordInvalid)
  end

  context 'when scheduling' do
    it 'allows a normal independent scheduled post' do
      scheduled = described_class.new.call(account, text: 'Independent future', scheduled_at: 2.hours.from_now)

      expect(scheduled).to be_a(ScheduledStatus)
      expect(scheduled).to be_persisted
      expect(account.statuses.reload).to be_empty
    end

    it 'rejects uninvited addressing before accepting a schedule' do
      expect do
        described_class.new.call(account, text: "@#{recipient.acct} Future", scheduled_at: 2.hours.from_now)
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(account.scheduled_statuses).to be_empty
    end

    it 'rechecks follows at publication and inherits destroy-before-rejection semantics' do
      recipient.follow!(account)
      scheduled = described_class.new.call(account, text: "@#{recipient.acct} Future", scheduled_at: 2.hours.from_now)
      recipient.unfollow!(account)

      expect(PublishScheduledStatusWorker.new.perform(scheduled.id)).to be true
      expect(ScheduledStatus.find_by(id: scheduled.id)).to be_nil
      expect(account.statuses.reload).to be_empty
      expect(DistributionWorker).to_not have_received(:perform_async)
    end

    it 'rechecks the explicit invitation at publication' do
      incoming = Fabricate(:status, account: recipient)
      mention = Fabricate(:mention, status: incoming, account: account)
      scheduled = described_class.new.call(account, text: 'Future reply', thread: incoming, scheduled_at: 2.hours.from_now)
      mention.update!(silent: true)

      expect(PublishScheduledStatusWorker.new.perform(scheduled.id)).to be true
      expect(ScheduledStatus.find_by(id: scheduled.id)).to be_nil
      expect(account.statuses.reload).to be_empty
    end

    it 'publishes an independent schedule normally' do
      scheduled = described_class.new.call(account, text: 'Independent future', scheduled_at: 2.hours.from_now)

      PublishScheduledStatusWorker.new.perform(scheduled.id)

      published = account.statuses.reload.sole
      expect(published).to be_persisted
      expect(published.text).to eq 'Independent future'
      expect(ScheduledStatus.find_by(id: scheduled.id)).to be_nil
    end

    context 'with an allowed follower mention, quote and media' do
      let(:media) { Fabricate(:media_attachment, account: account) }
      let(:quoted_status) { Fabricate(:status, account: recipient) }

      before do
        recipient.follow!(account)
        media
        quoted_status
      end

      it 'stages media without persisting status, mention, quote or distribution effects' do
        scheduled = nil

        expect do
          scheduled = described_class.new.call(account, text: "@#{recipient.acct} Future", media_ids: [media.id], quoted_status: quoted_status, scheduled_at: 2.hours.from_now)
        end.to not_change { Status.count }
          .and(not_change { Mention.count })
          .and(not_change { Quote.count })

        expect(media.reload).to have_attributes(status_id: nil, scheduled_status_id: scheduled.id)
        expect(account.statuses.reload).to be_empty
        expect(DistributionWorker).to_not have_received(:perform_async)
      end

      it 'attaches the staged media and quote when publication is still permitted' do
        scheduled = described_class.new.call(account, text: "@#{recipient.acct} Future", media_ids: [media.id], quoted_status: quoted_status, scheduled_at: 2.hours.from_now)

        PublishScheduledStatusWorker.new.perform(scheduled.id)

        published = account.statuses.reload.sole
        expect(published).to be_persisted
        expect(media.reload).to have_attributes(status_id: published.id, scheduled_status_id: nil)
        expect(published.quote.quoted_status).to eq quoted_status
      end
    end
  end

  context 'when editing' do
    let(:status) { Fabricate(:status, account: account, text: 'Original', language: 'en') }

    it 'allows clearing text when adding media before the final status validation' do
      media = Fabricate(:media_attachment, account: account)

      UpdateStatusService.new.call(status, account.id, text: '', media_ids: [media.id])

      expect(status.reload.text).to be_empty
      expect(status.ordered_media_attachment_ids).to eq [media.id]
      expect(media.reload.status_id).to eq status.id
    end

    context 'with an existing video thumbnail' do
      let(:media) { Fabricate(:media_attachment, account: account, status: status, type: :video, thumbnail: attachment_fixture('attachment.jpg')) }
      let(:options) do
        {
          text: "@#{recipient.acct} Changed",
          media_ids: [media.id],
          media_attributes: [{ id: media.id, thumbnail: attachment_fixture('600x400.png') }],
        }
      end

      before { status.update!(ordered_media_attachment_ids: [media.id]) }

      it 'rejects before media updates and preserves the original thumbnail bytes' do
        service = UpdateStatusService.new
        original_thumbnail = File.binread(media.thumbnail.path(:original))
        allow(service).to receive(:update_media_attachments!).and_call_original

        expect { service.call(status, account.id, options) }.to raise_error(ActiveRecord::RecordInvalid)

        expect(service).to_not have_received(:update_media_attachments!)
        expect(File.binread(media.thumbnail.path(:original))).to eq original_thumbnail
        expect(status.reload.text).to eq 'Original'
        expect(status.edits).to be_empty
      end

      it 'preserves allowed thumbnail edits' do
        recipient.follow!(account)

        UpdateStatusService.new.call(status, account.id, options)

        expect(status.reload.text).to eq "@#{recipient.acct} Changed"
        expect(media.reload.thumbnail_file_name).to eq '600x400.png'
        expect(media.thumbnail_content_type).to eq 'image/png'
      end
    end

    context 'when a rejected edit would mutate existing media and a poll' do
      subject(:attempt_edit) do
        UpdateStatusService.new.call(status, account.id,
                                     text: 'Changed',
                                     media_ids: [replacement_media.id],
                                     media_attributes: [{ id: replacement_media.id, description: 'Changed description' }],
                                     poll: { options: %w(Changed Choices), multiple: false, expires_in: 3_600 })
      end

      let(:original_media) { Fabricate(:media_attachment, account: account, status: status) }
      let(:replacement_media) { Fabricate(:media_attachment, account: account, description: nil) }
      let(:poll) { Fabricate(:poll, account: account, status: status) }
      let(:vote) { Fabricate(:poll_vote, poll: poll) }
      let(:original_mention) { Fabricate(:mention, account: recipient, status: status) }

      before do
        status.update!(poll_id: poll.id, ordered_media_attachment_ids: [original_media.id])
        vote
        recipient.follow!(account)
        original_mention
        recipient.unfollow!(account)
      end

      it 'rolls back text, media, polls, votes, mentions and edit history' do
        expect(status.preloadable_poll).to eq poll
        expect { attempt_edit }.to raise_error(ActiveRecord::RecordInvalid)
        expect(status.reload).to have_attributes(text: 'Original', ordered_media_attachment_ids: [original_media.id])
        expect(status.edits).to be_empty
        expect(replacement_media.reload).to have_attributes(status_id: nil, description: nil)
        expect(poll.reload.options).to eq %w(Foo Bar)
        expect(poll.votes).to include(vote)
        expect(original_mention.reload).to_not be_silent
      end

      it 'does not enqueue publication or preview work' do
        expect { attempt_edit }.to raise_error(ActiveRecord::RecordInvalid)
        expect(DistributionWorker).to_not have_received(:perform_async)
        expect(ActivityPub::StatusUpdateDistributionWorker).to_not have_received(:perform_async)
        expect(LinkCrawlWorker).to_not have_received(:perform_async)
      end
    end

    it 'preserves a no-op edit without creating history or distribution' do
      result = UpdateStatusService.new.call(status, account.id, text: 'Original')

      expect(result).to eq status
      expect(status.reload.edits).to be_empty
      expect(DistributionWorker).to_not have_received(:perform_async)
      expect(ActivityPub::StatusUpdateDistributionWorker).to_not have_received(:perform_async)
    end

    it 'rejects a newly added uninvited mention without changing the saved post' do
      expect do
        UpdateStatusService.new.call(status, account.id, text: "Changed @#{recipient.acct}")
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(status.reload.text).to eq 'Original'
      expect(status.mentions).to be_empty
      expect(status.edits).to be_empty
    end

    it 'checks retained silent mentions even for a non-text edit' do
      Fabricate(:mention, account: recipient, status: status, silent: true)

      expect do
        UpdateStatusService.new.call(status, account.id, spoiler_text: 'New CW')
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(status.reload.spoiler_text).to be_empty
    end

    it 'preserves preview reset and edit history for a valid scoped edit' do
      preview_card = Fabricate(:preview_card)
      PreviewCardsStatus.create!(status: status, preview_card: preview_card)

      UpdateStatusService.new.call(status, account.id, text: 'Changed')

      expect(status.reload.text).to eq 'Changed'
      expect(status.preview_card).to be_nil
      expect(status.edits.ordered.pluck(:text)).to eq %w(Original Changed)
      expect(LinkCrawlWorker).to have_received(:perform_async).with(status.id)
      expect(ActivityPub::StatusUpdateDistributionWorker).to have_received(:perform_async).with(status.id)
    end

    it 'allows a retained silent mention for a current follower' do
      recipient.follow!(account)
      mention = Fabricate(:mention, account: recipient, status: status, silent: true)

      UpdateStatusService.new.call(status, account.id, spoiler_text: 'New CW')

      expect(status.reload.spoiler_text).to eq 'New CW'
      expect(mention.reload).to be_silent
    end

    it 'uses the status author rather than the editor account ID' do
      expect do
        UpdateStatusService.new.call(status, Fabricate(:account).id, text: "@#{recipient.acct} Changed")
      end.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'rolls back an edit when the current follow lookup fails' do
      allow(Follow).to receive(:exists?).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect do
        UpdateStatusService.new.call(status, account.id, text: "@#{recipient.acct} Changed")
      end.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(status.reload.text).to eq 'Original'
      expect(status.mentions).to be_empty
      expect(status.edits).to be_empty
      expect(ActivityPub::StatusUpdateDistributionWorker).to_not have_received(:perform_async)
    end

    context 'when a quote invitation was withdrawn' do
      let(:quoted_status) { Fabricate(:status, account: recipient) }
      let(:invitation) { Fabricate(:mention, status: quoted_status, account: account) }
      let(:status) { described_class.new.call(account, text: 'Allowed quote', quoted_status: quoted_status) }

      before do
        invitation
        status
        invitation.destroy!
      end

      it 'rechecks the quote author and retained silent recipient before editing' do
        expect do
          UpdateStatusService.new.call(status, account.id, text: 'Changed quote')
        end.to raise_error(ActiveRecord::RecordInvalid)

        expect(status.reload.text).to eq 'Allowed quote'
        expect(status.edits).to be_empty
        expect(status.mentions.find_by(account: recipient)).to be_silent
        expect(ActivityPub::StatusUpdateDistributionWorker).to_not have_received(:perform_async)
      end
    end
  end
end
