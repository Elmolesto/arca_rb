# Files are grouped by layer; every constant still lives directly under Arca
# (Arca::ReceiptType, Arca::Wsfe), so folders are not namespaces.
require_relative "arca/version"
require_relative "arca/errors"
require_relative "arca/support/serialization"

# Fiscal rules: identities, VAT, receipt types and the request WSFE receives.
require_relative "arca/fiscal/identity"
require_relative "arca/fiscal/vat_condition"
require_relative "arca/fiscal/vat_rate"
require_relative "arca/fiscal/receipt_type"
require_relative "arca/fiscal/service_period"
require_relative "arca/fiscal/request"
require_relative "arca/fiscal/pricing"

# Configuration: environment, certificate, ticket storage, issuer and point of sale.
require_relative "arca/configuration/environment"
require_relative "arca/configuration/ticket_store"
require_relative "arca/configuration/credentials"
require_relative "arca/configuration/issuer"
require_relative "arca/configuration/point_of_sale"

# ARCA web services: SOAP transport, WSAA, WSFE and the registry, and the
# clients built on them.
require_relative "arca/services/soap"
require_relative "arca/services/wsaa"
require_relative "arca/services/wsfe"
require_relative "arca/services/padron"
require_relative "arca/services/client"
require_relative "arca/services/padron_client"

# Printable receipts and their QR.
require_relative "arca/pdf/qr"
require_relative "arca/pdf"

# Issuing: drafts, issued receipts and the invoicer that ties everything together.
require_relative "arca/draft"
require_relative "arca/issued_receipt"
require_relative "arca/invoicer"
