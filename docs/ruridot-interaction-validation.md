# Draft: local ruridot interaction validation

This draft is based on `stellarianetwork/mastodon` branch `ver4.7.3`, commit
`6c2e9ffbdac582920dae89f7f44d94c1b8cacda3`. It does not deploy anything or
execute live Mastodon interactions.

## Intended policy

Only the server-resolved local account named `ruridot` is subject to this policy.
Client account IDs and `allowed_mentions` do not grant authorization.

- Normal independent posts, media, polls, content warnings and visibility choices
  remain available.
- Every resolved mention (including a retained silent mention on edit), effective
  reply recipient and quote author is checked individually.
- A recipient qualifies by currently following ruridot, or by authoring the
  current incoming reply/quote source that explicitly mentions ruridot.
- For self-reply continuations, only consecutive ruridot-authored ancestors are
  traversed. The first other-author ancestor is the bounded incoming source.
  Its current explicit mention can authorize its own author only.
- Public visibility, following a recipient, old unrelated mentions and another
  participant's invitation do not authorize targeting someone.
- Missing/unresolved recipient data and failed mention resolution must not
  silently allow targeted publication. Other accounts retain existing behavior.
- Edits must reject inside their mutation transaction, before durable changes or
  distribution. Scheduled posts must pass at acceptance and again at publication.

## Planned checks and limits

Focused Ruby specs will cover independent posts, mentions, reply/quote context,
self-reply chains, extra recipients, unresolved mentions, atomic rejected edits,
media/polls and scheduled publication revalidation.

The existing scheduled worker destroys the schedule first and rescues
`ActiveRecord::RecordInvalid`. A rejected publication is therefore removed rather
than retried. This draft does not replace that scheduling behavior.

Existing queued distribution, arbitrary links/plain text references, favourites,
boosts and follows are outside this post/edit/schedule validation boundary.
Ordinary follower, relay, hashtag and existing-interactor distribution remains
Mastodon's responsibility. This guard checks authored directed interactions;
it does not claim that every eventual delivery recipient is individually invited.

All authored implementation and test sources are committed to the public head
branch. No live Mastodon writes are used for testing.

### Verification status

The implementation and focused Rails service/request specs are included. Ruby
syntax and whitespace checks passed. The locked bundle installs successfully
with the exact repository-pinned Ruby 4.0.6 in a private dependency prefix.

Local Rails integration execution is blocked: this sandbox refuses to create
even private PostgreSQL/Redis Unix sockets, including through its supported
escalation route. Docker is unavailable. RuboCop and the existing public PR CI
are being checked; no Rails integration pass is claimed at this stage.

Focused regression command:

```sh
bundle exec rspec spec/services/validate_ruridot_interaction_service_spec.rb \
  spec/services/post_status_service_ruridot_spec.rb \
  spec/requests/api/v1/ruridot_statuses_spec.rb \
  spec/services/post_status_service_spec.rb \
  spec/services/update_status_service_spec.rb \
  spec/services/process_mentions_service_spec.rb \
  spec/workers/publish_scheduled_status_worker_spec.rb
```

Tests use fabricated accounts/statuses and intercepted remote resolution. They
cover create, edit and schedule rejection through existing 422 handling, follower
direction, pending requests, current explicit versus silent invitations,
self-reply continuations and broken chains, quote routing, extra recipients,
resolver failures, rollback of media/polls/votes/mentions/history, preview reset,
normal independent media/poll posting and publication-time schedule revalidation.
