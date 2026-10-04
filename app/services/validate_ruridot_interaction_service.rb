# frozen_string_literal: true

# A local, account-specific publication boundary. Public visibility is not an
# invitation to target an account, and client-provided allowlists cannot grant it.
class ValidateRuridotInteractionService < BaseService
  def self.guarded?(account)
    account.local? && account.username.casecmp?('ruridot')
  end

  def call(status, quoted_status: status.quote&.quoted_status, unresolved_mentions: [])
    return unless self.class.guarded?(status.account)

    @status = status
    @account = status.account
    @thread = status.thread&.proper
    @quoted_status = quoted_status&.proper

    reject! if unresolved_mentions.any? || (status.reply? && @thread.nil?)

    incoming_sources = [incoming_reply_source, @quoted_status].compact
    invited_account_ids = incoming_sources.filter_map do |source|
      source.account_id if source.account_id != @account.id && source.active_mentions.exists?(account_id: @account.id)
    end

    recipient_ids = status.mentions.map(&:account_id)
    recipient_ids << effective_reply_recipient_id if @thread
    recipient_ids << @quoted_status.account_id if @quoted_status
    recipient_ids << status.quote.quoted_account_id if status.quote

    recipient_ids.uniq.each do |recipient_id|
      next if recipient_id == @account.id

      reject! if recipient_id.nil? || !Account.exists?(id: recipient_id)
      next if Follow.exists?(account_id: recipient_id, target_account_id: @account.id) || invited_account_ids.include?(recipient_id)

      reject!
    end
  end

  private

  # Mirrors Status#set_conversation's resolved routing, including the recipient
  # carried over when replying to one's own reply. The service never uses a
  # client-supplied account ID for this decision.
  def effective_reply_recipient_id
    if @thread.account_id == @account.id && @thread.reply?
      @thread.in_reply_to_account_id
    else
      @thread.account_id
    end
  end

  # Only consecutive self-authored ancestors belong to this continuation. An
  # unrelated historical mention or another participant's invitation cannot
  # authorize the next recipient. Broken/cyclic chains fail closed.
  def incoming_reply_source
    source = @thread
    seen = Set.new

    while source&.account_id == @account.id && source.reply?
      reject! unless seen.add?(source.id)

      source = source.thread&.proper
      reject! if source.nil?
    end

    source
  end

  def reject!
    @status.errors.add(:base, I18n.t('statuses.errors.ruridot_interaction_not_invited'))
    raise ActiveRecord::RecordInvalid, @status
  end
end
