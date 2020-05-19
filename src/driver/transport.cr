require "tokenizer"
require "./transport/http_proxy"

abstract class PlaceOS::Driver::Transport
  abstract def send(message) : PlaceOS::Driver::Transport
  abstract def send(message, task : PlaceOS::Driver::Task, &block : (Bytes, PlaceOS::Driver::Task) -> Nil) : PlaceOS::Driver::Transport
  abstract def terminate : Nil
  abstract def disconnect : Nil
  abstract def start_tls(verify_mode : OpenSSL::SSL::VerifyMode, context : OpenSSL::SSL::Context) : Nil
  abstract def connect(connect_timeout : Int32) : Nil

  property tokenizer : ::Tokenizer? = nil

  # Only SSH implements exec
  def exec(message) : SSH2::Channel
    raise ::IO::EOFError.new("exec is only available to SSH transports")
  end

  # Use `logger` of `Driver::Queue`
  delegate logger, to: @queue

  macro inherited
    def enable_multicast_loop(state = true)
      {% if @type.name.stringify == "PlaceOS::Driver::TransportUDP" %}
        @socket.try &.multicast_loopback = state
      {% end %}
      state
    end
  end

  private def process(data : Bytes) : Nil
    if tokenize = @tokenizer
      messages = tokenize.extract(data)
      if messages.size == 1
        process_message(messages[0])
      else
        messages.each { |message| process_message(message) }
      end
    else
      process_message(data)
    end
  rescue error
    Log.error { "error processing data\n#{error.inspect_with_backtrace}" }
  end

  private def process_message(data)
    # We want to ignore completed tasks as they could not have been the cause of the data
    # The next task has not executed so this data is not associated with a task
    task = @queue.current
    task = nil if task.try &.complete?

    # Check if the task provided a response processing block
    if task
      if processing = task.processing
        processing.call(data, task)
        return
      end
    end

    # See spec for how this callback is expected to be used
    @received.call(data, task)
  rescue error
    Log.error { "error processing received data\n#{error.inspect_with_backtrace}" }
  end
end
