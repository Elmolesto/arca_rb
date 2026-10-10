require_relative "pdf/format"
require_relative "pdf/document"
require_relative "pdf/renderer"

module Arca
  # Printable receipts. Returns the PDF as a binary String.
  #
  #   Arca::Pdf.render(document, copies: %i[original duplicate], logo: "logo.png")
  module Pdf
    def self.render(document, **options) = Renderer.new(document, **options).render
  end
end
