# frozen_string_literal: true

# Builds in-memory SOUQ taxonomy documents for the T3 specs. Values are
# explicit: nothing is defaulted by the production code, so the specs state
# every field the format requires.
module SouqTaxonomyDocumentHelpers
  def taxonomy_document(markets:, categories:, taxonomy_version: 1, **overrides)
    {
      'format_version' => Souq::Taxonomy::Document::FORMAT_VERSION,
      'taxonomy_version' => taxonomy_version,
      'markets' => markets,
      'categories' => categories,
      'attributes' => [],
      'locations' => [],
    }.merge(overrides.transform_keys(&:to_s))
  end

  def taxonomy_category(code, parent_code: nil, position: 0, **overrides)
    {
      'code' => code,
      'parent_code' => parent_code,
      'name_en' => "Name #{code}",
      'name_ar' => "اسم #{code}",
      'description_en' => nil,
      'description_ar' => nil,
      'icon' => nil,
      'cover_url' => nil,
      'color' => nil,
      'hashtag' => nil,
      'hashtag_ar' => nil,
      'position' => position,
      'active' => true,
      'listable' => true,
    }.merge(overrides.transform_keys(&:to_s))
  end

  def taxonomy_market(code, categories: [], position: 0, **overrides)
    {
      'code' => code,
      'name_en' => "Name #{code}",
      'name_ar' => "اسم #{code}",
      'description_en' => nil,
      'description_ar' => nil,
      'icon' => nil,
      'cover_url' => nil,
      'color' => nil,
      'position' => position,
      'active' => true,
      'categories' => categories,
    }.merge(overrides.transform_keys(&:to_s))
  end

  # The three-level reference tree shared by most examples.
  def reference_document(**overrides)
    taxonomy_document(
      categories: [
        taxonomy_category('vehicles', position: 0),
        taxonomy_category('vehicles__cars', parent_code: 'vehicles', position: 0, hashtag: 'cars'),
        taxonomy_category('vehicles__cars__spare_parts', parent_code: 'vehicles__cars', position: 0),
        taxonomy_category('services', position: 1),
      ],
      markets: [taxonomy_market('motors', categories: ['vehicles'])],
      **overrides
    )
  end
end

RSpec.configure do |config|
  config.include SouqTaxonomyDocumentHelpers
end
