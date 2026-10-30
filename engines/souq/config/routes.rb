# frozen_string_literal: true

Souq::Engine.routes.draw do
  get '/api/v1/souq/health', to: 'api/v1/health#show'
end
