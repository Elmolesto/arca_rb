module Arca
  module Environment
    ALL = %i[homologation production].freeze

    def self.fetch(value)
      environment = value.to_s.to_sym
      return environment if ALL.include?(environment)

      raise ConfigurationError, "El entorno ARCA configurado no es válido"
    end
  end
end
