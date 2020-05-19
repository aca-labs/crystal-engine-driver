require "uri"
require "connect-proxy"

# Provides a `HTTP::Client` for a driver context. This may be used to execute
# HTTP requests (e.g. against an admin interface) regardless of, or in parallel
# to the primary transport.
class PlaceOS::Driver::HTTPClient < ConnectProxy::HTTPClient
  def initialize(config : DriverModel, settings : Settings? = nil, tls : HTTP::Client::TLSContext = nil)
    if config.role.logic?
      raise "direct external comms not supported from logic drivers"
    end

    @settings = settings || Settings.new(config.settings)

    uri = config.uri.try(&.strip)
    uri = URI.parse(!uri.empty && uri || config.ip.not_nil!)
    tls = new_tls_context if tls == true || uri.scheme == "https"

    client = super(uri, tls)

    if auth = auth_settings
      client.basic_auth **auth
    end

    if proxy_config = proxy_settings
      proxy = ConnectProxy.new(**proxy_config)
      client.before_request { client.set_proxy(proxy) }
    end

    client
  end

  def auth_settings
    @settings.get do
      setting?(NamedTuple(username: String, password: String), :basic_auth)
    end
  end

  def proxy_settings
    @settings.get do
      setting?(NamedTuple(host: String, port: Int32, auth: NamedTuple(username: String, password: String)?), :proxy)
    end
  end

  def tls_settings

  end

  protected def new_tls_context : OpenSSL::SSL::Context::Client
    # Default to no_verify
    verify_mode = OpenSSL::SSL::VerifyMode::NONE

    if mode = setting?(String | Int32, :https_verify)
      # NOTE:: why we use case here crystal-lang/crystal#7382
      if mode.is_a?(String)
        verify_mode = case mode.camelcase.downcase
                      when "none"
                        OpenSSL::SSL::VerifyMode::NONE
                      when "peer"
                        OpenSSL::SSL::VerifyMode::PEER
                      when "failifnopeercert"
                        OpenSSL::SSL::VerifyMode::FAIL_IF_NO_PEER_CERT
                      when "clientonce"
                        OpenSSL::SSL::VerifyMode::CLIENT_ONCE
                      when "all"
                        OpenSSL::SSL::VerifyMode::All
                      else
                        OpenSSL::SSL::VerifyMode::NONE
                      end
      else
        begin
          verify_mode = OpenSSL::SSL::VerifyMode.from_value(mode)
        rescue error
          Log.warn { "issue configuring verify mode\n#{error.inspect_with_backtrace}" }
        end
      end
    end

    new_tls_context(verify_mode)
  end

  protected def new_tls_context(verify_mode : OpenSSL::SSL::VerifyMode) : OpenSSL::SSL::Context::Client
    tls = OpenSSL::SSL::Context::Client.new
    tls.verify_mode = verify_mode
    tls
  end
end
