#!/usr/bin/env ruby
# description: ManageIQ appliance console
#

# TODO: Move the Service Support (start/stop/restart/status) to it's own file (appliance_console_service.rb)
# and update callers to appliance_console.rb to use the appliance_console_service.rb.
console_title = 'Evm Appliance Console [appliance_console.rb]'
ARGV << "start" if ARGV.empty?

# developers can turn this off
LOCK_CONSOLE = !(ENV["LOCK_CONSOLE"].to_s.strip.downcase == "false")

def bail_if_running(message = "running...")
  pids = `pgrep -f "ruby.*appliance_console.rb"`.chomp.split
  pids.each do |pid|
    if Process.pid != pid.to_i
      puts "Evm Appliance Console (pid #{pid}) is #{message}"
      exit 0
    end
  end
end

case ARGV.first
when "start"
  bail_if_running if LOCK_CONSOLE
when "stop"
  puts "Stopping #{console_title} disabled"
  exit 1
when "status"
  bail_if_running
  puts "#{console_title} is stopped..."
  exit 0
when "restart"
  puts "Restarting #{console_title} is disabled..."
  exit 1
else
  puts "Invalid command: #{ARGV.first}: Usage: #{__FILE__} {start,stop,status,restart}"
  exit 1
end

# Simulate rubygems adding the top level appliance_console.rb's directory to the path.
$LOAD_PATH.push(File.dirname(__FILE__))

ROOT = [
  "/var/www/miq",
  File.expand_path(File.join(File.dirname(__FILE__), ".."))
].detect { |f| File.exist?(f) }

# Set up Environment
ENV['BUNDLE_GEMFILE'] ||= "#{ROOT}/vmdb/Gemfile"
require 'bundler'
Bundler.setup

require 'fileutils'
require 'highline/import'
require 'highline/system_extensions'
require 'rubygems'
require 'timeout'
require 'bcrypt'
require 'linux_admin'
require 'pathname'
require 'util/vmdb-logger'
include HighLine::SystemExtensions

require 'i18n'
LOCALES = File.join(File.expand_path(File.dirname(__FILE__)), "appliance_console/locales/*.yml")
I18n.load_path = Dir[LOCALES].sort
I18n.enforce_available_locales = true
I18n.backend.load_translations

TIMEOUT = 300

def ask_with_timeout(*args, &block)
  Timeout.timeout(TIMEOUT) { ask_without_timeout(*args, &block) }
end
alias ask_without_timeout ask
alias ask ask_with_timeout

def choose_with_timeout(*args, &block)
  Timeout.timeout(TIMEOUT) { choose_without_timeout(*args, &block) }
end
alias choose_without_timeout choose
alias choose choose_with_timeout

def agree_with_timeout(*args, &block)
  Timeout.timeout(TIMEOUT) { agree_without_timeout(*args, &block) }
end
alias agree_without_timeout agree
alias agree agree_with_timeout

$terminal.wrap_at = 80
$terminal.page_at = 21

$MIQDEBUG = false
$MIQDEBUG_FILES = %W(#{ROOT}/lib/appliance_console.rb
                     /bin/miqnet.sh
                     #{ROOT}/vmdb/lib/tasks/evm_dba.rake
                     #{ROOT}/lib/util/mount/miq_generic_mount_session.rb
                     #{ROOT}/lib/util/mount/miq_smb_session.rb
                     #{ROOT}/lib/util/mount/miq_nfs_session.rb
                     #{ROOT}/vmdb/lib/evm_database_ops.rb)

require 'appliance_console/errors.rb'

[:INT, :TERM, :KILL, :ABRT, :TSTP].each { |s| trap(s) { raise MiqSignalError } } if LOCK_CONSOLE

# Disabled in order to allow rescue of timeout error
HighLine.track_eof = false

RAILS_ROOT    = Pathname.new("#{ROOT}/vmdb")
EVM_PID_FILE  = RAILS_ROOT.join("tmp/pids/evm.pid")
REGION_FILE   = RAILS_ROOT.join("REGION")
VERSION_FILE  = RAILS_ROOT.join("VERSION")
BUILD_FILE    = RAILS_ROOT.join("BUILD")
LOGFILE       = File.join(RAILS_ROOT, "log", "appliance_console.log")
DB_RESTORE_FILE = "/tmp/evm_db.backup"
PASS_FILE     = RAILS_ROOT.join("config/miq_pass")
DEF_PASS_FILE = RAILS_ROOT.join("config/miq_pass_default")

AS_OPTIONS = I18n.t("advanced_settings.menu_order").collect do |item|
  I18n.t("advanced_settings.#{item}")
end

CANCEL        = "Cancel"

# Restore database choices
RESTORE_LOCAL   = "Local file"
RESTORE_NFS     = "Network File System (nfs)"
RESTORE_SMB     = "Samba (smb)"
RESTORE_OPTIONS = [RESTORE_LOCAL, RESTORE_NFS, RESTORE_SMB, CANCEL]

# Restart choices
RE_RESTART  = "Restart"
RE_DELLOGS  = "Restart and Clean Logs"
RE_OPTIONS  = [RE_RESTART, RE_DELLOGS, CANCEL]

# Timezone constants
$tzdata          = nil
TZ_AREAS         = %w{Africa America Asia Atlantic Australia Canada Europe Indian Pacific US}
TZ_AREAS_OPTIONS = ["United States", "Canada", "Africa", "America", "Asia", "Atlantic Ocean", "Australia", "Europe",
                    "Indian Ocean", "Pacific Ocean", CANCEL]
TZ_AREAS_MAP     = Hash.new { |_h, k| k }.merge!(
    "United States"  => "US",
    "Atlantic Ocean" => "Atlantic",
    "Pacific Ocean"  => "Pacific",
    "Indian Ocean"   => "Indian"
  )
TZ_AREAS_MAP_REV = Hash.new { |_h, k| k }.merge!(TZ_AREAS_MAP.invert)

# Load appliance_console libraries
require 'appliance_console/utilities'
require 'appliance_console/logging'
require 'appliance_console/database_configuration'
require 'appliance_console/internal_database_configuration'
require 'appliance_console/external_database_configuration'
require 'appliance_console/external_httpd_authentication'
require 'appliance_console/temp_storage_configuration'
require 'appliance_console/env'
require 'appliance_console/key_configuration'

require 'appliance_console/prompts'
include ApplianceConsole::Prompts

module ApplianceConsole
loop do
  begin
    ip = Env["IP"]
    # Because it takes a few seconds, get the database information once in the outside loop
    dbhost, dbtype, database = ApplianceConsole::Utilities.db_host_type_database

    clear_screen

    say("ManageIQ Virtual Appliance\n\nTo administer this appliance, browse to https://#{ip}\n")
    if $MIQDEBUG
      $MIQDEBUG_FILES.each { |f| puts "Modified #{(Time.now - File.mtime(f)).to_i / 60} minutes ago - #{f}" }
    end

    ask_without_timeout("Username: ") do |q|
      q.validate = /ADMIN/i
      q.responses[:not_valid] = "Username invalid"
    end

    ask_without_timeout("Password: ") do |q|
      q.echo = '*'
      filename = File.exist?(PASS_FILE) ? PASS_FILE : DEF_PASS_FILE
      q.validate = ->(p) { BCrypt::Password.new(File.read(filename).chomp) == p }
      q.responses[:not_valid] = "Password invalid: "
    end

    loop do
      begin
        host     = Env["HOST"]
        ip       = Env["IP"]
        mac      = Env["MAC"]
        mask     = Env["MASK"]
        gw       = Env["GW"]
        dns1     = Env["DNS1"]
        dns2     = Env["DNS2"]
        order    = Env["SEARCHORDER"]
        # time   = Env["TIMESERVER"]
        timezone = Env["TIMEZONE"]
        region   = File.read(REGION_FILE).chomp  if File.exist?(REGION_FILE)
        version  = File.read(VERSION_FILE).chomp if File.exist?(VERSION_FILE)

        clear_screen

        say(<<-EOL)
Welcome to the ManageIQ Virtual Appliance.

To modify the configuration, use a web browser to access the management page.

        Hostname:          #{host}
        IP Address:        #{ip}
        Netmask:           #{mask}
        Gateway:           #{gw}
        Primary DNS:       #{dns1}
        Secondary DNS:     #{dns2}
        Search Order:      #{order}
        MAC Address:       #{mac}
        Timezone:          #{timezone}
        Local Database:    #{ApplianceConsole::Utilities.pg_status}
        EVM Database:      #{dbtype} @ #{dbhost}
        Database/Region:   #{database} / #{region || 0}
        External Auth:     #{ExternalHttpdAuthentication.config_status}
        EVM Version:       #{version}
        EVM Console:       https://#{ip}
        EOL

        say("Note: Use the Ctrl-Alt-Del to exit out of any screen and return to the summary screen.")
        say("You may need to use Ctrl-Alt-Ins to send a Ctrl-Alt-Del to the virtual machine.\n")
        press_any_key

        clear_screen
        selection = ask_with_menu("Advanced Setting", AS_OPTIONS, nil, true)
        case selection
        when I18n.t("advanced_settings.dhcp")
          say("DHCP Network Configuration\n\n")
          if agree("Apply DHCP network configuration? (Y/N): ")
            say("\nApplying DHCP network configuration...")
            Env['DHCP'] = true
            say("\nAfter completing the appliance configuration, please restart EVM server processes.")
          end

        when I18n.t("advanced_settings.static")
          say("Static Network Configuration\n\n")
          say("Enter the new static network configuration settings.\n\n")

          new_ip   = ask_for_ip("IP Address", ip)
          new_mask = ask_for_ip("Netmask", mask)
          new_gw   = ask_for_ip("Gateway", gw)
          new_dns1 = ask_for_ip("Primary DNS", dns1)
          new_dns2 = ask_for_ip_or_none("Secondary DNS (Enter 'none' for no value)")

          new_search_order = ask_for_many("domain", "Domain search order", order)

          clear_screen
          say(<<-EOL)
Static Network Configuration

        IP Address:      #{new_ip}
        Netmask:         #{new_mask}
        Gateway:         #{new_gw}
        Primary DNS:     #{new_dns1}
        Secondary DNS:   #{new_dns2}
        Search Order:    #{new_search_order.join(" ")}

          EOL

          if agree("Apply static network configuration? (Y/N)")
            say("\nApplying static network configuration...")

            Env['STATIC'] = new_ip, new_mask, new_gw, new_dns1, new_dns2

            # Convert space delimiter to semicolon: manageiq.com galaxy.local to manageiq.com;galaxy.local
            # so we can pass it on the command line to miqnet.sh without quoting it
            Env['SEARCHORDER'] = new_search_order.join("\\;") unless Env.error?

            say("\nAfter completing the appliance configuration, please restart EVM server processes.")
          end

        when I18n.t("advanced_settings.testnet")
          ApplianceConsole::Utilities.test_network

        when I18n.t("advanced_settings.hostname")
          say("Hostname Configuration\n\n")
          new_host = just_ask("new hostname", host)

          if new_host != host
            say("Applying new hostname...")
            Env['HOST'] = new_host
          end

        when I18n.t("advanced_settings.datetime")
          say("Date and Time Configuration\n\n")

          # Cache time zone data the first time
          if $tzdata.nil?
            $tzdata = {}
            TZ_AREAS.each do |a|
              $tzdata[a] = ary = []
              a = "/usr/share/zoneinfo/#{a}/"
              Dir.glob("#{a}*").each do |z|
                ary << z[a.length..-1]
              end
              ary.sort!
            end
          end

          timezone = timezone.split("/")
          cur_loc = timezone[0]
          cur_city = timezone[1..-1].join("/")

          # Prompt for timezone geographic area (with current area as default)
          def_loc = TZ_AREAS.include?(cur_loc) ? TZ_AREAS_MAP_REV[cur_loc] : nil
          tz_area = ask_with_menu("Geographic Location", TZ_AREAS_OPTIONS, def_loc, false)
          next if tz_area == CANCEL
          new_loc = TZ_AREAS_MAP[tz_area]

          # Prompt for timezone specific city (with current city as default)
          default_city = cur_city if $tzdata[new_loc].include?(cur_city) && cur_loc == new_loc
          new_city = ask_with_menu("Timezone", $tzdata[new_loc], default_city, true) do |menu|
            menu.list_option = :columns_across
          end
          next if new_city == CANCEL

          clear_screen
          say("Date and Time Configuration\n\n")

          new_date = ask_for_date("current date (YYYY-MM-DD)")
          new_time = ask_for_time("current time in 24 hour format (HH:MM:SS)")

          clear_screen
          say(<<-EOL)
Date and Time Configuration

        Timezone area: #{tz_area}
        Timezone city: #{new_city}
        Date:          #{new_date}
        Time:          #{new_time}

          EOL

          if agree("Apply time and timezone configuration? (Y/N): ")
            say("Applying time and timezone configuration...")
            Env['TIMEZONE'] = new_loc, new_city
            Env['TIME'] = new_date, new_time unless Env.error?
          end


        when I18n.t("advanced_settings.httpdauth")
          say("#{selection}\n\n")

          httpd_auth = ExternalHttpdAuthentication.new(host)
          if httpd_auth.ask_questions && httpd_auth.activate
            httpd_auth.post_activation
            say("\nExternal Authentication configured successfully.\n")
            press_any_key
          else
            say("\nExternal Authentication configuration failed!\n")
            press_any_key
            raise MiqSignalError
          end

        when I18n.t("advanced_settings.evmstop")
          say("#{selection}\n\n")
          if agree("\nNote: It may take up to a few minutes for all EVM Server processes to exit gracefully.  Perform an EVM stop? (Y/N): ")
            if File.exist?(EVM_PID_FILE)
              say("\nStopping EVM...")
              Env['STOP'] = true
            else
              say("\nNo EVM PID file.  EVM Server is not running...")
            end
          end

        when I18n.t("advanced_settings.evmstart")
          say("#{selection}\n\n")
          if agree("\nPerform an EVM start? (Y/N): ")
            say("\nStarting EVM...")
            Env['START'] = true
          end

        when I18n.t("advanced_settings.dbrestore")
          say("#{selection}\n\n")
          ApplianceConsole::Utilities.bail_if_db_connections "preventing a database restore"

          task_with_opts = ""
          uri = nil

          # TODO: merge into 1 prompt
          case ask_with_menu("Restore Database File", RESTORE_OPTIONS, RESTORE_LOCAL, nil)
          when RESTORE_LOCAL
            validate = ->(a) { File.exist?(a) }
            uri = just_ask("location of the local restore file", DB_RESTORE_FILE, validate, "file that exists")
            task_with_opts = "evm:db:restore:local -- --local-file '#{uri}'"

          when RESTORE_NFS
            uri = ask_for_uri("location of the remote backup file\nExample: #{sample_url('nfs')})", "nfs")
            task_with_opts = "evm:db:restore:remote -- --uri '#{uri}'"

          when RESTORE_SMB
            uri = ask_for_uri("location of the remote backup file\nExample: #{sample_url('smb')}", "smb")
            user = just_ask("username with access to this file.\nExample: 'mydomain.com/user'")
            pass = ask_for_password("password for #{user}")

            task_with_opts = "evm:db:restore:remote -- --uri '#{uri}' --uri-username '#{user}' --uri-password '#{pass}'"

          when CANCEL
            raise MiqSignalError
          end

          clear_screen
          say("#{selection}\n\n")

          delete_agreed = false
          if selection == RESTORE_LOCAL
            say "The local database restore file is located at: '#{uri}'.\n"
            delete_agreed = agree("Should this file be deleted after completing the restore? (Y/N): ")
          end

          say "\nNote: A database restore cannot be undone.  The restore will use the file: #{uri}.\n"
          if agree("Are you sure you would like to restore the database? (Y/N): ")
            say("\nRestoring the database...")
            if Env.rake(task_with_opts) && delete_agreed
              say("\nRemoving the database restore file #{DB_RESTORE_FILE}...")
              File.delete(DB_RESTORE_FILE)
            end
          end

        when I18n.t("advanced_settings.dbregion_setup")
          say("#{selection}\n\n")
          ApplianceConsole::Utilities.bail_if_db_connections("preventing the setup of a database region")
          clear_screen
          say("#{selection}\n\n")
          say("Note: Each database region number must be unique.\n\n")
          region_number = ask_for_integer("Enter a database region number: ")
          clear_screen
          say "It is recommended to use a new database or backup the existing database first.\n"
          say "Warning: SETTING A DATABASE REGION WILL DESTROY ANY EXISTING DATA AND CANNOT BE UNDONE.\n\n"
          if agree("Setting Database Region to: #{region_number}\nAre you sure you want to continue? (Y/N): ")
            say("Setting Database Region...  This process may take a few minutes.\n\n")

            if Env.rake("evm:db:region -- --region #{region_number} 1>> #{LOGFILE}")
              say("Database region setup complete...\nStart the EVM server processes via '#{I18n.t("advanced_settings.evmstart")}'.")
            end
            press_any_key
          else
            raise MiqSignalError
          end

        when I18n.t("advanced_settings.db_config")
          say("#{selection}\n\n")
          loc_selection = ask_with_menu("Database Location", %w(Internal External), nil, false)

          ApplianceConsole::Logging.logger = VMDBLogger.new(LOGFILE)
          database_configuration = ApplianceConsole.const_get("#{loc_selection}DatabaseConfiguration").new
          database_configuration.ask_questions

          clear_screen
          say "Activating the configuration using the following settings...\n"
          say "#{database_configuration.friendly_inspect}\n"

          if database_configuration.activate
            database_configuration.post_activation
            say("\nConfiguration activated successfully.\n")
            press_any_key
          else
            say("\nConfiguration activation failed!\n")
            press_any_key
            raise MiqSignalError
          end

        when I18n.t("advanced_settings.tmp_config")
          ApplianceConsole::TempStorageConfiguration.new.process_menus

        when I18n.t("advanced_settings.restart")
          case ask_with_menu("Restart Option", RE_OPTIONS, nil, false)
          when CANCEL
            # don't do anything
          when RE_RESTART
            Env['RESTARTOS'] = are_you_sure?("restart the appliance now")
          when RE_DELLOGS
            Env['RESTARTOSRMLOGS'] = are_you_sure?("restart the appliance now")
          end

        when I18n.t("advanced_settings.shutdown")
          say("#{selection}\n\n")
          if are_you_sure?("shut down the appliance now")
            say("\nShutting down appliance...  This process may take a few minutes.\n\n")
            Env['SHUTDOWN'] = true
          end

        when I18n.t("advanced_settings.summary")
          # Do nothing

        when I18n.t("advanced_settings.logoff")
          say("#{selection}\n\n")
          break if are_you_sure?("log off the appliance")
        end
      rescue Timeout::Error
        break
      rescue MiqSignalError
        # If a signal is caught anywhere in the inner (after login) loop, go back to the summary screen
        next
      ensure
        if Env.changed?
          if (errtext = Env.error)
            say("\nAn error occurred:\n\n#{errtext}")
          else
            say("\nCompleted successfully.")
          end
          press_any_key

        end
        Env.clear_errors
      end
    end
  rescue MiqSignalError
    # If a signal is caught anywhere in the outer loop (before login), go back to the login screen
    next
  end
end
end
