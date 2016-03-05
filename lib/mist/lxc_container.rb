require 'lxc'

module Mist
  class LXCContainer
    attr_reader :name, :distro, :release, :ips

    def initialize(name, distro = nil, release = nil)
      @name = name
      @distro = distro
      @release = release

      @container = LXC::Container.new(@name)
      @ips = []
    end

    def exists?
      @container.defined?
    end

    def create
      raise "Container #{@name} already exists!" if exists?

      # Find the template for this container; if one does not exist on the host,
      # create it.
      template = LXCTemplate.new(distro, release)
      unless template.exists?
        Mist.logger.info "Template for #{distro}-#{release} does not exist"
        template.create
      end

      # Fast-clone a new container from the template
      Mist.logger.info 'Cloning template...'
      container = template.clone(@name)

      begin
        # Start the container
        Mist.logger.info "Starting #{@name}"

        container.start
        container.wait(:running, 30)

        # Wait for the network to start
        Mist.logger.info 'Waiting for network...'

        @ips = []
        start = Time.now
        loop do
          @ips = container.ip_addresses
          break unless @ips.empty?

          sleep 0.5

          raise 'timed out waiting for network' \
            if (Time.now - start) >= 30
        end

        # Give the container a few more seconds to allow SSH to start
        socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
        sockaddr = Socket.sockaddr_in(22, @ips.first)
        start = Time.now
        loop do
          begin
            if socket.connect_nonblock(sockaddr) == 0
              Mist.logger.info 'SSH started'
              socket.close
              break
            else
              sleep 0.5
            end

            raise 'timed out waiting for SSH' \
              if (Time.now - start) >= 30
          rescue Errno::ECONNREFUSED, Errno::EWOULDBLOCK, Errno::EINPROGRESS
            # Ignored
          end
        end
      rescue StandardError => ex
        Mist.logger.error "Failed to start container #{@name}: #{ex}"

        # Attempt to clean up
        container.stop if container.running?
        container.destroy if container.defined?

        raise
      end

      @container = container
    end

    def destroy
      raise "Container #{@name} does not exist!" unless exists?

      begin
        @container.stop
        @container.wait(:stopped, 60)
        @container.destroy

        @container = nil
        @ips = []
      rescue StandardError => ex
        Mist.logger.error "Failed to destroy container #{@name}: #{ex}"
        raise
      end
    end
  end
end
