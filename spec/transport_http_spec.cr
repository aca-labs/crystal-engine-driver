require "webmock"
require "./helper"

describe PlaceOS::Driver::TransportHTTP do
  WebMock.stub(:any, "www.example.com")

  queue = Helper.queue
  transport = PlaceOS::Driver::TransportHTTP.new(queue, "http://www.example.com/", ::PlaceOS::Driver::Settings.new("{}"))

  it "connects" do
    transport.connect
    queue.online.should eq(true)
  end

  {% for method in %i(get post put head delete patch options) %}
    it "supports {{method.id.upcase}} requests" do
      response = transport.http({{method}}, "/")
      response.status_code.should eq(200)
    end
  {% end %}

  it "terminates" do
    transport.terminate
    queue.online.should eq(true)
  end
end
