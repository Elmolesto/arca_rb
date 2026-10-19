require "prawn"

module Arca
  module Pdf
    # Lays out a Document on A4 following ARCA's printed receipt model: copy
    # banner, issuer and receipt boxes, receiver, items, totals and the
    # CAE/QR footer. Coordinates are PDF points from the bottom-left corner.
    class Renderer
      FONT = "Noto Sans".freeze
      DEFAULT_FONTS = {
        normal: File.expand_path("fonts/NotoSans-Regular.ttf", __dir__),
        bold: File.expand_path("fonts/NotoSans-Bold.ttf", __dir__),
        italic: File.expand_path("fonts/NotoSans-Italic.ttf", __dir__)
      }.freeze
      COPIES = { original: "ORIGINAL", duplicate: "DUPLICADO", triplicate: "TRIPLICADO", quadruplicate: "CUADRUPLICADO" }.freeze

      CONTENT_LEFT = 28
      CONTENT_WIDTH = 539
      CONTENT_RIGHT = CONTENT_LEFT + CONTENT_WIDTH
      HEADER_TOP = 814
      ITEM_HEADER_TOP = 528
      CONTINUATION_ITEM_HEADER_TOP = 790
      ITEM_HEADER_HEIGHT = 22
      # The first row starts 18 points below the items header.
      ITEM_BODY_TOP = 508
      # The last item must end above the totals; earlier ones may use the page
      # down to the page number.
      ITEM_BODY_BOTTOM = 330
      PAGE_BODY_BOTTOM = 60
      TOTALS_TOP = 315
      TOTALS_HEIGHT = 112

      # `proforma: { title: "ORDEN DE COMPRA", number: 1234 }` prints a draft
      # as a commercial document of the app's own (a quote, a purchase order)
      # instead of as a receipt draft: letter X, the app's number and no point
      # of sale.
      def initialize(document, copies: [ :original ], logo: nil, fonts: DEFAULT_FONTS, proforma: nil)
        @document = document
        @copies = document.draft? ? [ nil ] : Array(copies).map { |copy| COPIES.fetch(copy) { raise ArgumentError, "Copia no soportada: #{copy}" } }
        raise ArgumentError, "Se necesita al menos una copia" if @copies.empty?
        raise ArgumentError, "Un comprobante autorizado no puede imprimirse como proforma" if proforma && document.authorized?

        @proforma = proforma && { title: proforma.fetch(:title).to_s.upcase, number: proforma[:number]&.to_s }

        @logo = logo
        @fonts = fonts
      end

      def render
        Prawn::Document.new(page_size: "A4", margin: 0, info: { Title: title, Creator: "arca_rb" }) do |pdf|
          pdf.font_families.update(FONT => @fonts.transform_values(&:to_s))
          pdf.font(FONT)
          @copies.each_with_index do |copy, index|
            pdf.start_new_page unless index.zero?
            render_copy(pdf, copy)
          end
        end.render
      end

      private

      attr_reader :document

      def title
        return document_title.capitalize if @proforma
        return "Borrador de #{document.receipt_type.document_title.downcase}" if document.draft?

        "#{document.receipt_type.document_title.capitalize} #{document.letter} #{Format.point_of_sale(document.point_of_sale)}-#{Format.receipt_number(document.receipt_number)}"
      end

      def render_copy(pdf, copy)
        first_page = pdf.page_number
        draw_banner(pdf, copy)
        draw_header(pdf)
        draw_service_period(pdf) if document.service_period
        draw_receiver(pdf)
        draw_associated_receipts(pdf) if document.associated_receipts.any?
        draw_items_header(pdf, top: ITEM_HEADER_TOP)
        remaining = draw_items(pdf, document.items, top: ITEM_BODY_TOP)

        until remaining.empty?
          pdf.start_new_page
          text(pdf, "#{title} · #{copy || "BORRADOR"} · continuación", at: [ CONTENT_LEFT, 815 ], width: CONTENT_WIDTH, height: 15, size: 11, style: :bold)
          draw_items_header(pdf, top: CONTINUATION_ITEM_HEADER_TOP)
          remaining = draw_items(pdf, remaining, top: CONTINUATION_ITEM_HEADER_TOP - ITEM_HEADER_HEIGHT - 2)
        end

        draw_observations(pdf) if document.observations
        draw_totals(pdf)
        document.authorized? ? draw_fiscal_footer(pdf, first_page:) : draw_draft_footer(pdf)
        number_pages(pdf, first_page..pdf.page_number, skip_last: document.authorized?)
      end

      def draw_banner(pdf, copy)
        banner = copy || "#{@proforma ? document_title : "BORRADOR DE #{document_title}"} · SIN VALIDEZ FISCAL"
        box(pdf, CONTENT_LEFT, HEADER_TOP, CONTENT_WIDTH, 28)
        text(pdf, banner, at: [ CONTENT_LEFT, 811 ], width: CONTENT_WIDTH, height: 18, size: 14, style: :bold, align: :center, valign: :center)
      end

      def draw_header(pdf)
        box(pdf, CONTENT_LEFT, 784, CONTENT_WIDTH, 112)
        pdf.stroke_vertical_line 709, 673, at: CONTENT_LEFT + 269
        draw_issuer(pdf)
        draw_letter_badge(pdf)
        draw_receipt_details(pdf)
      end

      def draw_issuer(pdf)
        issuer = document.issuer
        if @logo
          pdf.bounding_box([ 35, 780 ], width: 238, height: 32) { pdf.image @logo, fit: [ 238, 32 ], position: :center, vposition: :center }
        else
          text(pdf, issuer.legal_name.to_s.upcase, at: [ 35, 768 ], width: 238, height: 14, size: 11, style: :bold, align: :center)
        end
        label_value(pdf, "Razón Social:", issuer.legal_name, y: 744, label_x: 35, value_x: 120, width: 160, size: 8.5)
        label_value(pdf, "Domicilio Comercial:", document.commercial_address, y: 724, label_x: 35, value_x: 120, width: 167, height: 22, size: 8.5) if document.commercial_address
        label_value(pdf, "Condición frente al IVA:", VatCondition.label(issuer.vat_condition), y: 692, label_x: 35, value_x: 120, width: 160, size: 8.5, value_style: :bold)
      end

      def draw_letter_badge(pdf)
        x = CONTENT_LEFT + 246
        pdf.fill_color "FFFFFF"
        pdf.fill_rectangle [ x, 784 ], 48, 62
        pdf.fill_color "000000"
        box(pdf, x, 784, 48, 62, line_width: 0.5)
        text(pdf, @proforma ? "X" : document.letter, at: [ x, 780 ], width: 48, height: 38, size: 32, style: :bold, align: :center, valign: :center)
        text(pdf, @proforma ? "NO FISCAL" : "COD. #{document.receipt_type.code.to_s.rjust(3, "0")}", at: [ x, 732 ], width: 48, height: 9, size: 6, align: :center)
      end

      def draw_receipt_details(pdf)
        x = CONTENT_LEFT + 313
        text(pdf, document_title, at: [ x, 774 ], width: 240, height: 24, size: 18, style: :bold)
        if @proforma
          label_value(pdf, "Nro.:", @proforma[:number], y: 750, label_x: x, value_x: x + 30, width: 200, value_style: :bold) if @proforma[:number]
        else
          label_value(pdf, "Punto de Venta:", document.authorized? ? Format.point_of_sale(document.point_of_sale) : "00000", y: 750, label_x: x, value_x: 405, width: 42, value_style: :bold)
          label_value(pdf, "Comp. Nro.:", document.authorized? ? Format.receipt_number(document.receipt_number) : "BORRADOR", y: 750, label_x: 453, value_x: 510, width: 47, value_style: :bold)
        end
        label_value(pdf, "Fecha de Emisión:", Format.date(document.issued_on), y: 732, label_x: x, value_x: 438, width: 107, value_style: :bold)
        label_value(pdf, "CUIT:", Format.cuit(document.issuer.cuit), y: 712, label_x: x, value_x: 385, width: 160)
        label_value(pdf, "Ingresos Brutos:", document.issuer.gross_income, y: 698, label_x: x, value_x: 420, width: 125) if document.issuer.gross_income
        if document.issuer.activity_started_on
          label_value(pdf, "Fecha de Inicio de Actividades:", Format.date(document.issuer.activity_started_on), y: 684, label_x: x, value_x: 470, width: 75)
        end
      end

      def draw_service_period(pdf)
        period = document.service_period
        box(pdf, CONTENT_LEFT, 666, CONTENT_WIDTH, 24, line_width: 0.6)
        label_value(pdf, "Período Facturado Desde:", Format.date(period.from), y: 655, label_x: 35, value_x: 166, width: 70)
        label_value(pdf, "Hasta:", Format.date(period.to), y: 655, label_x: 240, value_x: 276, width: 70)
        label_value(pdf, "Fecha de Vto. para el pago:", Format.date(period.payment_due), y: 655, label_x: 370, value_x: 485, width: 75)
      end

      def draw_receiver(pdf)
        receiver = document.receiver
        box(pdf, CONTENT_LEFT, 636, CONTENT_WIDTH, 62, line_width: 0.6)
        unless receiver.unidentified?
          label_value(pdf, receiver.document_type == :cuit ? "CUIT:" : "Documento:", receiver.document_type == :dni ? receiver.document_number : Format.cuit(receiver.document_number),
            y: 624, label_x: 35, value_x: 135, width: 120)
        end
        text(pdf, "Apellido y Nombre / Razón Social:", at: [ 290, 624 ], width: 260, height: 11, size: 9, style: :bold)
        text(pdf, receiver.legal_name || (receiver.unidentified? ? "CONSUMIDOR FINAL" : ""), at: [ 290, 612 ], width: 270, height: 11, size: 9)
        label_value(pdf, "Condición frente al IVA:", VatCondition.label(receiver.vat_condition), y: 608, label_x: 35, value_x: 135, width: 145)
        text(pdf, "Domicilio:", at: [ 290, 596 ], width: 260, height: 11, size: 9, style: :bold)
        text(pdf, receiver.fiscal_address.to_s, at: [ 290, 584 ], width: 270, height: 11, size: 9)
        label_value(pdf, "Condición de venta:", document.payment_condition, y: 590, label_x: 35, value_x: 135, width: 145)
      end

      def draw_associated_receipts(pdf)
        references = document.associated_receipts.map do |receipt|
          definition = ReceiptType.fetch(receipt.receipt_type)
          "#{definition.document_title.capitalize} #{definition.letter} #{Format.point_of_sale(receipt.point_of_sale)}-#{Format.receipt_number(receipt.receipt_number)}"
        end
        label_value(pdf, "Comprobantes asociados:", references.join(", "), y: 566, label_x: 35, value_x: 155, width: 405)
      end

      def draw_items_header(pdf, top:)
        widths = columns.map { |column| column[1] }
        positions = column_positions(widths)
        pdf.fill_color "C8C8C8"
        pdf.fill_rectangle [ CONTENT_LEFT, top ], CONTENT_WIDTH, ITEM_HEADER_HEIGHT
        pdf.fill_color "000000"
        box(pdf, CONTENT_LEFT, top, CONTENT_WIDTH, ITEM_HEADER_HEIGHT, line_width: 0.4)
        positions[1...-1].each { |x| pdf.stroke_vertical_line top - ITEM_HEADER_HEIGHT, top, at: x }

        columns.each_with_index do |(header, _, align), index|
          text(pdf, header, at: [ positions[index] + 3, top - 6 ], width: widths[index] - 6, height: 10, size: 7.5, style: :bold, align:)
        end
      end

      # Draws as many items as fit on the page and returns the rest.
      def draw_items(pdf, items, top:)
        y = top
        widths = columns.map { |column| column[1] }
        positions = column_positions(widths)

        items.each_with_index do |item, index|
          bottom = index == items.length - 1 ? ITEM_BODY_BOTTOM : PAGE_BODY_BOTTOM
          row_height = [ 24, pdf.height_of(item.description, width: widths[1] - 6, size: 8.5) + 8 ].max
          # The first row of a page is always drawn, clamped if it is taller
          # than the page, so pagination always makes progress.
          return items.drop(index) unless y - row_height >= bottom || y == top

          height = [ row_height, y - bottom ].min
          cells(item).each_with_index do |value, cell|
            text(pdf, value, at: [ positions[cell] + 3, y - 4 ], width: widths[cell] - 6, height: height - 4, size: 8.5, align: columns[cell][2], valign: :top)
          end
          pdf.stroke_horizontal_line CONTENT_LEFT, CONTENT_RIGHT, at: y - height unless document.letter == "C"
          y -= height
        end
        []
      end

      # [header, width, alignment] per letter, as ARCA prints them.
      def columns
        @columns ||= case document.letter
        when "A"
          [ [ "Cantidad", 45, :right ], [ "Producto / Servicio", 145, :left ], [ "U. Medida", 50, :center ], [ "Precio Unit.", 70, :right ],
            [ "% Bonif.", 36, :center ], [ "Imp. Bonif.", 62, :right ], [ "% IVA", 36, :center ], [ "Subtotal s/IVA", 95, :right ] ]
        when "B"
          [ [ "Cantidad", 45, :right ], [ "Producto / Servicio", 171, :left ], [ "U. Medida", 50, :center ], [ "Precio Unit.", 75, :right ],
            [ "% Bonif.", 36, :center ], [ "Imp. Bonif.", 70, :right ], [ "Subtotal", 92, :right ] ]
        else
          [ [ "Código", 38, :left ], [ "Producto / Servicio", 134, :left ], [ "Cantidad", 60, :center ], [ "U. Medida", 50, :center ],
            [ "Precio Unit.", 78, :right ], [ "% Bonif.", 32, :center ], [ "Imp. Bonif.", 70, :right ], [ "Subtotal", 77, :right ] ]
        end
      end

      def cells(item)
        money = ->(amount) { Format.money(amount, symbol: document.currency_symbol) }
        case document.letter
        when "A"
          [ Format.number(item.quantity), item.description, item.unit, money.(item.unit_price), Format.percentage(item.discount_percent),
            money.(item.discount_amount), Format.percentage(item.vat_rate || document.vat_lines.first&.rate || VatRate::DEFAULT), money.(item.subtotal) ]
        when "B"
          [ Format.number(item.quantity), item.description, item.unit, money.(item.unit_price), Format.percentage(item.discount_percent),
            money.(item.discount_amount), money.(item.subtotal) ]
        else
          [ item.code.to_s, item.description, Format.number(item.quantity), item.unit, money.(item.unit_price), Format.percentage(item.discount_percent),
            money.(item.discount_amount), money.(item.subtotal) ]
        end
      end

      def draw_observations(pdf)
        text(pdf, "Observaciones:", at: [ 35, TOTALS_TOP - 28 ], width: 300, height: 11, size: 8.5, style: :bold)
        text(pdf, document.observations.to_s, at: [ 35, TOTALS_TOP - 41 ], width: 300, height: 58, size: 8, valign: :top)
      end

      def draw_totals(pdf)
        return draw_invoice_c_totals(pdf) if document.authorized? && document.letter == "C"

        rows = document.authorized? ? total_rows : []
        rows.each_with_index do |(label, value), index|
          y = 270 - (index * 14)
          text(pdf, label, at: [ 350, y ], width: 145, height: 12, size: 8, align: :right)
          text(pdf, value, at: [ 504, y ], width: 60, height: 12, size: 8, align: :right)
        end

        total_top = 270 - (rows.length * 14) + 2
        box(pdf, 350, total_top, 214, 24, line_width: 0.6)
        text(pdf, "Importe Total:", at: [ 357, total_top - 7 ], width: 105, height: 13, size: 10.5, style: :bold, align: :right)
        text(pdf, money(document.total_amount), at: [ 470, total_top - 7 ], width: 86, height: 13, size: 10.5, style: :bold, align: :right)
        text(pdf, "Son #{document.currency_name} #{Format.amount_in_words(document.total_amount)}", at: [ 164, 155 ], width: 400, height: 18, size: 7.5, align: :right)
        draw_transparency_regime(pdf, total_top - 48) if document.letter == "B" && document.receiver.final_consumer?
      end

      def draw_invoice_c_totals(pdf)
        box(pdf, CONTENT_LEFT, TOTALS_TOP, CONTENT_WIDTH, TOTALS_HEIGHT, line_width: 1)
        [
          [ "Subtotal:", money(document.total_amount - document.other_taxes_amount) ],
          [ "Importe Otros Tributos:", money(document.other_taxes_amount) ],
          [ "Importe Total:", money(document.total_amount) ]
        ].each_with_index do |(label, value), index|
          y = 266 - (index * 20)
          text(pdf, label, at: [ 355, y ], width: 125, height: 13, size: 9.5, style: :bold, align: :right)
          text(pdf, value, at: [ 488, y ], width: 68, height: 13, size: 9.5, style: :bold, align: :right)
        end
        text(pdf, "Son #{document.currency_name} #{Format.amount_in_words(document.total_amount)}", at: [ 164, 178 ], width: 392, height: 18, size: 8.5, align: :right)
      end

      def total_rows
        rows = case document.letter
        when "A"
          [ [ "Importe Neto Gravado:", money(document.net_amount) ] ] +
            VatRate::IDS.keys.reject(&:zero?).sort.reverse.filter_map do |rate|
              amount = vat_for(rate)
              [ "IVA #{Format.percentage(rate)}:", money(amount) ] unless amount.zero?
            end
        else
          [ [ "Subtotal:", money(document.total_amount - document.other_taxes_amount) ] ]
        end
        rows << [ "Importe Exento:", money(document.exempt_amount) ] unless document.exempt_amount.zero?
        rows << [ "Importe No Gravado:", money(document.untaxed_amount) ] unless document.untaxed_amount.zero?
        rows << [ "Importe Otros Tributos:", money(document.other_taxes_amount) ] unless document.other_taxes_amount.zero?
        rows
      end

      # Ley 27.743 (Régimen de Transparencia Fiscal al Consumidor): B receipts
      # to final consumers disclose the VAT they contain.
      def draw_transparency_regime(pdf, y)
        box(pdf, CONTENT_LEFT, y, CONTENT_WIDTH, 30, line_width: 0.4)
        text(pdf, "Régimen de Transparencia Fiscal al Consumidor (Ley 27.743)", at: [ 35, y - 4 ], width: 400, height: 10, size: 7.5, style: :bold)
        label_value(pdf, "IVA Contenido:", money(document.vat_amount), y: y - 17, label_x: 35, value_x: 110, width: 90, size: 7.5, height: 10)
        label_value(pdf, "Otros Impuestos Nacionales Indirectos:", money(0), y: y - 17, label_x: 230, value_x: 395, width: 90, size: 7.5, height: 10)
      end

      def draw_fiscal_footer(pdf, first_page:)
        total = pdf.page_number - first_page + 1
        pdf.image document.qr.png, at: [ 35, 126 ], width: 65, height: 65
        text(pdf, "ARCA", at: [ 112, 134 ], width: 112, height: 22, size: 17, style: :bold, color: "444444")
        text(pdf, "AGENCIA DE RECAUDACIÓN\nY CONTROL ADUANERO", at: [ 112, 112 ], width: 112, height: 12, size: 4, color: "444444")
        text(pdf, "Comprobante Autorizado", at: [ 112, 80 ], width: 180, height: 10, size: 9, style: :italic)
        text(pdf, "Esta Administración Federal no se responsabiliza por los datos ingresados en el detalle de la operación.", at: [ 112, 66 ], width: 300, height: 8, size: 6, style: :italic)
        text(pdf, "Pág. #{total}/#{total}", at: [ 302, 92 ], width: 70, height: 11, size: 9, style: :bold, align: :center)
        label_value(pdf, "CAE N°:", document.cae, y: 102, label_x: 414, value_x: 465, width: 91, size: 10, height: 12)
        label_value(pdf, "Fecha de Vto. de CAE:", Format.date(document.cae_expires_on), y: 84, label_x: 382, value_x: 486, width: 70, size: 10, height: 12)
      end

      def draw_draft_footer(pdf)
        text(pdf, "Previsualización · Sin validez fiscal · No contiene CAE ni código QR de ARCA.", at: [ 200, 52 ], width: 364, height: 12, size: 7.5, align: :right)
      end

      def number_pages(pdf, pages, skip_last: false)
        total = pages.count
        pages.each_with_index do |page, index|
          pdf.go_to_page(page)
          pdf.stroke_horizontal_line CONTENT_LEFT, CONTENT_RIGHT, at: 25
          next if skip_last && index == total - 1

          text(pdf, "Pág. #{index + 1}/#{total}", at: [ 470, 40 ], width: 94, height: 11, size: 9, style: :bold, align: :right)
        end
      end

      def document_title = @proforma ? @proforma.fetch(:title) : document.receipt_type.document_title
      def vat_for(rate) = document.vat_lines.select { |line| line.rate == rate }.sum(BigDecimal("0"), &:amount)
      def money(amount) = Format.money(amount, symbol: document.currency_symbol)
      def column_positions(widths) = widths.reduce([ CONTENT_LEFT ]) { |positions, width| positions << positions.last + width }

      def box(pdf, x, top, width, height, line_width: 0.4)
        pdf.line_width = line_width
        pdf.stroke_rectangle [ x, top ], width, height
      end

      def label_value(pdf, label, value, y:, label_x:, value_x:, width:, size: 9, height: 11, value_style: :normal)
        text(pdf, label, at: [ label_x, y ], width: value_x - label_x - 3, height:, size:, style: :bold)
        text(pdf, value.to_s, at: [ value_x, y ], width:, height:, size:, style: value_style)
      end

      def text(pdf, value, at:, width:, height:, size:, color: nil, **options)
        pdf.fill_color(color) if color
        pdf.text_box(value.to_s, at:, width:, height:, size:, overflow: :shrink_to_fit, **options)
        pdf.fill_color("000000") if color
      end
    end
  end
end
