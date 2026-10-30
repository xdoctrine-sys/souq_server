# frozen_string_literal: true

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
end

RSpec.configure do |config|
  config.include SouqTaxonomyCacheHelpers
end
