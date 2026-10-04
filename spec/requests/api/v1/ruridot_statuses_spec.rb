# frozen_string_literal: true

require 'rails_helper'

RSpec.describe '/api/v1/statuses ruridot validation' do
  include_context 'with API authentication'

  let(:user) { Fabricate(:user, account_attributes: { username: 'ruridot' }) }
  let(:scopes) { 'write:statuses' }
  let(:recipient) { Fabricate(:account) }

  it 'uses existing 422 responses and ignores a forged posting account ID' do
    post '/api/v1/statuses', headers: headers, params: { status: "@#{recipient.acct} Hello", account_id: recipient.id, allowed_mentions: [recipient.id] }

    expect(response).to have_http_status(422)
    expect(response.parsed_body[:error]).to include('ruridot')
    expect(user.account.statuses).to be_empty
  end

  it 'returns 422 for a rejected edit without durable changes' do
    status = Fabricate(:status, account: user.account, text: 'Original')

    put "/api/v1/statuses/#{status.id}", headers: headers, params: { status: "@#{recipient.acct} Changed" }

    expect(response).to have_http_status(422)
    expect(status.reload.text).to eq 'Original'
    expect(status.edits).to be_empty
    expect(status.mentions).to be_empty
  end

  it 'returns 422 without accepting an uninvited scheduled post' do
    post '/api/v1/statuses', headers: headers, params: { status: "@#{recipient.acct} Future", scheduled_at: 2.hours.from_now.iso8601 }

    expect(response).to have_http_status(422)
    expect(user.account.scheduled_statuses).to be_empty
  end

  it 'preserves normal independent posting' do
    post '/api/v1/statuses', headers: headers, params: { status: 'Independent post' }

    expect(response).to have_http_status(200)
    expect(user.account.statuses.first.text).to eq 'Independent post'
  end
end
