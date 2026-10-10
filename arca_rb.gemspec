require_relative "lib/arca/version"

Gem::Specification.new do |spec|
  spec.name = "arca_rb"
  spec.version = Arca::VERSION
  spec.authors = [ "Felipe Hernandez" ]
  spec.email = [ "hernandezfeli@gmail.com" ]

  spec.summary = "Electronic invoicing (WSFE), taxpayer registry (padrón) and receipt PDFs for ARCA, without Rails"
  spec.description = "Facturación electrónica de ARCA (ex AFIP) para Ruby: WSAA, WSFEv1, padrón A5 y PDF con QR, con reglas fiscales y emisión a prueba de reintentos."
  spec.homepage = "https://github.com/Elmolesto/arca_rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}#documentaci%C3%B3n"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.{rb,ttf,txt}", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "base64"
  spec.add_dependency "bigdecimal"
  spec.add_dependency "nokogiri", ">= 1.16"
  spec.add_dependency "prawn", "~> 2.5"
  spec.add_dependency "rqrcode", "~> 3.1"
end
