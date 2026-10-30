# frozen_string_literal: true

require_relative 'db_objects'
require_relative 'configuration'

module Souq
  class Engine < ::Rails::Engine
    isolate_namespace Souq

    initializer 'souq.configuration' do
      Souq.configuration
    end

    initializer 'souq.schema_loader' do
      ActiveRecord::Tasks::DatabaseTasks.prepend(Souq::DbObjects::SchemaLoader)
    end

    initializer 'souq.append_migrations' do |app|
      app.config.paths['db/migrate'].concat(config.paths['db/migrate'].expanded) unless app.root == root
    end

    initializer 'souq.mount_routes' do |app|
      app.routes.prepend do
        mount Souq::Engine => '/'
      end
    end
  end
end
