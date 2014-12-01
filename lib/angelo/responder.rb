module Angelo

  class Responder
    include Celluloid::Logger

    class << self

      attr_writer :default_headers, :content_types

      # top-level setter
      def content_type type, lambda_or_class=nil
        dhs = self.default_headers
        cts = self.content_types
        
        if cts.has_key? type
          self.default_headers = dhs.merge CONTENT_TYPE_HEADER_KEY => cts[type].mime
        elsif type === String
          self.content_types = cts.merge type => ContentType.new(type, lambda_or_class)
          self.default_headers = dhs.merge CONTENT_TYPE_HEADER_KEY => type
        else
          raise ArgumentError.new "invalid content_type: #{type}"
        end
      end

      def default_headers
        @default_headers ||= DEFAULT_RESPONSE_HEADERS
        @default_headers
      end

      def content_types
        @content_types ||= DEFAULT_CONTENT_TYPES
        @content_types
      end

      def symhash
        Hash.new {|hash,key| hash[key.to_s] if Symbol === key }
      end

    end

    attr_accessor :connection, :request
    attr_writer :base

    def initialize &block
      @response_handler = Base.compile! :request_handler, &block
    end

    def reset!
      @params = nil
      @redirect = nil
      @body = nil
      @request = nil
    end

    def handle_request
      if @response_handler
        @base.filter :before
        @body = catch(:halt) { @response_handler.bind(@base).call || EMPTY_STRING }

        # TODO any real reason not to run afters with SSE?
        case @body
        when HALT_STRUCT
          @base.filter :after if @body.body != :sse
        else
          @base.filter :after
        end

        respond
      else
        raise NotImplementedError
      end
    rescue JSON::ParserError => jpe
      handle_error jpe, :bad_request
    rescue FormEncodingError => fee
      handle_error fee, :bad_request
    rescue RequestError => re
      handle_error re, re.type
    rescue => e
      handle_error e
    end

    def handle_error _error, type = :internal_server_error, report = @base.report_errors?
      err_msg = error_message _error
      Angelo.log @connection, @request, nil, type, err_msg.size
      @connection.respond type, headers, err_msg
      @connection.close
      if report
        error "#{_error.class} - #{_error.message}"
        ::STDERR.puts _error.backtrace
      end
    end

    def error_message _error
      case
      when respond_with?(:json)
        { error: _error.message }.to_json
      else
        case _error.message
        when Hash
          _error.message.to_s
        else
          _error.message
        end
      end
    end

    def headers hs = nil
      @headers ||= self.class.default_headers.dup
      @headers.merge! hs if hs
      @headers
    end

    # route handler helper
    def content_type type
      cts = self.class.content_types
      if cts.has_key? type
        headers CONTENT_TYPE_HEADER_KEY => self.class.content_types[type].mime
      elsif type === String
        headers CONTENT_TYPE_HEADER_KEY => type
      else
        raise ArgumentError.new "invalid content_type: #{type}"
      end
    end

    def transfer_encoding *encodings
      encodings.flatten.each do |encoding|
        case encoding
        when :chunked
          @chunked = true
          headers transfer_encoding: :chunked
        # when :compress, :deflate, :gzip, :identity
        else
          raise ArgumentError.new "invalid transfer_conding: #{encoding}"
        end
      end
    end

    def respond
      status = nil
      case @body
      when HALT_STRUCT
        status = @body.status
        @body = @body.body
        @body = nil if @body == :sse
        if Hash === @body
          @body = {error: @body} if status != :ok or status < 200 && status >= 300
          @body = @body.to_json if respond_with? :json
        end

      else
        unless @chunked and @body.respond_to? :each
          raise RequestError.new "what is this? #{@body}"
        end
      end

      status ||= @redirect.nil? ? :ok : :moved_permanently
      headers LOCATION_HEADER_KEY => @redirect if @redirect

      if @chunked
        Angelo.log @connection, @request, nil, status
        @request.respond status, headers
        err = nil
        begin
          @body.each do |r|
            r = r.to_json + NEWLINE if respond_with? :json
            @request << r
          end
        rescue => e
          err = e
        ensure
          @request.finish_response
          raise err if err
        end
      else
        size = @body.nil? ? 0 : @body.size
        Angelo.log @connection, @request, nil, status, size
        @request.respond status, headers, @body
      end

    rescue => e
      handle_error e, :internal_server_error
    end

    def redirect url
      @redirect = url
    end

    def on_close= on_close
      raise ArgumentError.new unless Proc === on_close
      @on_close = on_close
    end

    def on_close
      @on_close[] if @on_close
    end

  end

end
