# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ValidateRuridotInteractionService do
  subject(:validate) { described_class.new.call(status, quoted_status: quoted_status, unresolved_mentions: unresolved_mentions) }

  let(:account) { Fabricate(:account, username: 'ruridot') }
  let(:recipient) { Fabricate(:account) }
  let(:status) { account.statuses.build(text: 'Hello', visibility: :public) }
  let(:quoted_status) { nil }
  let(:unresolved_mentions) { [] }

  it 'allows normal independent posts' do
    expect { validate }.to_not raise_error
  end

  context 'with a resolved mention' do
    before { status.mentions.build(account: recipient) }

    it 'rejects an uninvited recipient even for public posts' do
      expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
    end

    context 'when the recipient follows ruridot' do
      before { recipient.follow!(account) }

      it 'allows the mention' do
        expect { validate }.to_not raise_error
      end

      it 'rechecks the current follow rather than a cached relationship' do
        recipient.following?(account)
        recipient.unfollow!(account)

        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when ruridot follows the recipient instead' do
      before { account.follow!(recipient) }

      it 'rejects the opposite follow direction' do
        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when a follow request is pending' do
      before { Fabricate(:follow_request, account: recipient, target_account: account) }

      it 'requires an actual follow' do
        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when a different local account is posting' do
      let(:account) { Fabricate(:account) }

      it 'preserves existing behavior' do
        expect { validate }.to_not raise_error
      end
    end

    context 'when a remote account is named ruridot' do
      let(:account) { Fabricate(:account, username: 'ruridot', domain: 'example.test') }

      it 'does not apply the local account policy' do
        expect { validate }.to_not raise_error
      end
    end
  end

  context 'when mentioning itself' do
    before { status.mentions.build(account: account) }

    it 'allows the self mention' do
      expect { validate }.to_not raise_error
    end
  end

  context 'with unresolved mention data' do
    let(:unresolved_mentions) { ['@missing@example.test'] }

    it 'fails closed' do
      expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
    end

    context 'when another local account is posting' do
      let(:account) { Fabricate(:account) }

      it 'preserves its existing handling of unresolved mentions' do
        expect { validate }.to_not raise_error
      end
    end
  end

  context 'with a missing resolved recipient' do
    before { status.mentions.build(account_id: -1) }

    it 'fails closed' do
      expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  context 'when a recipient lookup fails' do
    before do
      status.mentions.build(account: recipient)
      allow(Account).to receive(:exists?).and_raise(ActiveRecord::ConnectionNotEstablished)
    end

    it 'does not turn the error into permission' do
      expect { validate }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end
  end

  context 'when replying to an incoming post' do
    let(:incoming) { Fabricate(:status, account: recipient) }

    before { status.thread = incoming }

    it 'rejects an uninvited reply without textual mentions' do
      expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
    end

    context 'when its author follows ruridot' do
      before { recipient.follow!(account) }

      it 'allows the reply' do
        expect { validate }.to_not raise_error
      end
    end

    context 'when that post explicitly mentions ruridot' do
      before { Fabricate(:mention, status: incoming, account: account) }

      it 'allows its author' do
        expect { validate }.to_not raise_error
      end

      it 'does not extend that invitation to another recipient' do
        status.mentions.build(account: Fabricate(:account))

        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end

      it 'rechecks a withdrawn explicit mention' do
        incoming.mentions.update_all(silent: true)

        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end

      context 'when continuing consecutive self replies' do
        let(:first_reply) { Fabricate(:status, account: account, thread: incoming) }
        let(:continuation) { Fabricate(:status, account: account, thread: first_reply) }

        before { status.thread = continuation }

        it 'uses the same bounded incoming invitation and carried-over recipient' do
          expect(continuation.in_reply_to_account_id).to eq recipient.id
          expect { validate }.to_not raise_error
        end

        it 'checks a mismatched carried-over recipient independently' do
          continuation.update_column(:in_reply_to_account_id, Fabricate(:account).id)

          expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
        end

        it 'rejects a broken self-reply chain' do
          allow(continuation).to receive(:thread).and_return(nil)

          expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
        end

        it 'rejects a cyclic self-reply chain' do
          allow(continuation).to receive(:thread).and_return(continuation)

          expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end

    context 'when that post only grants silent access to ruridot' do
      before { Fabricate(:mention, status: incoming, account: account, silent: true) }

      it 'does not treat access as an invitation' do
        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when an unrelated older post mentioned ruridot' do
      before { Fabricate(:mention, status: Fabricate(:status, account: recipient), account: account) }

      it 'does not borrow the older invitation' do
        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when replying to a boost' do
      before { status.thread = Fabricate(:status, reblog: incoming) }

      it 'checks the original author rather than the boosting account' do
        status.thread.account.follow!(account)

        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  context 'when quoting a post' do
    let(:quoted_status) { Fabricate(:status, account: recipient) }

    it 'rejects an uninvited author without textual mentions' do
      expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
    end

    context 'when the quote source explicitly mentions ruridot' do
      before { Fabricate(:mention, status: quoted_status, account: account) }

      it 'allows the source author' do
        expect { validate }.to_not raise_error
      end

      it 'does not grant permission for a different reply author' do
        status.thread = Fabricate(:status)

        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when the quote source only silently mentions ruridot' do
      before { Fabricate(:mention, status: quoted_status, account: account, silent: true) }

      it 'rejects the quote' do
        expect { validate }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end
end
