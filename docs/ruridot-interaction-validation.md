# Draft: local ruridot interaction validation

This draft is based on `stellarianetwork/mastodon` branch `ver4.7.3`, commit
`6c2e9ffbdac582920dae89f7f44d94c1b8cacda3`. It does not deploy anything or
change the operational pause on autonomous outgoing activity.

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

All authored implementation and test sources will be committed to the public
head branch before execution. No live Mastodon writes are used for testing.

### Verification status

Implementation has not yet been added. The current workspace has no Ruby,
Bundler, PostgreSQL, Redis or Docker runtime. The checkout's isolated Docker
verification procedure cannot run here as-is. An official dependency runtime is
being evaluated; no Rails integration test result is claimed at this stage.
