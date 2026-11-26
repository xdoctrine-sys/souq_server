# frozen_string_literal: true

require 'rails_helper'
require_relative '../support/taxonomy'
require_relative '../support/taxonomy_cache'
require_relative '../support/taxonomy_document'
require_relative '../support/attributes'
require_relative '../support/schema_reference'

# T3: the importer applies a validated taxonomy document to the database. The
# examples cover the contract the plan states: codes used as stable keys, a dry
# run that writes nothing, one atomic transaction, an idempotent second import
# and deactivation instead of deletion.
RSpec.describe Souq::Taxonomy::Importer do
  include SouqSchemaReference

  let!(:account) { Fabricate(:account) }

  def import(raw, dry_run: false)
    described_class.call(document: Souq::Taxonomy::Document.new(raw), account: account, dry_run: dry_run)
  end

  # Everything the import may touch: the tree, the markets, the curated links,
  # the taxonomy version and the audit trail.
  def snapshot
    [
      Souq::Category.order(:id).pluck(:id, :code, :parent_id, :ancestor_ids, :depth, :position, :active, :listable),
      Souq::Market.order(:id).pluck(:id, :code, :active),
      Souq::MarketCategory.order(:market_id, :position, :id).pluck(:market_id, :category_id, :position),
      read_taxonomy_version,
      Souq::AuditLog.count,
    ]
  end

  def expect_no_write
    before = snapshot
    yield
    expect(snapshot).to eq(before)
  end

  it 'creates the tree, the markets and the links from an empty database' do
    report = import(reference_document)

    expect(report).to be_changed
    expect(report.dry_run).to be(false)
    expect(report.categories.created).to contain_exactly('vehicles', 'vehicles__cars', 'vehicles__cars__spare_parts', 'services')
    expect(report.markets.created).to eq(['motors'])
    expect(report.links.added).to contain_exactly(%w(motors vehicles))

    vehicles = Souq::Category.find_by!(code: 'vehicles')
    cars = Souq::Category.find_by!(code: 'vehicles__cars')
    parts = Souq::Category.find_by!(code: 'vehicles__cars__spare_parts')
    expect(cars.parent).to eq(vehicles)
    expect(cars.ancestor_ids).to eq([vehicles.id])
    expect(parts.ancestor_ids).to eq([vehicles.id, cars.id])
    expect(parts.depth).to eq(2)
    expect(Souq::Market.find_by!(code: 'motors').categories).to contain_exactly(vehicles)
  end

  it 'is idempotent: the second import reports no difference and writes nothing' do
    import(reference_document)

    report = nil
    expect_no_write { report = import(reference_document) }

    expect(report).to_not be_changed
    expect(report.categories.unchanged).to contain_exactly('vehicles', 'vehicles__cars', 'vehicles__cars__spare_parts', 'services')
    expect(report.markets.unchanged).to eq(['motors'])
    expect(report.links.added).to be_empty
  end

  it 'detects a reordered market link and applies the new positions' do
    original = taxonomy_document(
      categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('services', position: 1)],
      markets: [taxonomy_market('motors', categories: %w(vehicles services))]
    )
    import(original)

    reordered = taxonomy_document(
      categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('services', position: 1)],
      markets: [taxonomy_market('motors', categories: %w(services vehicles))]
    )
    report = import(reordered)

    expect(report).to be_changed
    expect(report.links.reordered).to contain_exactly(%w(motors services), %w(motors vehicles))

    market = Souq::Market.find_by!(code: 'motors')
    ordered = Souq::MarketCategory.where(market: market).order(:position).map { |link| link.category.code }
    expect(ordered).to eq(%w(services vehicles))

    unchanged = taxonomy_document(
      categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('services', position: 1)],
      markets: [taxonomy_market('motors', categories: %w(services vehicles))]
    )
    again = import(unchanged)
    expect(again).to_not be_changed
  end

  it 'prints no difference without an empty version when an import changes nothing' do
    import(reference_document)
    report = import(reference_document)

    expect(report).to_not be_changed
    lines = report.to_text.lines.map(&:strip)
    expect(lines).to include('no difference')
    expect(lines).to_not include('taxonomy_version')
  end

  it 'computes the same report in a dry run and writes nothing' do
    dry = import(reference_document, dry_run: true)

    expect(dry).to be_changed
    expect(dry.dry_run).to be(true)
    expect(dry.taxonomy_version).to be_nil
    expect(snapshot).to eq([[], [], [], nil, 0])

    real = import(reference_document)
    expect(real.categories.created).to eq(dry.categories.created)
    expect(real.markets.created).to eq(dry.markets.created)
    expect(real.links.added).to eq(dry.links.added)
  end

  it 'deactivates an absent code and unlinks it instead of deleting the row' do
    import(reference_document)

    reduced = taxonomy_document(
      markets: [taxonomy_market('motors', categories: [])],
      categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('vehicles__cars', parent_code: 'vehicles', position: 0, hashtag: 'cars')]
    )
    report = import(reduced)

    expect(report.categories.deactivated).to contain_exactly('services', 'vehicles__cars__spare_parts')
    expect(report.links.removed).to contain_exactly(%w(motors vehicles))
    expect(Souq::Category.find_by(code: 'services')).to be_present
    expect(Souq::Category.find_by(code: 'services')).to_not be_active
    expect(Souq::Category.find_by(code: 'vehicles__cars__spare_parts')).to_not be_active
    expect(Souq::MarketCategory.count).to eq(0)
  end

  it 'reparents a category, rewriting parent, ancestors and depth together' do
    import(taxonomy_document(markets: [], categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('bikes', position: 1)]))
    bikes = Souq::Category.find_by!(code: 'bikes')
    expect(bikes.depth).to eq(0)

    nested = taxonomy_document(markets: [], categories: [taxonomy_category('vehicles', position: 0), taxonomy_category('bikes', parent_code: 'vehicles', position: 0)])
    report = import(nested)

    expect(report.categories.updated).to eq(['bikes'])
    expect(bikes.reload.parent).to eq(Souq::Category.find_by!(code: 'vehicles'))
    expect(bikes.ancestor_ids).to eq([Souq::Category.find_by!(code: 'vehicles').id])
    expect(bikes.depth).to eq(1)
  end

  it 'rewrites the ancestry of every descendant, including inactive ones, when an ancestor moves' do
    initial = taxonomy_document(
      markets: [],
      categories: [
        taxonomy_category('vehicles', position: 0),
        taxonomy_category('cars', parent_code: 'vehicles', position: 0),
        taxonomy_category('parts', parent_code: 'cars', position: 0),
        taxonomy_category('bodywork', parent_code: 'cars', position: 1),
        taxonomy_category('services', position: 1),
      ]
    )
    import(initial)

    services = Souq::Category.find_by!(code: 'services')
    vehicles = Souq::Category.find_by!(code: 'vehicles')

    # `bodywork` is left out of the new document: it must be deactivated, never
    # deleted, and — because its ancestor `vehicles` moved — its own ancestry
    # must follow. The deferred tree trigger checks every row at commit, so a
    # stale descendant would roll the whole import back.
    moved = taxonomy_document(
      markets: [],
      categories: [
        taxonomy_category('services', position: 0),
        taxonomy_category('vehicles', parent_code: 'services', position: 0),
        taxonomy_category('cars', parent_code: 'vehicles', position: 0),
        taxonomy_category('parts', parent_code: 'cars', position: 0),
      ]
    )
    report = import(moved)

    expect(report.categories.updated).to include('vehicles')
    expect(report.categories.deactivated).to eq(['bodywork'])

    cars = Souq::Category.find_by!(code: 'cars')
    parts = Souq::Category.find_by!(code: 'parts')
    bodywork = Souq::Category.find_by!(code: 'bodywork')

    expect(vehicles.reload).to have_attributes(ancestor_ids: [services.id], depth: 1)
    expect(cars).to have_attributes(ancestor_ids: [services.id, vehicles.id], depth: 2)
    expect(parts).to have_attributes(ancestor_ids: [services.id, vehicles.id, cars.id], depth: 3)
    expect(bodywork).to_not be_active
    expect(bodywork).to have_attributes(ancestor_ids: [services.id, vehicles.id, cars.id], depth: 3)
  end

  it 'moves an existing root under a parent created by the same import' do
    import(taxonomy_document(markets: [], categories: [taxonomy_category('vehicles', position: 1), taxonomy_category('bikes', position: 0)]))

    nested = taxonomy_document(
      markets: [],
      categories: [
        taxonomy_category('vehicles', position: 1),
        taxonomy_category('vehicles__two_wheels', parent_code: 'vehicles', position: 0),
        taxonomy_category('bikes', parent_code: 'vehicles__two_wheels', position: 0),
      ]
    )
    report = import(nested)

    expect(report.categories.created).to eq(['vehicles__two_wheels'])
    expect(report.categories.updated).to eq(['bikes'])
    expect(Souq::Category.find_by!(code: 'bikes').parent).to eq(Souq::Category.find_by!(code: 'vehicles__two_wheels'))
    expect(Souq::Category.find_by!(code: 'bikes').depth).to eq(2)
  end

  it 'increments the version once and records one import audit line' do
    report = import(reference_document)

    expect(report.taxonomy_version).to eq(2)
    expect(read_taxonomy_version).to eq(2)
    expect(Souq::AuditLog.where(action: 'import').count).to eq(1)

    log = Souq::AuditLog.find_by!(action: 'import')
    expect(log.account).to eq(account)
    expect(log.target_type).to eq('Souq::Setting')
    expect(log.recorded_changes['taxonomy_version']).to eq(2)
    expect(log.recorded_changes).to_not have_key('dry_run')
    expect(log.recorded_changes.dig('categories', 'created')).to include('vehicles')
  end

  it 'rolls every write back when a late step fails' do
    allow(Souq::AuditLog).to receive(:create!).and_raise('audit failure')

    expect { import(reference_document) }.to raise_error('audit failure')
    expect(snapshot).to eq([[], [], [], nil, 0])
  end

  it 'rolls a whole move back, descendants included, when a later step fails' do
    original = taxonomy_document(
      markets: [],
      categories: [
        taxonomy_category('vehicles', position: 0),
        taxonomy_category('cars', parent_code: 'vehicles', position: 0),
        taxonomy_category('bodywork', parent_code: 'cars', position: 1),
        taxonomy_category('services', position: 1),
      ]
    )
    import(original)
    before = snapshot

    allow(Souq::AuditLog).to receive(:create!).and_raise('audit failure')

    moved = taxonomy_document(
      markets: [],
      categories: [
        taxonomy_category('services', position: 0),
        taxonomy_category('vehicles', parent_code: 'services', position: 0),
        taxonomy_category('cars', parent_code: 'vehicles', position: 0),
      ]
    )
    expect { import(moved) }.to raise_error('audit failure')
    expect(snapshot).to eq(before)
  end

  it 'refuses to import a move that would orphan an inherited override' do
    vehicles = reference_category('vehicles', 'Vehicles', 'مركبات')
    cars = reference_category('cars', 'Cars', 'سيارات', parent: vehicles)
    definition = reference_definition('import_override_attr', 0, 'single_option')
    reference_option(definition, 'aa')
    reference_rule(vehicles, definition, mode: :enable)
    reference_rule(cars, definition, mode: :override, config: { 'allowed_option_codes' => ['aa'] })

    before = snapshot
    # `cars` leaves `vehicles`, so its `override` no longer inherits the
    # attribute: exactly the orphaned `override` the design calls an error
    # (section 3.4). The import must abort instead of leaving `/schema` to
    # answer 503 on every later request.
    moved = taxonomy_document(markets: [], categories: [taxonomy_category('cars', position: 0)])

    expect { import(moved) }
      .to raise_error(Souq::Schema::RuleError) do |error|
        expect(error.issues.map(&:code)).to include('override_without_inherited')
      end
    expect(snapshot).to eq(before)
  end

  it 'refuses an account that is not persisted' do
    expect { described_class.call(document: Souq::Taxonomy::Document.new(reference_document), account: nil) }
      .to raise_error(Souq::Taxonomy::ValidationError)
  end
end
