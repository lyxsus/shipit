assert = require 'assert'
should = require('chai').should()
expect = require('chai').expect
bond = require 'bondjs'
{UpsClient} = require '../lib/ups'
{ShipperClient} = require '../lib/shipper'
{Builder, Parser} = require 'xml2js'

describe "ups client", ->
  _upsClient = null
  _xmlParser = new Parser()
  _xmlHeader = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'

  before ->
    _upsClient = new UpsClient
      licenseNumber: '12345'
      userId: 'shipit'
      password: 'password'

  describe "generateRequest", ->
    _xmlDocs = null

    before ->
      trackXml = _upsClient.generateRequest('1Z5678', 'eloquent shipit')
      _xmlDocs = trackXml.split _xmlHeader

    it "generates a track request with two xml documents", ->
      expect(_xmlDocs).to.have.length(3)

    it "includes an AccessRequest in the track request", (done) ->
      _xmlParser.parseString _xmlDocs[1], (err, doc) ->
        doc.should.have.property('AccessRequest')
        done()

    it "includes a TrackRequest in the track request", (done) ->
      _xmlParser.parseString _xmlDocs[2], (err, doc) ->
        doc.should.have.property('TrackRequest')
        done()

    it "includes an AccessRequest with license number, user id and password", (done) ->
      _xmlParser.parseString _xmlDocs[1], (err, doc) ->
        accessReq = doc['AccessRequest']
        accessReq.should.have.property 'AccessLicenseNumber'
        accessReq.should.have.property 'UserId'
        accessReq.should.have.property 'Password'
        accessReq['AccessLicenseNumber'][0].should.equal '12345'
        accessReq['UserId'][0].should.equal 'shipit'
        accessReq['Password'][0].should.equal 'password'
        done()

    it "includes a TrackRequest with customer context", (done) ->
      _xmlParser.parseString _xmlDocs[2], (err, doc) ->
        trackReq = doc['TrackRequest']
        trackReq.should.have.property 'Request'
        trackReq['Request'][0]['TransactionReference'][0]['CustomerContext'][0].should.equal 'eloquent shipit'
        done()

    it "includes a TrackRequest with request action and option", (done) ->
      _xmlParser.parseString _xmlDocs[2], (err, doc) ->
        trackReq = doc['TrackRequest']
        trackReq.should.have.property 'Request'
        trackReq['Request'][0]['RequestAction'][0].should.equal 'track'
        trackReq['Request'][0]['RequestOption'][0].should.equal '3'
        done()

    it "includes a TrackRequest with the correct tracking number", (done) ->
      _xmlParser.parseString _xmlDocs[2], (err, doc) ->
        trackReq = doc['TrackRequest']
        trackReq['TrackingNumber'][0].should.equal '1Z5678'
        done()

  describe "requestOptions", ->
    _options = null
    _generateReqSpy = null

    before ->
      _generateReqSpy = bond(_upsClient, 'generateRequest').through()
      _options = _upsClient.requestOptions trk: '1ZMYTRACK123', reference: 'zappos'

    it "creates a POST request", ->
      _options.method.should.equal 'POST'

    it "uses the correct URL", ->
      _options.uri.should.equal 'https://www.ups.com/ups.app/xml/Track'

    it "calls generateRequest with the correct parameters", ->
      _generateReqSpy.calledWith('1ZMYTRACK123', 'zappos').should.equal true

  describe "validateResponse", ->
    it "returns an error if response is not an xml document", (done) ->
      errorReported = false
      _upsClient.validateResponse 'bad xml', (err, resp) ->
        err.should.exist
        done() unless errorReported
        errorReported = true

    it "returns an error if xml response contains no nodes", (done) ->
      errorReported = false
      emptyResponse = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      _upsClient.validateResponse emptyResponse, (err, resp) ->
        err.should.exist
        done() unless errorReported
        errorReported = true

    it "returns an error if xml response does not contain a response status", (done) ->
      errorReported = false
      _xmlHeader = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      badResponse = '<TrackResponse><Response><ResponseStatusCode>1</ResponseStatusCode></Response></TrackResponse>'
      _upsClient.validateResponse _xmlHeader + badResponse, (err, resp) ->
        err.should.exist
        done() unless errorReported
        errorReported = true

    it "returns error description if xml response contains an unsuccessful status", (done) ->
      errorReported = false
      _xmlHeader = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      failureResponse = '<TrackResponse><Response><ResponseStatusCode>1</ResponseStatusCode><ResponseStatusDescription>Exception</ResponseStatusDescription><Error><ErrorDescription>No data</ErrorDescription></Error></Response></TrackResponse>'
      _upsClient.validateResponse _xmlHeader + failureResponse, (err, resp) ->
        err.should.equal "No data"
        done() unless errorReported
        errorReported = true

    it "returns an error if xml response does not contain shipment data", (done) ->
      errorReported = false
      noShipmentResponse = '<TrackResponse><Response><ResponseStatusCode>1</ResponseStatusCode><ResponseStatusDescription>Success</ResponseStatusDescription></Response></TrackResponse>'
      _upsClient.validateResponse _xmlHeader + noShipmentResponse, (err, resp) ->
        err.should.exist
        done() unless errorReported
        errorReported = true

    it "returns shipment data retrieved from the xml response", (done) ->
      goodResponse = '<TrackResponse><Response><ResponseStatusCode>1</ResponseStatusCode><ResponseStatusDescription>Success</ResponseStatusDescription></Response><Shipment>Smuggled Goods</Shipment></TrackResponse>'
      _upsClient.validateResponse _xmlHeader + goodResponse, (err, resp) ->
        expect(err).to.be.a 'null'
        expect(resp).to.equal 'Smuggled Goods'
        done()

  describe "getEta", ->
    _presentTimestamp = null

    beforeEach ->
      _presentTimestamp = bond(_upsClient, 'presentTimestamp').return('at midnight')

    it "uses ScheduledDeliveryDate", ->
      shipment = 'ScheduledDeliveryDate': ['tomorrow']
      eta = _upsClient.getEta shipment
      _presentTimestamp.calledWith('tomorrow').should.equal true
      expect(eta).to.equal 'at midnight'

    it "uses RescheduledDeliveryDate if ScheduledDeliveryDate is't available", ->
      shipment = 'Package': ['RescheduledDeliveryDate': ['next week']]
      _upsClient.getEta shipment
      _presentTimestamp.calledWith('next week').should.equal true

    it "calls presentTimestamp with a null if shipment is malformed", ->
      shipment = 'RandomCrap': ['garbage']
      _upsClient.getEta shipment
      _presentTimestamp.calledWith().should.equal true

  describe "getService", ->
    it "returns service description converted to title case", ->
      shipment = 'Service': ['Description': ['priority overnight']]
      service = _upsClient.getService shipment
      expect(service).to.equal 'Priority Overnight'

    it "returns undefined if service is not present", ->
      shipment = 'NoService': 'none'
      service = _upsClient.getService shipment
      expect(service).to.be.a 'undefined'

    it "returns undefined if service description is not present", ->
      shipment = 'Service': ['NoDescription': ['abc']]
      service = _upsClient.getService shipment
      expect(service).to.be.a 'undefined'

  describe "getWeight", ->
    it "returns package weight along with unit of measurement", ->
      shipment = 'Package': ['PackageWeight': ['Weight': ['very heavy'], 'UnitOfMeasurement': ['Code': ['moon lbs']]]]
      weight = _upsClient.getWeight shipment
      expect(weight).to.equal 'very heavy moon lbs'

    it "returns package weight even when unit of measurement is not available", ->
      shipment = 'Package': ['PackageWeight': ['Weight': ['very heavy']]]
      weight = _upsClient.getWeight shipment
      expect(weight).to.equal 'very heavy'

    it "returns null when weight data is malformed or unavailable", ->
      shipment = 'Package': ['PackageHasNoWeight']
      weight = _upsClient.getWeight shipment
      expect(weight).to.be.a 'null'

  describe "getDestination", ->
    _presentAddress = null

    beforeEach ->
      _presentAddress = bond(_upsClient, 'presentAddress').return('mi casa')

    it "calls presentAddress with the ship to address", ->
      shipment = 'ShipTo': ['Address': ['casa blanca']]
      address = _upsClient.getDestination shipment
      _presentAddress.calledWith('casa blanca').should.equal true
      expect(address).to.equal 'mi casa'

    it "calls presentAddress with a null if ship to address doesn't exist", ->
      shipment = 'ShipTo': ['NoAddress': ['su blanca']]
      _upsClient.getDestination shipment
      _presentAddress.calledWith().should.equal true

  describe "getActivitiesAndStatus", ->
    _presentAddressSpy = null
    _presentTimestampSpy = null
    _presentStatusSpy = null
    _activity1 = null
    _activity2 = null
    _activity3 = null
    _activity4 = null
    _shipment = null

    beforeEach ->
      _presentAddressSpy = bond(_upsClient, 'presentAddress')
      _presentTimestampSpy = bond(_upsClient, 'presentTimestamp')
      _presentStatusSpy = bond(_upsClient, 'presentStatus')
      _activity1 =
        'ActivityLocation': ['Address': ['middle earth']]
        'Date': ['yesterday']
        'Time': ['at noon']
        'Status': ['StatusType': ['Description': ['almost there']]]
      _activity2 =
        'ActivityLocation': ['Address': ['middle earth']]
        'Status': ['StatusType': ['Description': ['not there yet']]]
      _activity3 =
        'Date': ['yesterday']
        'Time': ['at noon']
        'Status': ['StatusType': ['Description': ['not there yet']]]
      _activity4 =
        'ActivityLocation': ['Address': ['shire']]
        'Date': ['two days ago']
        'Time': ['at midnight']
        'Status': ['StatusType': ['Description': ['fellowship begins']]]
      _shipment = 'Package': ['Activity': [_activity1]]

    it "returns an empty array and null status if no package activities are found", ->
      {activities, status} = _upsClient.getActivitiesAndStatus()
      expect(activities).to.be.an 'array'
      expect(activities).to.have.length 0
      expect(status).to.be.a 'null'

    it "calls presentAddress for activity location in package's activities", ->
      presentAddress = _presentAddressSpy.return()
      _upsClient.getActivitiesAndStatus _shipment
      presentAddress.calledWith('middle earth').should.equal true

    it "calls presentTimestamp for activity time and date in package's activities", ->
      presentTimestamp = _presentTimestampSpy.return()
      _upsClient.getActivitiesAndStatus _shipment
      presentTimestamp.calledWith('yesterday', 'at noon').should.equal true

    it "calls presentStatus for the first of package's activities", ->
      _presentAddressSpy.return 'rivendell'
      _presentTimestampSpy.return 'long long ago'
      presentStatus = _presentStatusSpy.return('look to the east')
      _shipment['Package'][0]['Activity'].push _activity4
      {activities, status} = _upsClient.getActivitiesAndStatus _shipment
      expect(activities).to.be.an 'array'
      expect(activities).to.have.length 2
      expect(status).to.equal 'look to the east'

    it "sets activity details to upper case first", ->
      _presentAddressSpy.return 'rivendell'
      _presentTimestampSpy.return 'long long ago'
      {activities} = _upsClient.getActivitiesAndStatus _shipment
      expect(activities[0].details).to.equal 'Almost there'

    it "skips activities that don't have a valid timestamp", ->
      _presentAddressSpy.return 'rivendell'
      _presentTimestampSpy.to (dateString, timeString) ->
        return 'long long ago' if dateString?
      _shipment['Package'][0]['Activity'].push _activity2
      {activities} = _upsClient.getActivitiesAndStatus _shipment
      expect(activities).to.be.an 'array'
      expect(activities).to.have.length 1

    it "skips activities that don't have a valid location", ->
      _presentAddressSpy.to (address) ->
        return 'rivendell' if address?
      _presentTimestampSpy.return 'long long ago'
      _shipment['Package'][0]['Activity'].push _activity3
      {activities} = _upsClient.getActivitiesAndStatus _shipment
      expect(activities).to.be.an 'array'
      expect(activities).to.have.length 1

  describe "presentTimestamp", ->
    it "returns undefined if dateString isn't specified", ->
      ts = _upsClient.presentTimestamp()
      expect(ts).to.be.a 'undefined'

    it "uses only the date string if time string isn't specified", ->
      ts = _upsClient.presentTimestamp '20140704'
      expect(ts).to.deep.equal new Date 'Jul 04 2014 00:00:00'

    it "uses the date and time strings when both are available", ->
      ts = _upsClient.presentTimestamp '20140704', '142305'
      expect(ts).to.deep.equal new Date 'Jul 04 2014 14:23:05'

  describe "presentAddress", ->
    _presentLocationSpy = null

    beforeEach ->
      _presentLocationSpy = bond(_upsClient, 'presentLocation')

    it "returns undefined if raw address isn't specified", ->
      address = _upsClient.presentAddress()
      expect(address).to.be.a 'undefined'

    it "calls presentLocation using the city, state, country and postal code", (done) ->
      address =
        city: 'Chicago'
        stateCode: 'IL'
        countryCode: 'US'
        postalCode: '60654'
      rawAddress =
        'City': [address.city]
        'StateProvinceCode': [address.stateCode]
        'CountryCode': [address.countryCode]
        'PostalCode': [address.postalCode]
      _presentLocationSpy.to (raw) ->
        expect(raw).to.deep.equal address
        done()
      _upsClient.presentAddress rawAddress

    it "calls presentLocation even when address components aren't available", ->
      presentLocation = _presentLocationSpy.return('Nowhere in Africa')
      address = _upsClient.presentAddress({})
      expect(address).to.equal 'Nowhere in Africa'
      presentLocation.calledWith().should.equal true

  describe "presentStatus", ->
    it "detects delivered status", ->
      statusType = 'StatusType': ['Code': ['D']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.DELIVERED

    it "detects en route status after package has been picked up", ->
      statusType = 'StatusType': ['Code': ['P']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.EN_ROUTE

    it "detects en route status for packages in transit", ->
      statusType = 'StatusType': ['Code': ['I']], 'StatusCode': ['Code': ['anything']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.EN_ROUTE

    it "detects en route status for packages that have an exception", ->
      statusType = 'StatusType': ['Code': ['X']], 'StatusCode': ['Code': ['U2']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.EN_ROUTE

    it "detects out-for-delivery status", ->
      statusType = 'StatusType': ['Code': ['I']], 'StatusCode': ['Code': ['OF']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.OUT_FOR_DELIVERY

    it "detects delayed status", ->
      statusType = 'StatusType': ['Code': ['X']], 'StatusCode': ['Code': ['anything else']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.DELAYED

    it "returns unknown if status code and type can't be matched", ->
      statusType = 'StatusType': ['Code': ['G']], 'StatusCode': ['Code': ['W']]
      status = _upsClient.presentStatus statusType
      expect(status).to.equal ShipperClient.STATUS_TYPES.UNKNOWN

    it "returns unknown if status code isn't available", ->
      status = _upsClient.presentStatus({})
      expect(status).to.equal ShipperClient.STATUS_TYPES.UNKNOWN

    it "returns unknown if status object is undefined", ->
      status = _upsClient.presentStatus()
      expect(status).to.equal ShipperClient.STATUS_TYPES.UNKNOWN

