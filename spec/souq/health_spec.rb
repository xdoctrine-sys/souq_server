# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'SOUQ health', type: :request do
  it 'returns the engine version without authentication' do
    get '/api/v1/souq/health'
    expect(response).to have_http_status(200)
    expect(response.parsed_body).to eq('ok' => true, 'version' => Souq::VERSION)
  end

  it 'registers engine migrations in the host application' do
    expect(Rails.application.config.paths['db/migrate'].expanded)
      .to include(Souq::Engine.root.join('db/migrate').to_s)
  end

  it 'keeps the empty extension idempotent' do
    callbacks = Status._create_callbacks.to_a
    2.times { Souq::StatusExtension.apply! }
    expect(Status._create_callbacks.to_a).to eq(callbacks)
  end
end
