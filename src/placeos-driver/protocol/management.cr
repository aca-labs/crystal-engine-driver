require "log_helper"
require "promise"
require "set"
require "socket"
require "tokenizer"
require "yaml"

require "./request"

# Launch driver when first instance is requested
# Shutdown driver when no more instances required
class PlaceOS::Driver::Protocol::Management
  Log = ::Log.for("driver.protocol.management")

  alias DebugCallback = String -> Nil

  # Core should update this callback to route requests
  property on_exec : Proc(Request, Proc(Request, Nil), Nil) = ->(request : Request, callback : Proc(Request, Nil)) {}
  property on_setting : Proc(String, String, YAML::Any, Nil) = ->(module_id : String, setting_name : String, setting_value : YAML::Any) {}

  # A request for the system model as defined in the database
  property on_system_model : Proc(Request, Proc(Request, Nil), Nil) = ->(request : Request, callback : Proc(Request, Nil)) {}

  # These are the events coming from the driver where edge is expected to update redis on the drivers behalf
  enum RedisAction
    HSET
    SET
    CLEAR
  end
  property on_redis : Proc(RedisAction, String, String, String?, Nil) = ->(action : RedisAction, hash_id : String, key_name : String, status_value : String?) {}

  getter? terminated = false
  getter pid : Int64 = -1

  getter last_exit_code : Int32 = 0
  getter launch_count : Int32 = 0
  getter launch_time : Int64 = 0

  private getter tokenizer : Tokenizer = Tokenizer.new(Bytes[0x00, 0x03])

  private getter debug_lock : Mutex = Mutex.new(protection: :reentrant)
  private getter request_lock : Mutex = Mutex.new
  private getter settings_update_lock : Mutex = Mutex.new

  private getter modules : Hash(String, String) = {} of String => String
  private getter events : Channel(Request) = Channel(Request).new

  @io : IO::Stapled? = nil

  def initialize(@driver_path : String, @on_edge : Bool = false)
    @requests = {} of UInt64 => Promise::DeferredPromise(String)
    @starting = {} of String => Promise::DeferredPromise(Nil)

    @debugging = Hash(String, Array(DebugCallback)).new do |hash, key|
      hash[key] = [] of DebugCallback
    end

    @sequence = 1_u64
    spawn(same_thread: true) { process_events }
  end

  def running?
    !!@io
  end

  def module_instances
    modules.size
  end

  def terminate : Nil
    @events.send(Request.new("t", "terminate"))
  end

  def start(module_id : String, payload : String) : Nil
    update = false
    promise = request_lock.synchronize do
      prom = @starting[module_id]?
      # We want to ensure updates make it if they come in while loading
      if prom
        update = true
      else
        prom = @starting[module_id] = Promise.new(Nil)
      end
      prom
    end

    if update
      update(module_id, payload)
    else
      @events.send(Request.new(module_id, "start", payload))
    end
    promise.get
  end

  def update(module_id : String, payload : String) : Nil
    @events.send(Request.new(module_id, "update", payload))
  end

  def stop(module_id : String)
    @events.send(Request.new(module_id, "stop"))
  end

  def info
    return [] of String if terminated?
    promise = Promise.new(String)

    sequence = request_lock.synchronize do
      seq = @sequence
      @sequence = seq &+ 1
      @requests[seq] = promise
      seq
    end

    @events.send(Request.new("", "info", seq: sequence))
    Array(String).from_json promise.get
  end

  def execute(module_id : String, payload : String?) : String
    raise "module #{module_id} not running, terminated" if terminated?
    promise = Promise.new(String)

    sequence = request_lock.synchronize do
      seq = @sequence
      @sequence = seq &+ 1
      @requests[seq] = promise
      seq
    end

    @events.send(Request.new(module_id, "exec", payload, seq: sequence))
    promise.get
  end

  def debug(module_id : String, &callback : (String) -> Nil) : Nil
    count = debug_lock.synchronize do
      array = @debugging[module_id]
      array << callback
      array.size
    end

    return unless count == 1

    @events.send(Request.new(module_id, "debug"))
  end

  def ignore(module_id : String, &callback : DebugCallback) : Nil
    signal = debug_lock.synchronize do
      array = @debugging[module_id]
      initial_size = array.size
      array.delete callback

      if array.size == 0
        @debugging.delete(module_id)
        initial_size > 0
      else
        false
      end
    end

    return unless signal

    @events.send(Request.new(module_id, "ignore"))
  end

  # Remove all debug listeners on a module, returning the debug callback array
  #
  def ignore_all(module_id : String) : Array(DebugCallback)
    debug_lock.synchronize do
      @debugging[module_id].dup.tap do |callbacks|
        callbacks.each do |callback|
          ignore(module_id, &callback)
        end
      end
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  private def process_events
    loop do
      return if terminated?
      request = @events.receive

      begin
        case request.cmd
        when "start"
          start(request)
        when "stop"
          stop(request)
        when "exec"
          exec(request.id, request.payload.not_nil!, request.seq.not_nil!)
        when "result"
          io = @io
          next unless io
          json = request.to_json
          io.write_bytes json.bytesize
          io.write json.to_slice
          io.flush
        when "debug"
          debug(request.id)
        when "ignore"
          ignore(request.id)
        when "info"
          running_modules(request.seq.not_nil!)
        when "update"
          update(request)
        when "exited"
          relaunch(request.id)
        when "terminate"
          shutdown
        else
          raise "unexpected command: #{request.cmd}"
        end
      rescue error
        Log.error { {error: error.inspect_with_backtrace, driver_path: @driver_path} }
      end
    end
  end

  private def start(request : Request) : Nil
    module_id = request.id
    if modules[module_id]?
      update(request)
      starting = request_lock.synchronize { @starting.delete(module_id) }
      starting.resolve(nil) if starting

      return
    end

    payload = request.payload.not_nil!
    modules[module_id] = payload

    if io = @io
      json = %({"id":"#{module_id}","cmd":"start","payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    else
      start_process
    end
  end

  private def update(request : Request) : Nil
    module_id = request.id
    return unless modules[module_id]?

    payload = request.payload.not_nil!
    modules[module_id] = payload
    io = @io
    return unless io

    json = %({"id":"#{module_id}","cmd":"update","payload":#{payload.to_json}})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def stop(request : Request) : Nil
    module_id = request.id
    instance = modules.delete module_id
    io = @io
    return unless io && instance
    return shutdown(false) if modules.empty?

    json = %({"id":"#{module_id}","cmd":"stop"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def shutdown(terminated = true) : Nil
    @terminated = terminated
    io = @io
    return unless io

    modules.clear

    # The driver will shutdown the modules gracefully
    json = %({"id":"t","cmd":"terminate"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def exec(module_id : String, payload : String, seq : UInt64) : Nil
    io = @io
    if io && modules[module_id]?
      json = %({"id":"#{module_id}","cmd":"exec","seq":#{seq},"payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    elsif promise = request_lock.synchronize { @requests.delete(seq) }
      promise.reject Exception.new("module #{module_id} not running on this host")
    end
  end

  private def debug(module_id : String) : Nil
    io = @io
    return unless io && modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"debug"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def ignore(module_id : String) : Nil
    io = @io
    return unless io && modules[module_id]?

    json = %({"id":"#{module_id}","cmd":"ignore"})
    io.write_bytes json.bytesize
    io.write json.to_slice
    io.flush
  end

  private def running_modules(seq : UInt64)
    io = @io
    if io
      json = %({"id":"","cmd":"info","seq":#{seq}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    elsif promise = request_lock.synchronize { @requests.delete(seq) }
      promise.resolve "[]"
    end
  end

  # This function
  private def start_process : Nil
    return if @io || terminated?

    stdin_reader, input = IO.pipe
    output, stderr_writer = IO.pipe

    # We want to be manually flushing our writes
    input.sync = false
    io = IO::Stapled.new(output, input, true)

    @launch_count += 1
    @launch_time = Time.utc.to_unix

    fetch_pid = Promise.new(Int64)
    spawn(same_thread: true) { launch_driver(fetch_pid, stdin_reader, stderr_writer) }
    @pid = fetch_pid.get.as(Int64)

    # Start processing the output of the driver
    loaded = Promise.new(Nil)
    spawn(same_thread: true) { process_comms(io, loaded) }
    loaded.get

    # start the desired instances
    modules.each do |module_id, payload|
      json = %({"id":"#{module_id}","cmd":"start","payload":#{payload.to_json}})
      io.write_bytes json.bytesize
      io.write json.to_slice
      io.flush
    end

    # events can now write directly to the io, driver is running
    @io = io
  end

  # launches the driver and manages the process
  private def launch_driver(fetch_pid, stdin_reader, stderr_writer) : Nil
    Process.run(
      @driver_path,
      @on_edge ? {"-p", "-e"} : {"-p"},
      input: stdin_reader,
      output: Process::Redirect::Inherit,
      error: stderr_writer
    ) do |process|
      fetch_pid.resolve process.pid
    end

    status = $?
    last_exit_code = status.exit_code.to_s
    Log.warn { {message: "driver process exited with #{last_exit_code}", driver_path: @driver_path} } unless status.success?
    @events.send(Request.new(last_exit_code, "exited"))
  end

  private def relaunch(last_exit_code : String) : Nil
    @io = nil
    @last_exit_code = last_exit_code.to_i
    return if terminated?
    start_process unless modules.empty?
  end

  MESSAGE_INDICATOR = "\x00\x02"

  private def process_comms(io, loaded)
    raw_data = Bytes.new(2048)

    # wait for ready signal
    io.read_string(1)
    loaded.resolve(nil)

    while !io.closed?
      bytes_read = io.read(raw_data)
      break if bytes_read == 0 # IO was closed

      # These should never be enabled in production.
      # leaving here in case protocol level debugging is required for development
      # Log.debug { "manager #{@driver_path} received #{bytes_read}" }

      tokenizer.extract(raw_data[0, bytes_read]).each do |message|
        string = nil
        begin
          string = String.new(message[0..-3])
          _junk, _, string = string.rpartition(MESSAGE_INDICATOR)

          # Log.debug do
          #  if junk.empty?
          #    "manager #{@driver_path} processing #{string}"
          #  else
          #    "manager #{@driver_path} processing #{string}, ignoring #{junk}"
          #  end
          # end

          request = Request.from_json(string)
          spawn(same_thread: true) { process(request) }
        rescue error
          Log.warn(exception: error) { "error parsing request #{string.inspect}" }
        end
      end
    end
  rescue error : IO::Error
    # Input stream closed. This should only occur on termination
    Log.debug(exception: error) { "comms closed for #{@driver_path}" }
  ensure
    # Reject any pending request
    temp_reqs = request_lock.synchronize do
      reqs = @requests
      @requests = {} of UInt64 => Promise::DeferredPromise(String)
      reqs
    end
    temp_reqs.each { |request| request.reject(Exception.new("process terminated")) }
    Log.info { "comms closed for #{@driver_path}" }
  end

  # This function is used to process comms coming from the driver
  # ameba:disable Metrics/CyclomaticComplexity
  private def process(request)
    case request.cmd
    when "start"
      if starting = request_lock.synchronize { @starting.delete(request.id) }
        starting.resolve(nil)
      end
    when "result"
      seq = request.seq.not_nil!
      if promise = request_lock.synchronize { @requests.delete(seq) }
        # determine if the result was a success or an error
        if request.error
          promise.reject request.build_error
        elsif payload = request.payload
          promise.resolve payload
        else
          promise.resolve "null"
        end
      else
        Log.warn { "sequence number #{request.seq} not found for result from #{request.id}" }
      end
    when "debug"
      # pass the unparsed message down the pipe
      payload = request.payload.not_nil!
      watchers = debug_lock.synchronize { @debugging[request.id].dup }
      watchers.each do |callback|
        callback.call(payload)
      rescue error
        Log.warn(exception: error) { "error forwarding debug payload #{request.inspect}" }
      end
    when "exec"
      # need to route this internally to the correct module
      on_exec.call(request, ->(response : Request) {
        # The event queue is for sending data to the driver
        response.cmd = "result"
        @events.send(response)
        nil
      })
    when "sys"
      # the response payload should return the requested systems database model
      on_system_model.call(request, ->(response : Request) {
        response.cmd = "result"
        @events.send(response)
        nil
      })
    when "setting"
      mod_id = request.id
      setting_name, setting_value = Tuple(String, YAML::Any).from_yaml(request.payload.not_nil!)
      settings_update_lock.synchronize { on_setting.call(mod_id, setting_name, setting_value) }
    when "hset"
      # Redis proxy driver state (hash)
      hash_id = request.id
      key, value = request.payload.not_nil!.split("\x03", 2)
      on_redis.call(RedisAction::HSET, hash_id, key, value.empty? ? "null" : value)
    when "set"
      # Redis proxy key / value
      key = request.id
      value = request.payload.not_nil!
      on_redis.call(RedisAction::SET, key, value, nil)
    when "clear"
      hash_id = request.id
      on_redis.call(RedisAction::CLEAR, hash_id, "clear", nil)
    else
      Log.warn { "received unknown request #{request.cmd} - #{request.inspect}" }
    end
  rescue error
    Log.warn(exception: error) { "error processing driver request #{request.inspect}" }
  end
end
