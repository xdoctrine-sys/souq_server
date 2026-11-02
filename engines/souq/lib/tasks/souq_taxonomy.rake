# frozen_string_literal: true

namespace :souq do
  namespace :taxonomy do
    desc 'Import a SOUQ taxonomy document. Usage: rake "souq:taxonomy:import[path]" DRY_RUN=1 ACCOUNT=<username or id>'
    task :import, [:path] => :environment do |_task, args|
      path = args[:path].presence || Souq::Engine.root.join('db', 'taxonomy', 'qa.json').to_s
      reference = ENV['ACCOUNT'].to_s
      abort '[souq:taxonomy:import] set ACCOUNT=<username or id> to name the import actor' if reference.empty?

      account = reference.match?(/\A\d+\z/) ? Account.find_by(id: reference) : Account.local.find_by(username: reference)
      abort "[souq:taxonomy:import] no account matches ACCOUNT=#{reference}" if account.nil?

      document = Souq::Taxonomy::Document.load(path)
      report = Souq::Taxonomy::Importer.call(document: document, account: account, dry_run: ENV['DRY_RUN'] == '1')
      puts "[souq:taxonomy:import] #{path}"
      puts report.to_text
    rescue Souq::Taxonomy::InvalidDocumentError => e
      abort "[souq:taxonomy:import] #{path} is invalid:\n#{e.details.map { |key, problems| "  #{key}: #{problems.join('; ')}" }.join("\n")}"
    rescue Souq::Taxonomy::UnsupportedSectionError, Souq::Taxonomy::ValidationError => e
      abort "[souq:taxonomy:import] #{e.message}"
    end

    desc 'Export the SOUQ taxonomy. Usage: rake "souq:taxonomy:export[path]"'
    task :export, [:path] => :environment do |_task, args|
      document = Souq::Taxonomy::Exporter.call
      path = args[:path].presence
      if path
        File.write(path, "#{JSON.pretty_generate(document)}\n")
        puts "[souq:taxonomy:export] wrote #{path} (#{document['categories'].size} categories, #{document['markets'].size} markets)"
      else
        puts JSON.pretty_generate(document)
      end
    end
  end
end
