require "option_parser"

require "./driver/logger"

abstract class PlaceOS::Driver
  module Proxy
  end

  module Utilities
  end

  annotation Security
  end

  enum Level
    Support
    Administrator
  end

  def initialize(
    @__module_id__ : String,
    @__setting__ : Settings,
    @__queue__ : Queue,
    @__transport__ : Transport,
    @__logger__ : PlaceOS::Driver::Log,
    @__schedule__ = Proxy::Scheduler.new,
    @__subscriptions__ = Proxy::Subscriptions.new,
    @__driver_model__ = DriverModel.from_json(%({"udp":false,"tls":false,"makebreak":false,"settings":{},"role":1}))
  )
    @__status__ = Status.new
    @__storage__ = Storage.new(@__module_id__)
    @__storage__.clear
    @__storage__.redis.set("interface/#{@__module_id__}", {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata)
  end

  @__system__ : Proxy::System?
  @__driver_model__ : DriverModel

  # Access to the various components
  HELPERS = %w(transport logger queue setting schedule subscriptions)
  {% for name in HELPERS %}
    def {{name.id}}
      @__{{name.id}}__
    end
  {% end %}

  def config
    @__driver_model__
  end

  # Status helpers #}
  def []=(key, value)
    key = key.to_s
    json_data, did_change = @__status__.set_json(key, value)
    if did_change
      # using spawn so execution flow isn't interrupted.
      # ensures that setting a key and then reading it back as the next
      # operation will always result in the expected value
      spawn(same_thread: true) { @__storage__[key] = json_data }
      @__logger__.debug { "status updated: #{key} = #{value}" }
    else
      @__logger__.debug { "no change for: #{key} = #{value}" }
    end
    value
  end

  def [](key)
    @__status__.fetch_json(key)
  end

  def []?(key)
    @__status__.fetch_json?(key)
  end

  macro status(klass, key)
    {{klass}}.from_json(@__status__[{{key}}.to_s])
  end

  macro status?(klass, key)
    %value = @__status__[{{key}}.to_s]?
    {{klass}}.from_json(%value) if %value
  end

  def signal_status(key)
    spawn(same_thread: true) { @__storage__.signal_status(key) }
  end

  def system : Proxy::System
    sys = @__system__
    return sys if sys

    system_model = @__driver_model__.control_system
    raise "not directly associated with a system" unless system_model
    @__system__ = Proxy::System.new(system_model, @__module_id__, @__logger__, @__subscriptions__)
  end

  # Settings helpers
  macro setting(klass, *types)
    @__setting__.get { setting({{klass}}, {{*types}}) }
  end

  macro setting?(klass, *types)
    @__setting__.get { setting?({{klass}}, {{*types}}) }
  end

  def define_setting(name, value)
    PlaceOS::Driver::Protocol.instance.request(@__module_id__, "setting", {name, value})
  end

  # Queuing
  def queue(**opts, &block : Task -> Nil)
    @__queue__.add(**opts, &block)
  end

  # Transport
  def send(message, **opts)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message)
    end
  end

  def send(message, **opts, &block : (Bytes, PlaceOS::Driver::Task) -> Nil)
    queue(**opts) do |task|
      task.request_payload = message if task.responds_to?(:request_payload)
      transport.send(message, task, &block)
    end
  end

  # Subscriptions and channels
  def subscribe(status, &callback : (Subscriptions::DirectSubscription, String) -> Nil) : Subscriptions::DirectSubscription
    @__subscriptions__.subscribe(@__module_id__, status.to_s, &callback)
  end

  def publish(channel, message)
    @__storage__.redis.publish("placeos/#{channel}", message.to_s)
    message
  end

  def monitor(channel, &callback : (Subscriptions::ChannelSubscription, String) -> Nil) : Subscriptions::ChannelSubscription
    @__subscriptions__.channel(channel.to_s, &callback)
  end

  # utilities
  def wake_device(mac_address, subnet = "255.255.255.255", port = 9)
    PlaceOS::Driver::Utilities::WakeOnLAN.wake_device(mac_address, subnet, port)
  end

  def set_connected_state(online, status_only = true)
    online = !!online
    if status_only
      @__queue__.set_connected(online)
    else
      @__queue__.online = online
    end
  end

  def disconnect
    @__transport__.disconnect
  end

  # Keep track of loaded driver classes. Should only be one.
  CONCRETE_DRIVERS = {} of Nil => Nil

  # Remote execution helpers
  macro inherited
    macro finished
      {% if !@type.abstract? %}
        __build_helpers__
        {% CONCRETE_DRIVERS[@type] = [@type.methods, (@type.name.id.stringify + "::KlassExecutor").id] %}
        __build_apply_bindings__
      {% end %}
    end
  end

  IGNORE_KLASSES   = ["PlaceOS::Driver", "Reference", "Object", "Spec::ObjectExtensions", "Colorize::ObjectExtensions"]
  RESERVED_METHODS = {} of Nil => Nil
  {% RESERVED_METHODS["initialize"] = true %}
  {% RESERVED_METHODS["received"] = true %}
  {% RESERVED_METHODS["connected"] = true %}
  {% RESERVED_METHODS["disconnected"] = true %}
  {% RESERVED_METHODS["on_load"] = true %}
  {% RESERVED_METHODS["on_update"] = true %}
  {% RESERVED_METHODS["on_unload"] = true %}
  {% RESERVED_METHODS["[]?"] = true %}
  {% RESERVED_METHODS["[]"] = true %}
  {% RESERVED_METHODS["[]="] = true %}
  {% RESERVED_METHODS["send"] = true %}
  {% RESERVED_METHODS["http"] = true %}
  {% for name in HELPERS %}
    {% RESERVED_METHODS[name.id.stringify] = true %}
  {% end %}

  macro __build_helpers__
    {% methods = @type.methods %}
    {% klasses = @type.ancestors.reject { |a| IGNORE_KLASSES.includes?(a.stringify) } %}
    # {{klasses.map &.stringify}} <- in case we need to filter out more classes
    {% klasses.map { |a| methods = methods + a.methods } %}
    {% methods = methods.reject { |method| RESERVED_METHODS[method.name.stringify] } %}
    {% methods = methods.reject { |method| method.visibility != :public } %}
    {% methods = methods.reject { |method| method.accepts_block? } %}
    # Filter out abstract methods
    {% methods = methods.reject { |method| method.body.stringify.empty? } %}

    # A class that handles executing every public method defined
    # NOTE:: currently doesn't handle multiple methods signatures (except block
    # and no block). Technically we could add the support however the JSON
    # parsing does not reliably pick the closest match and instead picks the
    # first or simplest match. So simpler to have a single method signature for
    # all public API methods
    class KlassExecutor
      def initialize(json : String)
        @lookup = Hash(String, JSON::Any).from_json(json)
        @exec = @lookup["__exec__"].as_s
      end

      @lookup : Hash(String, JSON::Any)
      @exec : String

      EXECUTORS = {
        {% for method in methods %}
          {% index = 0 %}
          {% args = [] of Crystal::Macros::Arg %}
          {% for arg in method.args %}
            {% if !method.splat_index || index < method.splat_index %}
              {% args << arg %}
            {% end %}
            {% index = index + 1 %}
          {% end %}

          {{method.name.stringify}} => ->(json : JSON::Any, klass : {{@type.id}}) do
            {% if args.size > 0 %}

              # Support argument lists
              if json.raw.is_a?(Array)
                arg_names = { {{*args.map { |arg| arg.name.stringify }}} }
                args = json.as_a

                raise "wrong number of arguments for '#{{{method.name.stringify}}}' (given #{args.size}, expected #{arg_names.size})" if args.size > arg_names.size

                hash = {} of String => JSON::Any
                json.as_a.each_with_index do |value, index|
                  hash[arg_names[index]] = value
                end

                json = hash
              end

              # Support named arguments
              tuple = {
                {% for arg in args %}
                  {% arg_name = arg.name.stringify %}

                  {% if !arg.restriction.is_a?(Union) && arg.restriction.resolve < ::Enum %}
                    {% if arg.default_value.is_a?(Nop) %}
                      {{arg.name}}: ({{arg.restriction}}).parse(json[{{arg_name}}].as_s),
                    {% else %}
                      {{arg.name}}: json[{{arg_name}}]? != nil ? ({{arg.restriction}}).parse(json[{{arg_name}}].as_s) : {{arg.default_value}},
                    {% end %}
                  {% else %}
                    {% if arg.default_value.is_a?(Nop) %}
                      {{arg.name}}: ({{arg.restriction}}).from_json(json[{{arg_name}}].to_json),
                    {% else %}
                      {{arg.name}}: json[{{arg_name}}]? ? ({{arg.restriction}}).from_json(json[{{arg_name}}].to_json) : {{arg.default_value}},
                    {% end %}
                  {% end %}
                {% end %}
              }
              ret_val = klass.{{method.name}}(**tuple)
            {% else %}
              ret_val = klass.{{method.name}}
            {% end %}

            case ret_val
            when Array(::Log::Entry)
              ret_val.map(&.message).to_json
            when ::Log::Entry
              ret_val.message.to_json
            when Task
              ret_val
            when Enum
              ret_val.to_s.to_json
            when JSON::Serializable
              ret_val.to_json
            else
              ret_val = ret_val.responds_to?(:get) ? ret_val.get : ret_val
              begin
                ret_val.try_to_json("null")
              rescue error
                klass.logger.info { "unable to convert result to json executing #{{{method.name.stringify}}} on #{klass.class}\n#{error.inspect_with_backtrace}" }
                "null"
              end
            end
          end,
        {% end %}
      }

      def execute(klass : {{@type.id}}) : Task | String
        json = @lookup[@exec]
        executor = EXECUTORS[@exec]?
        raise "execute requested for unknown method: #{@exec} on #{klass.class}" unless executor
        executor.call(json, klass)
      end

      # provide introspection into available functions
      @@functions : String?
      def self.functions : String
        functions = @@functions
        return functions if functions

        @@functions = funcs = {
          {% for method in methods %}
            {% index = 0 %}
            {% args = [] of Crystal::Macros::Arg %}
            {% for arg in method.args %}
              {% if !method.splat_index || index < method.splat_index %}
                {% args << arg %}
              {% end %}
              {% index = index + 1 %}
            {% end %}

            {{method.name.stringify}} => {
              {% for arg in args %}
                {{arg.name.stringify}} => [
                  {% if !arg.restriction.is_a?(Union) && arg.restriction.resolve < ::Enum %}
                    "String",
                    {% if !arg.default_value.is_a?(Nop) %}
                      {{arg.default_value}}.to_s
                    {% end %}
                  {% else %}
                    {{arg.restriction.stringify}},
                    {% if !arg.default_value.is_a?(Nop) %}
                      {{arg.default_value}}
                    {% end %}
                  {% end %}
                ],
              {% end %}
            }{% if args.size == 0 %} of String => Array(String){% end %},
          {% end %}
        }.to_json
        funcs
      end

      @@security : String?
      def self.security : String
        security = @@security
        return security if security

        sec = {} of String => Array(String)

        {% for method in methods %}
          {% if method.annotation(Security) %}
            level = {{method.annotation(Security)[0]}}.as(::PlaceOS::Driver::Level).to_s.downcase
            array = sec[level]? || [] of String
            array << {{method.name.stringify}}
            sec[level] = array
          {% end %}
        {% end %}

        @@security = sec = sec.to_json
        sec
      end

      @@metadata : String?
      def self.metadata : String
        metadata = @@metadata
        return metadata if metadata

        implements = {{@type.ancestors.map(&.stringify.split("(")[0])}}.reject { |obj| IGNORE_KLASSES.includes?(obj) }
        details = %({
          "functions": #{self.functions},
          "implements": #{implements.to_json},
          "requirements": #{Utilities::Discovery.requirements.to_json},
          "security": #{self.security}
        }).gsub(/\s/, "")

        @@metadata = details
      end
    end
  end
end

require "./driver/*"
require "./driver/proxy/*"
require "./driver/subscriptions/*"
require "./driver/transport/*"
require "./driver/utilities/*"

macro finished
  exec_process_manager = false

  # Command line options
  OptionParser.parse(ARGV.dup) do |parser|
    parser.banner = "Usage: #{PROGRAM_NAME} [arguments]"

    parser.on("-m", "--metadata", "output driver metadata") do
      puts {{PlaceOS::Driver::CONCRETE_DRIVERS.values.first[1]}}.metadata
      exit 0
    end

    parser.on("-d", "--defaults", "output driver defaults") do
      puts PlaceOS::Driver::Utilities::Discovery.defaults
      exit 0
    end

    parser.on("-p", "--process", "starts the process manager (expects to have been launched by PlaceOS core)") do
      exec_process_manager = true
    end

    parser.on("-h", "--help", "show this help") do
      puts parser
      exit 0
    end
  end

  # Set up logging
  backend = ::Log::IOBackend.new(STDOUT)
  backend.formatter = PlaceOS::Driver::LOG_FORMATTER
  ::Log.builder.bind("*", ::Log::Severity::Info, backend)

  # Launch the process manager by default, this can be overriten for testing
  if exec_process_manager
    process = PlaceOS::Driver::ProcessManager.new

    # Detect ctr-c to shutdown gracefully
    Signal::INT.trap do |signal|
      puts " > terminating gracefully"
      spawn(same_thread: true) { process.terminate }
      signal.ignore
    end

    process.terminated.receive?
  end
end
