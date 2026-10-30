# frozen_string_literal: true

class Souq::Api::V1::HealthController < ActionController::API
  def show
    render json: { ok: true, version: Souq::VERSION }
  end
end
