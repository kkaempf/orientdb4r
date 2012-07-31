module Orientdb4r

  class RestClient < Client
    include Aop2


    before [:query, :command], :assert_connected
    before [:create_class, :get_class, :drop_class, :create_property], :assert_connected
    before [:create_document, :get_document, :update_document, :delete_document], :assert_connected
    around [:query, :command], :time_around


    def initialize(options) #:nodoc:
      super()
      options_pattern = { :host => 'localhost', :port => 2480, :ssl => false,
                          :nodes => :optional, :load_balancing => :sequence,
                          :connection_library => Orientdb4r::connection_library}
      verify_and_sanitize_options(options, options_pattern)

      # fake nodes for single server
      if options[:nodes].nil?
        options[:nodes] = [{:host => options[:host], :port => options[:port], :ssl => options[:ssl]}]
      end
      raise ArgumentError, 'nodes has to be arrray' unless options[:nodes].is_a? Array

      # instantiate nodes accroding to HTTP library
      @connection_library = options[:connection_library]
      node_clazz = case connection_library
        when :restclient then Orientdb4r::RestClientNode
        when :excon then Orientdb4r::ExconNode
        else raise ArgumentError, "unknown connection library: #{connection_library}"
      end

      # nodes
      options[:nodes].each do |node_options|
        verify_and_sanitize_options(node_options, options_pattern)
        @nodes << node_clazz.new(node_options[:host], node_options[:port], node_options[:ssl])
      end

      # load balancing
      @load_balancing = options[:load_balancing]
      @lb_strategy = case load_balancing
        when :sequence then Orientdb4r::Sequence.new nodes.size
        when :round_robin then Orientdb4r::RoundRobin.new nodes.size
        else raise ArgumentError, "unknow load balancing type: #{load_balancing}"
      end


      Orientdb4r::logger.info "client initialized with #{@nodes.size} node(s) "
      Orientdb4r::logger.info "connection_library=#{options[:connection_library]}, load_balancing=#{load_balancing}"
    end


    # --------------------------------------------------------------- CONNECTION

    def connect(options) #:nodoc:
      options_pattern = { :database => :mandatory, :user => :mandatory, :password => :mandatory }
      verify_and_sanitize_options(options, options_pattern)
      @database = options[:database]
      @user = options[:user]
      @password = options[:password]

      node = nodes[lb_strategy.node_index]
      begin
        response = call_server(:method => :get, :uri => "connect/#{@database}")
      rescue
        @connected = false
        @server_version = nil
        @user = nil
        @password = nil
        @database = nil
        @nodes.each { |node| node.cleanup }
        raise ConnectionError
      end
      rslt = process_response response
      decorate_classes_with_model(rslt['classes'])

      # try to read server version
      if rslt.include? 'server'
        @server_version = rslt['server']['version']
      else
        @server_version = DEFAULT_SERVER_VERSION
      end
      unless server_version =~ SERVER_VERSION_PATTERN
        Orientdb4r::logger.warn "bad version format, version=#{server_version}"
        @server_version = DEFAULT_SERVER_VERSION
      end

      Orientdb4r::logger.debug "successfully connected to server, version=#{server_version}"
      @connected = true
      rslt
    end


    def disconnect #:nodoc:
      return unless @connected

      begin
        call_server(:method => :get, :uri => 'disconnect')
        # https://groups.google.com/forum/?fromgroups#!topic/orient-database/5MAMCvFavTc
        # Disconnect doesn't require you're authenticated.
        # It always returns 401 because some browsers intercept this and avoid to reuse the same session again.
      ensure
        @connected = false
        @server_version = nil
        @user = nil
        @password = nil
        @database = nil
        @nodes.each { |node| node.cleanup }
        Orientdb4r::logger.debug 'disconnected from server'
      end
    end


    def server(options={}) #:nodoc:
      options_pattern = { :user => :optional, :password => :optional }
      verify_options(options, options_pattern)

      # additional authentication allowed, overriden in 'call_server' if not defined
      response = call_server :method => :get, :uri => 'server'
      process_response(response)
    end


    # ----------------------------------------------------------------- DATABASE

    def create_database(options) #:nodoc:
      options_pattern = {
        :database => :mandatory, :type => 'memory',
        :user => :optional, :password => :optional
      }
      verify_and_sanitize_options(options, options_pattern)

      # additional authentication allowed, overriden in 'call_server' if not defined
      response = call_server_one_off :method => :post, :uri => "database/#{options[:database]}/#{options[:type]}"
      process_response(response)
    end


    #> curl --user admin:admin http://localhost:2480/database/temp
    def get_database(options=nil) #:nodoc:
      raise ArgumentError, 'options have to be a Hash' if !options.nil? and !options.kind_of? Hash

      if options.nil?
        # use database from connect
        raise ConnectionError, 'client has to be connected if no params' unless connected?
        options = { :database => database }
      end

      options_pattern = { :database => :mandatory, :user => :optional, :password => :optional }
      verify_options(options, options_pattern)

      # additional authentication allowed, overriden in 'call_server' if not defined
      params = {:method => :get, :uri => "database/#{options[:database]}"}
      params[:user] = options[:user] if options.include? :user
      params[:password] = options[:password] if options.include? :password

      response = call_server params

      # NotFoundError cannot be raised - no way how to recognize from 401 bad auth
      process_response(response)
    end


    def delete_database(options) #:nodoc:
      options_pattern = {
        :database => :mandatory, :user => :optional, :password => :optional
      }
      verify_and_sanitize_options(options, options_pattern)

      # additional authentication allowed, overriden in 'call_server' if not defined
      response = call_server_one_off :method => :delete, :uri => "database/#{options[:database]}"
      process_response(response)
    end


    # ---------------------------------------------------------------------- SQL

    def query(sql, options=nil) #:nodoc:
      raise ArgumentError, 'query is blank' if blank? sql

      options_pattern = { :limit => :optional }
      verify_options(options, options_pattern) unless options.nil?

      limit = ''
      limit = "/#{options[:limit]}" if !options.nil? and options.include?(:limit)

      response = call_server(:method => :get, :uri => "query/#{@database}/sql/#{CGI::escape(sql)}#{limit}")
      entries = process_response(response) do
        raise NotFoundError, 'record not found' if response.body =~ /ORecordNotFoundException/
      end

      rslt = entries['result']
      # mixin all document entries (they have '@class' attribute)
      rslt.each { |doc| doc.extend Orientdb4r::DocumentMetadata unless doc['@class'].nil? }
      rslt
    end


    def command(sql) #:nodoc:
      raise ArgumentError, 'command is blank' if blank? sql
      response = call_server(:method => :post, :uri => "command/#{@database}/sql/#{CGI::escape(sql)}")
      process_response(response)
    end


    # -------------------------------------------------------------------- CLASS

    def get_class(name) #:nodoc:
      raise ArgumentError, "class name is blank" if blank?(name)

      if compare_versions(server_version, '1.1.0') >= 0
        response = call_server(:method => :get, :uri => "class/#{@database}/#{name}")
        rslt = process_response(response) do
          raise NotFoundError, 'class not found' if response.body =~ /Invalid class/
        end

        classes = [rslt]
      else
        # there is bug in REST API [v1.0.0, fixed in r5902], only data are returned
        # workaround - use metadate delivered by 'connect'
        response = call_server(:method => :get, :uri => "connect/#{@database}")
        connect_info = process_response(response) do
          raise NotFoundError, 'class not found' if response.body =~ /Invalid class/
        end

        classes = connect_info['classes'].select { |i| i['name'] == name }
        raise NotFoundError, "class not found, name=#{name}" unless 1 == classes.size
      end

      decorate_classes_with_model(classes)
      clazz = classes[0]
      clazz.extend Orientdb4r::HashExtension
      clazz.extend Orientdb4r::OClass
      unless clazz['properties'].nil? # there can be a class without properties
        clazz.properties.each do |prop|
          prop.extend Orientdb4r::HashExtension
          prop.extend Orientdb4r::Property
        end
      end

      clazz
    end


    # ----------------------------------------------------------------- DOCUMENT

    def create_document(doc) #:nodoc:
      response = call_server(:method => :post, :uri => "document/#{@database}", \
          :content_type => 'application/json', :data => doc.to_json)
      srid = process_response(response)  do
        raise DataError, 'validation problem' if response.body =~ /OValidationException/
      end

      Rid.new srid
    end


    def get_document(rid) #:nodoc:
      rid = Rid.new(rid) unless rid.is_a? Rid
      response = call_server(:method => :get, :uri => "document/#{@database}/#{rid.unprefixed}")
      rslt = process_response(response) do
        raise NotFoundError, 'record not found' if response.body =~ /ORecordNotFoundException/
        raise NotFoundError, 'record not found' if response.body =~ /Record with id .* was not found/ # why after delete?
      end

      rslt.extend Orientdb4r::DocumentMetadata
      rslt
    end


    def update_document(doc) #:nodoc:
      raise ArgumentError, 'document is nil' if doc.nil?
      raise ArgumentError, 'document has no RID' if doc.doc_rid.nil?
      raise ArgumentError, 'document has no version' if doc.doc_version.nil?

      rid = doc.doc_rid
      doc.delete '@rid' # will be not updated

      response = call_server(:method => :put, :uri => "document/#{@database}/#{rid.unprefixed}", \
          :content_type => 'application/json', :data => doc.to_json)
      process_response(response) do
        raise DataError, 'concurrent modification' if response.body =~ /OConcurrentModificationException/
        raise DataError, 'validation problem' if response.body =~ /OValidationException/
      end
      # empty http response
    end


    def delete_document(rid) #:nodoc:
      rid = Rid.new(rid) unless rid.is_a? Rid

      response = call_server(:method => :delete, :uri => "document/#{@database}/#{rid.unprefixed}")
      process_response(response) do
        raise NotFoundError, 'record not found' if response.body =~ /ORecordNotFoundException/
      end
      # empty http response
    end


    # ------------------------------------------------------------------ Helpers

    private

      ####
      # Processes a HTTP response.
      def process_response(response)
        raise ArgumentError, 'response is null' if response.nil?

        if block_given?
          yield
        end


        # return code
        if 401 == response.code
          raise UnauthorizedError, compose_error_message(response)
        elsif 500 == response.code
          raise ServerError, compose_error_message(response)
        elsif 2 != (response.code / 100)
          raise OrientdbError, "unexpected return code, code=#{response.code}, body=#{compose_error_message(response)}"
        end

        content_type = response.headers[:content_type] if connection_library == :restclient
        content_type = response.headers['Content-Type'] if connection_library == :excon
        content_type ||= 'text/plain'

        rslt = case
          when content_type.start_with?('text/plain')
            response.body
          when content_type.start_with?('application/json')
            ::JSON.parse(response.body)
          else
            raise OrientdbError, "unsuported content type: #{content_type}"
          end

        rslt
      end


      ###
      # Composes message of an error raised if the HTTP response doesn't
      # correspond with expectation.
      def compose_error_message(http_response, max_len=200)
        msg = http_response.body.gsub("\n", ' ')
        msg = "#{msg[0..max_len]} ..." if msg.size > max_len
        msg
      end


      # @deprecated
      def process_restclient_response(response, options={})
        raise ArgumentError, 'response is null' if response.nil?

        # raise problem if other code than 200
        if options[:mode] == :strict and 200 != response.code
          raise OrientdbError, "unexpeted return code, code=#{response.code}"
        end
        # log warning if other than 200 and raise problem if other code than 'Successful 2xx'
        if options[:mode] == :warning
          if 200 != response.code and 2 == (response.code / 100)
            Orientdb4r::logger.warn "expected return code 200, but received #{response.code}"
          elseif 200 != response.code
            raise OrientdbError, "unexpeted return code, code=#{response.code}"
          end
        end

        content_type = response.headers[:content_type]
        content_type ||= 'text/plain'

        rslt = case
          when content_type.start_with?('text/plain')
            response.body
          when content_type.start_with?('application/json')
            ::JSON.parse(response.body)
          end

        rslt
      end

      def decorate_classes_with_model(classes)
        classes.each do |clazz|
          clazz.extend Orientdb4r::HashExtension
          clazz.extend Orientdb4r::OClass
            unless clazz['properties'].nil? # there can be a class without properties
              clazz.properties.each do |prop|
                prop.extend Orientdb4r::HashExtension
                prop.extend Orientdb4r::Property
            end
          end
        end
      end

  end

end
