# frozen_string_literal: true

Souq::Engine.routes.draw do
  get '/api/v1/souq/health', to: 'api/v1/health#show'

  post '/api/v1/souq/listings', to: 'api/v1/listings#create'
  get '/api/v1/souq/listings/:id', to: 'api/v1/listings#show'
  put '/api/v1/souq/listings/:id', to: 'api/v1/listings#update'
  post '/api/v1/souq/listings/:id/state', to: 'api/v1/listings#state'
end
