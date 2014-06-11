require 'drb/drb'
require 'sync'
require 'VixDiskLib_FFI/const'
require 'VixDiskLib_FFI/enum'
#
# Alias the New FFI Binding Class Name to the old C Binding Class Name
#
VixDiskLib_raw = FFI::VixDiskLib::API

class VixDiskLibError < RuntimeError
end

MIQ_ROOT    = "#{File.dirname(__FILE__)}/../../"
SERVER_PATH = "#{File.dirname(__FILE__)}/"
LOG_DIR     = MIQ_ROOT + "vmdb/log/"
LOG_FILE    = LOG_DIR + "vim.log"

class VixDiskLib
  VIXDISKLIB_FLAG_OPEN_READ_ONLY = FFI::VixDiskLib::API::VIXDISKLIB_FLAG_OPEN_READ_ONLY
  @init_parms = {}
  @drb_services = []
  @connection_lock = Sync.new
  @shutting_down = nil

  #
  # Just stash the init arguments into a hash for now.
  # We will call init on the server every time a connect request is made.
  #
  def self.init(info_logger = nil, warn_logger = nil, error_logger = nil, lib_dir = nil)
    raise VixDiskLibError, "VixDiskLibClient.init() VixDiskLib already initialized" unless @init_parms.empty?
    @init_parms[:info] = info_logger
    @init_parms[:warn] = warn_logger
    @init_parms[:error] = error_logger
    @init_parms[:lib_dir] = lib_dir
    nil
  end

  def self.connect(connect_parms)
    @connection_lock.synchronize(:EX) do
      raise VixDiskLibError, "VixDiskLibClient.connect() failed: VixDiskLib not initialized" if @init_parms.empty?
      raise VixDiskLibError, "VixDiskLibClient.connect() aborting: VixDiskLib shutting down" if @shutting_down
      vix_disk_lib_service = start_service
      @drb_services << vix_disk_lib_service
      #
      # Let the DRb service start before attempting to use it.
      # I can find no examples suggesting that this is required, but on my test machine it is indeed.
      #
      retry_limit = 5
      begin
        sleep 1
        vix_disk_lib_service.init(@init_parms[:info], @init_parms[:warn], @init_parms[:error], @init_parms[:lib_dir])
      rescue DRb::DRbConnError => e
        if retry_limit > 0
          sleep 1
          retry_limit -= 1
          retry
        else
          raise VixDiskLibError, "VixDiskLibClient.connect() failed: #{e} on VixDiskLib.init()"
        end
      end
      vix_disk_lib_service.connect(connect_parms)
    end
  end

  def self.exit
    @connection_lock.synchronize(:EX) do
      @shutting_down = true
      DRb.stop_service
      i = 0
      @drb_services.each do |vdl_service|
        i += 1
        $vim_log.info "VixDiskLib.exit: shutting down service #{i} of #{@drb_services.size}" if $vim_log
        unless vdl_service.nil?
          begin
            vdl_service.shutdown = true
          rescue DRb::DRbConnError
            $vim_log.info "VixDiskLib.exit: DRb connection closed due to service shutdown.  Continuing" if $vim_log
          end
        end
      end
      # Now clear data so we can start over if needed
      @init_parms.clear
      num_services = @drb_services.size
      @drb_services.pop(num_services)
    end
  end

  #
  # Remove the Rails Environment Variables set in the Current Environment so that the SSL Libraries don't get loaded.
  #
  def self.setup_env
    vars_to_clear = %w(BUNDLE_BIN BUNDLE_BIN_PATH BUNDLE_GEMFILE
                       BUNDLE_ORIG_MANPATH EVMSERVER GEM_HOME
                       GEM_PATH MIQ_GUID RAILS_ENV RUBYOPT ORIGINAL_GEM_PATH)
    my_env = ENV.to_hash
    vars_to_clear.each do |key|
      my_env.delete(key)
    end
    my_env
  end

  def self.start_service
    #
    # TODO: Get the path to the server programatically - this server should probably live elsewhere.
    # TODO: Find a better place for this log file - the real log dir.
    #
    my_env = setup_env
    reader, writer = IO.pipe
    writerfd = writer.fileno
    my_env["WRITER_FD"] = writerfd.to_s
    pid = Kernel.spawn(my_env, "ruby " + SERVER_PATH + "VixDiskLibServer.rb",
                       [:out, :err]     => [LOG_FILE, "a"],
                       :unsetenv_others => true,
                       :close_others    => false,
                       reader           => :close)
    writer.close
    Process.detach(pid)
    $vim_log.info "VixDiskLibServer Process #{pid} started" if $vim_log
    DRb.start_service
    retry_num = 5
    begin
      sleep 1
      vix_disk_lib_service = DRbObject.new(nil, get_uri(reader))
    rescue DRb::DRbConnError => e
      raise VixDiskLibError, "ERROR: VixDiskLibClient.connect() got #{e} on DRbObject.new_with_uri()" if retry_num == 0
      retry_num -= 1 && retry
    end
    vix_disk_lib_service
  end

  def self.get_uri(reader)
    if reader.eof
      #
      # Error - unable to read the port number written into the pipe by the child (Server).
      #
      raise VixDiskLibError, "ERROR: VixDiskLibClient.connect() Unable to determine port used by VixDiskLib Server."
    end
    uri_selected = reader.gets.split("URI:")
    if uri_selected.length != 2
      raise VixDiskLibError, "ERROR: VixDiskLibClient.connect() Unable to determine port used by VixDiskLib Server."
    end
    uri_selected[1].chomp
  end
end
