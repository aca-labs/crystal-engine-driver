require "log_helper"

require "./constants"
require "./logger_io"

class PlaceOS::Driver
  # Set up logging
  backend = ::Log::IOBackend.new(STDOUT)
  backend.formatter = LOG_FORMATTER
  ::Log.setup("*", ::Log::Severity::Info, backend)

  # Allow signals to change the log level at run-time
  log_level_change = Proc(Signal, Nil).new do |signal|
    level = signal.usr1? ? ::Log::Severity::Debug : ::Log::Severity::Info
    Log.info { "> Log level changed to #{level}" }

    backend = ::Log::IOBackend.new(PlaceOS::Driver.logger_io)
    backend.formatter = PlaceOS::Driver::LOG_FORMATTER
    Log.builder.bind "*", level, backend
    signal.ignore
  end

  # Turn on DEBUG level logging `kill -s USR1 %PID`
  # Default production log levels (INFO and above) `kill -s USR2 %PID`
  Signal::USR1.trap &log_level_change
  Signal::USR2.trap &log_level_change

  # Custom backend that writes to a `PlaceOS::Driver::Protocol`
  class ProtocolBackend < ::Log::Backend
    getter protocol : Protocol

    {% if compare_versions(Crystal::VERSION, "0.36.0") < 0 %}
      def initialize(@protocol = Protocol.instance)
      end
    {% else %}
      def initialize(@protocol = Protocol.instance)
        @dispatcher = ::Log::Dispatcher.for(:async)
      end
    {% end %}

    def write(entry : ::Log::Entry)
      if exception = entry.exception
        message = "#{entry.message}\n#{exception.inspect_with_backtrace}"
        protocol.request entry.source, "debug", [entry.severity.to_i, message]
      else
        protocol.request entry.source, "debug", [entry.severity.to_i, entry.message]
      end
    end
  end

  # Custom Log that broadcasts to a `Log::IOBackend` and `PlaceOS::Driver::ProtocolBackend`
  class Log < ::Log
    getter broadcast_backend : ::Log::BroadcastBackend
    getter io_backend : ::Log::IOBackend
    getter protocol_backend : ProtocolBackend
    getter debugging : Bool

    def debugging=(value : Bool)
      @debugging = value

      # Don't worry it's not really an append, it's updating a hash with the
      # backend as the key, so this is a clean update
      @broadcast_backend.append(@protocol_backend, value ? ::Log::Severity::Debug : ::Log::Severity::None)
      self.level = value ? ::Log::Severity::Debug : ::Log::Severity::Info
    end

    def initialize(
      module_id : String,
      logger_io : IO = ::PlaceOS::Driver.logger_io,
      @protocol : Protocol = Protocol.instance,
      severity : ::Log::Severity = ::Log::Severity::Info
    )
      @debugging = false

      # Create a Driver protocol log backend
      @protocol_backend = ProtocolBackend.new(protocol: @protocol)

      # Create a IO based log backend
      @io_backend = ::Log::IOBackend.new(logger_io)
      @io_backend.formatter = PlaceOS::Driver::LOG_FORMATTER

      # Combine backends
      @broadcast_backend = ::Log::BroadcastBackend.new
      broadcast_backend.append(io_backend, severity)
      broadcast_backend.append(protocol_backend, ::Log::Severity::None)
      super(module_id, broadcast_backend, severity)

      # NOTE:: if broadcast level is set then it overrides the backend severity levels
      @broadcast_backend.level = nil
    end

    def level=(severity : ::Log::Severity)
      super(severity)

      # NOTE:: if broadcast level is set then it overrides the backend severity levels
      @broadcast_backend.level = nil
    end
  end
end
