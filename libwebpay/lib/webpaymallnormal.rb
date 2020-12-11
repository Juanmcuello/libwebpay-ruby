require 'signer'
require 'savon'
require_relative "verifier"


class WebpayMallNormal

  def initialize(configuration)

    @wsdl_path = ''
    @ambient = configuration.environment

    case @ambient
      when 'INTEGRACION'
        @wsdl_path='https://webpay3gint.transbank.cl/WSWebpayTransaction/cxf/WSWebpayService?wsdl'
      when 'CERTIFICACION'
        @wsdl_path='https://webpay3gint.transbank.cl/WSWebpayTransaction/cxf/WSWebpayService?wsdl'
      when 'PRODUCCION'
        @wsdl_path='https://webpay3g.transbank.cl/WSWebpayTransaction/cxf/WSWebpayService?wsdl'
      else
        #Por defecto esta el ambiente de INTEGRACION
        @wsdl_path='https://webpay3gint.transbank.cl/WSWebpayTransaction/cxf/WSWebpayService?wsdl'
    end

    @commerce_code = configuration.commerce_code
    @private_key = OpenSSL::PKey::RSA.new(configuration.private_key)
    @public_cert = OpenSSL::X509::Certificate.new(configuration.public_cert)
    @webpay_cert = OpenSSL::X509::Certificate.new(configuration.webpay_cert)
    @store_codes = configuration.store_codes
    @client = Savon.client(wsdl: @wsdl_path)

  end

  #######################################################
  def initTransaction(buyOrder, sessionId, urlReturn, urlFinal, stores)

    detailArray = Array.new

    stores.each do |store|
      wsTransactionDetail = {
          "commerceCode" => store['storeCode'],
          "amount" => store['amount'],
          "buyOrder" => store['buyOrder']
      }
      detailArray.push(wsTransactionDetail)
    end


    inputComplete ={
        "wsInitTransactionInput" => {
            "wSTransactionType" => 'TR_MALL_WS',
            "commerceId" => @commerce_code,
            "sessionId" => sessionId,
            "buyOrder" => buyOrder,
            "returnURL" => urlReturn,
            "finalURL" => urlFinal,
            "transactionDetails" => detailArray
        }
    }

    req = @client.build_request(:init_transaction, message: inputComplete)

    #Firmar documento
    document = sign_xml(req)
    #document = Util.signXml(req)

    begin
      response = @client.call(:init_transaction) do
        xml document.to_xml(:save_with => 0)
      end
    rescue Exception, RuntimeError => e
      response_array ={
          "error_desc" => "Ocurrio un error en la llamada a Webpay: "+e.message
      }
      return response_array
    end

    token=''

    #Verificacion de certificado respuesta
    tbk_cert = OpenSSL::X509::Certificate.new(@webpay_cert)

    if !Verifier.verify(response, tbk_cert)
      response_array ={
          "error_desc" => 'El Certificado de respuesta es Invalido'
      }
      return response_array
    end


    response_document = Nokogiri::HTML(response.to_s)
    response_document.xpath("//token").each do |token_value|
      token = token_value.text
    end
    url=''
    response_document.xpath("//url").each do |url_value|
      url = url_value.text
    end

    response_array ={
        "token" => token.to_s,
        "url" => url.to_s,
        "error_desc"        => 'TRX_OK'
    }

    return response_array
  end



  ##############################################
  def getTransactionResult(token)

    getResultInput ={
        "tokenInput" => token
    }

    #Preparacion firma
    req = @client.build_request(:get_transaction_result, message: getResultInput)

    #firmar la peticion
    document = sign_xml(req)

    #Se realiza el getResult
    begin
      response = @client.call(:get_transaction_result) do
        xml document.to_xml(:save_with => 0)
      end

    rescue Exception, RuntimeError => e
      response_array ={
          "error_desc" => "Ocurrio un error en la llamada a Webpay: "+e.message
      }
      return response_array
    end

    #Se revisa que respuesta no sea nula.
    unless response
      response_array ={
          "error_desc" => 'Webservice Webpay responde con null'
      }
      return response_array
    end

    #Verificacion de certificado respuesta
    tbk_cert = OpenSSL::X509::Certificate.new(@webpay_cert)

    if !Verifier.verify(response, tbk_cert)
      response_array ={
          "error_desc" => 'Webservice Webpay responde con null'
      }
      return response_array
    end


    token_obtenido=''
    response = Nokogiri::HTML(response.to_s)


    accountingDate 		= response.xpath("//accountingdate").text
    buyOrder 					= response.xpath("//buyorder")[0].text
    cardNumber 				= response.xpath("//cardnumber").text

    #ciclo
    detailOutput     = response.xpath("//detailoutput")
                               .map { |detail| parseDetailOutput(detail) }

    sessionId 			= response.xpath("//sessionid").text
    transactionDate	= response.xpath("//transactiondate").text
    urlRedirection 	= response.xpath("//urlredirection").text
    vci 			      = response.xpath("//vci").text

    response_array ={
        "accountingDate" 	=> accountingDate.to_s,
        "buyOrder" 				=> buyOrder.to_s,
        "cardNumber" 			=> cardNumber.to_s,
        "detailOutput"    => detailOutput,
        "sessionId" 			=> sessionId.to_s,
        "transactionDate" => transactionDate.to_s,
        "urlRedirection" 	=> urlRedirection.to_s,
        "vci" 		        => vci.to_s,
        "error_desc"        => 'TRX_OK'
    }

    #Realizar el acknowledge
    acknoledge_result = acknowledgeTransaction(token)

    unless acknoledge_result['error_desc'] == 'TRX_OK'
      response_array['error_desc'] = acknoledge_result['error_desc']
    end

    return response_array
  end

  def parseDetailOutput(detailOutput)
    {
      "sharesnumber"      => detailOutput.xpath("sharesnumber").text,
      "amount"            => detailOutput.xpath("amount").text,
      "commercecode"      => detailOutput.xpath("commercecode").text,
      "buyorder"          => detailOutput.xpath("buyorder").text,
      "authorizationcode" => detailOutput.xpath("authorizationcode").text,
      "paymenttypecode"   => detailOutput.xpath("paymenttypecode").text,
      "responsecode"      => detailOutput.xpath("responsecode").text,
    }
  end

  ################################
  def acknowledgeTransaction(token)
    acknowledgeInput ={
        "tokenInput" => token
    }

    #Preparacion firma
    req = @client.build_request(:acknowledge_transaction, message: acknowledgeInput)

    #Se firma el body de la peticion
    document = sign_xml(req)

    #Se realiza el acknowledge_transaction
    begin
      response = @client.call(:acknowledge_transaction, message: acknowledgeInput) do
        xml document.to_xml(:save_with => 0)
      end

    rescue Exception, RuntimeError => e
      response_array ={
          "error_desc" => "Ocurrio un error en la llamada a Webpay: "+e.message
      }
      return response_array
    end

    #Se revisa que respuesta no sea nula.
    unless response
      response_array ={
          "error_desc" => 'Webservice Webpay responde con null'
      }
      return response_array
    end

    #Verificacion de certificado respuesta
    tbk_cert = OpenSSL::X509::Certificate.new(@webpay_cert)

    if !Verifier.verify(response, tbk_cert)
      response_array ={
          "error_desc" => 'El Certificado de respuesta es Invalido'
      }
      return response_array
    end

    response_array ={
        "error_desc" => 'TRX_OK'
    }
    return response_array

  end



  def sign_xml (input_xml)

    document = Nokogiri::XML(input_xml.body)
    envelope = document.at_xpath("//env:Envelope")
    envelope.prepend_child("<env:Header><wsse:Security xmlns:wsse='http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd' wsse:mustUnderstand='1'/></env:Header>")
    xml = document.to_s

    signer = Signer.new(xml)

    signer.cert = OpenSSL::X509::Certificate.new(@public_cert)
    signer.private_key = OpenSSL::PKey::RSA.new(@private_key)

    signer.document.xpath("//soapenv:Body", { "soapenv" => "http://schemas.xmlsoap.org/soap/envelope/" }).each do |node|
      signer.digest!(node)
    end

    signer.sign!(:issuer_serial => true)
    signed_xml = signer.to_xml

    document = Nokogiri::XML(signed_xml)
    x509data = document.at_xpath("//*[local-name()='X509Data']")
    new_data = x509data.clone()
    new_data.set_attribute("xmlns:ds", "http://www.w3.org/2000/09/xmldsig#")

    n = Nokogiri::XML::Node.new('wsse:SecurityTokenReference', document)
    n.add_child(new_data)
    x509data.add_next_sibling(n)

    return document
  end



end
