# frozen_string_literal: true

# Helpers for the SOUQ taxonomy cache specs. Required explicitly by the specs
# that need them, never loaded globally from Mastodon's spec/support.
module SouqTaxonomyCacheHelpers
  def read_taxonomy_version
    Souq::Setting.where(id: 1).pick(:taxonomy_version)
  end

  def write_taxonomy_version(value)
    setting = Souq::Setting.find_or_initialize_by(id: 1)
    setting.update!(taxonomy_version: value)
  end

  def clear_taxonomy_version
    Souq::Setting.where(id: 1).delete_all
  end

  # Forces a tree load so that later measurements do not include the cache
  # warm-up queries.
  def warm_taxonomy_cache
    Souq::TaxonomyCache.category('__souq_taxonomy_warmup__')
  end

  # Compte les SELECT reels de version, pas les hits du query cache Rails.
  def count_taxonomy_version_reads(&block)
    reads = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      reads += 1 if !payload[:cached] && payload[:sql].match?(/\ASELECT\b.*\bFROM\s+"?souq_settings"?/i)
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
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
