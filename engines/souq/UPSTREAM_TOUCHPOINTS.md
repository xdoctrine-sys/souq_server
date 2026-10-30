# SOUQ upstream touchpoints

Reference: SOUQ_CATEGORIES_DESIGN.md, revision 2.2, section 9.
Base: v4.7.4, d04059fc80be5cbba6b4dd5a8b94d63ffff09f2c.

## Closed Allowlist

The checker reads the exact paths in this block. No additional exceptions.

```text
Gemfile
Gemfile.lock
config/initializers/souq.rb
db/schema.rb
config/routes.rb
config/navigation.rb
.gitignore
Dockerfile
streaming/Dockerfile
.github/workflows/souq.yml
```

- `engines/souq/**` and `spec/souq/**` contain new SOUQ code and tests.
- Gemfile and lockfile register the local engine.
- The new initializer invokes the reload-safe extension entry point.
- The schema is generated only, never manually edited.
- Routes: at most one optional mount line; unused in T0 (engine mounts itself).
- Navigation: at most one optional menu line, subject to product approval; unused in T0.
- The last three entries cover existing Railway commits, not permission to change deployment in T0.

Run `engines/souq/bin/souq-check-touchpoints` from any directory in the repository.
It checks commits, the index, unstaged changes and non-ignored untracked paths.
Renames are treated as deletion plus addition. Exit 1 lists forbidden paths;
exit 2 means an invalid base or a Git/configuration failure. CI must fetch the tag.
The path check does not verify line-level restrictions; review the diff as well.

Proof support is explicitly required from `spec/souq/support/`, never loaded
globally from Mastodon's `spec/support/`.

Upstream upgrades require updating both pinned base constants and rerunning
SOUQ contract tests for transactions, serializers, caching, distribution and feeds.
