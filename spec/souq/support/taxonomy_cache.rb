# frozen_string_literal: true

require 'delegate'

# Wraps a Redis client and reports every GET of one key while a spec runs.
# Forwarding everything else to the real client keeps the wrapper transparent.
class SouqTaxonomyReadCounter < SimpleDelegator
  def initialize(client, key, on_read:)
    super(client)
    @key = key
    @on_read = on_read
  end

  def get(key, ...)
    @on_read.call if key == @key
    __getobj__.get(key, ...)
  end
end

# Helpers for the SOUQ taxonomy cache specs. Required explicitly by the specs
# that need them, never loaded globally from Mastodon's spec/support.
module SouqTaxonomyCacheHelpers
  def read_taxonomy_version
    redis.get(Souq::TaxonomyCache::REDIS_KEY)
  end

  def write_taxonomy_version(value)
    redis.set(Souq::TaxonomyCache::REDIS_KEY, value)
  end

  def clear_taxonomy_version
    redis.del(Souq::TaxonomyCache::REDIS_KEY)
  end

  # Forces a tree load so that later measurements do not include the cache
  # warm-up queries.
  def warm_taxonomy_cache
    Souq::TaxonomyCache.category('__souq_taxonomy_warmup__')
  end

  # Counts every GET of the taxonomy version key while the block runs. Only
  # that key is counted, whatever else the wrapped client does.
  def count_taxonomy_version_reads
    reads = 0
    on_read = -> { reads += 1 }
    allow(RedisConnection).to receive(:with).and_wrap_original do |original, *args, &block|
      original.call(*args) do |client|
        block.call(SouqTaxonomyReadCounter.new(client, Souq::TaxonomyCache::REDIS_KEY, on_read: on_read))
      end
    end
    yield
    reads
  end
end

RSpec.configure do |config|
  config.include SouqTaxonomyCacheHelpers
  # Rails clears CurrentAttributes between requests and jobs but not between
  # examples, so reset it to keep the examples independent.
  config.before do
    Souq::Current.reset
  end
end
