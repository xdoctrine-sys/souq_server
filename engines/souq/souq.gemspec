# frozen_string_literal: true

require_relative 'lib/souq/version'

Gem::Specification.new do |spec|
  spec.name = 'souq'
  spec.version = Souq::VERSION
  spec.authors = ['SOUQ']
  spec.summary = 'Isolated SOUQ engine for Mastodon'
  spec.license = 'AGPL-3.0-or-later'
  spec.required_ruby_version = '>= 3.3'
  spec.files = Dir['{app,config,db,lib}/**/*', 'UPSTREAM_TOUCHPOINTS.md', 'bin/*']
  spec.add_dependency 'rails', '~> 8.1'
  spec.metadata['rubygems_mfa_required'] = 'true'
end
