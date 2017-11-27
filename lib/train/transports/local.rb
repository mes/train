# encoding: utf-8
#
# author: Dominik Richter
# author: Christoph Hartmann

require 'train/plugins'
require 'mixlib/shellout'

module Train::Transports
  class Local < Train.plugin(1)
    name 'local'

    include_options Train::Extras::CommandWrapper

    class PipeError < ::StandardError; end

    def connection(_ = nil)
      @connection ||= Connection.new(@options)
    end

    class Connection < BaseConnection
      def initialize(options)
        super(options)

        # While OS is being discovered, use the GenericRunner
        @runner = GenericRunner.new
        @runner.cmd_wrapper = CommandWrapper.load(self, options)

        if os.windows?
          # Attempt to use a named pipe but fallback to ShellOut if that fails
          begin
            @runner = WindowsPipeRunner.new
          rescue PipeError
            @runner = WindowsShellRunner.new
          end
        end
      end

      def local?
        true
      end

      def login_command
        nil # none, open your shell
      end

      def uri
        'local://'
      end

      private

      def run_command_via_connection(cmd)
        @runner.run_command(cmd)
      rescue Errno::ENOENT => _
        CommandResult.new('', '', 1)
      end

      def file_via_connection(path)
        if os.windows?
          Train::File::Local::Windows.new(self, path)
        else
          Train::File::Local::Unix.new(self, path)
        end
      end

      class GenericRunner
        attr_writer :cmd_wrapper

        def run_command(cmd)
          if defined?(@cmd_wrapper) && !@cmd_wrapper.nil?
            cmd = @cmd_wrapper.run(cmd)
          end

          res = Mixlib::ShellOut.new(cmd)
          res.run_command
          Local::CommandResult.new(res.stdout, res.stderr, res.exitstatus)
        end
      end

      class WindowsShellRunner
        require 'json'
        require 'base64'

        def run_command(script)
          # Prevent progress stream from leaking into stderr
          script = "$ProgressPreference='SilentlyContinue';" + script

          # Encode script so PowerShell can use it
          script = script.encode('UTF-16LE', 'UTF-8')
          base64_script = Base64.strict_encode64(script)

          cmd = "powershell -NoProfile -EncodedCommand #{base64_script}"

          res = Mixlib::ShellOut.new(cmd)
          res.run_command
          Local::CommandResult.new(res.stdout, res.stderr, res.exitstatus)
        end
      end

      class WindowsPipeRunner
        require 'json'
        require 'base64'
        require 'securerandom'

        def initialize
          @pipe = acquire_pipe
          fail PipeError if @pipe.nil?
        end

        def run_command(cmd)
          script = "$ProgressPreference='SilentlyContinue';" + cmd
          encoded_script = Base64.strict_encode64(script)
          @pipe.puts(encoded_script)
          @pipe.flush
          res = OpenStruct.new(JSON.parse(Base64.decode64(@pipe.readline)))
          Local::CommandResult.new(res.stdout, res.stderr, res.exitstatus)
        end

        private

        def acquire_pipe
          pipe_name = "inspec_#{SecureRandom.hex}"

          start_pipe_server(pipe_name)

          pipe = nil

          # PowerShell needs time to create pipe.
          100.times do
            begin
              pipe = open("//./pipe/#{pipe_name}", 'r+')
              break
            rescue
              sleep 0.1
            end
          end

          pipe
        end

        def start_pipe_server(pipe_name)
          require 'win32/process'

          script = <<-EOF
            $ErrorActionPreference = 'Stop'

            $pipeServer = New-Object System.IO.Pipes.NamedPipeServerStream('#{pipe_name}')
            $pipeReader = New-Object System.IO.StreamReader($pipeServer)
            $pipeWriter = New-Object System.IO.StreamWriter($pipeServer)

            $pipeServer.WaitForConnection()

            # Create loop to receive and process user commands/scripts
            $clientConnected = $true
            while($clientConnected) {
              $input = $pipeReader.ReadLine()
              $command = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($input))

              # Execute user command/script and convert result to JSON
              $scriptBlock = $ExecutionContext.InvokeCommand.NewScriptBlock($command)
              try {
                $stdout = & $scriptBlock | Out-String
                $result = @{ 'stdout' = $stdout ; 'stderr' = ''; 'exitstatus' = 0 }
              } catch {
                $stderr = $_ | Out-String
                $result = @{ 'stdout' = ''; 'stderr' = $_; 'exitstatus' = 1 }
              }
              $resultJSON = $result | ConvertTo-JSON

              # Encode JSON in Base64 and write to pipe
              $encodedResult = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($resultJSON))
              $pipeWriter.WriteLine($encodedResult)
              $pipeWriter.Flush()
            }
          EOF

          utf8_script = script.encode('UTF-16LE', 'UTF-8')
          base64_script = Base64.strict_encode64(utf8_script)
          cmd = "powershell -NoProfile -ExecutionPolicy bypass -NonInteractive -EncodedCommand #{base64_script}"

          server_pid = Process.create(command_line: cmd).process_id

          # Ensure process is killed when the Train process exits
          at_exit { Process.kill('KILL', server_pid) }
        end
      end
    end
  end
end
