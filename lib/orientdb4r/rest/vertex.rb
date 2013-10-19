module Orientdb4r

  class Vertex
    include Aop2


    before [:query, :command], :assert_connected
    before [:create_class, :get_class, :class_exists?, :drop_class, :create_property], :assert_connected
    before [:create_document, :get_document, :update_document, :delete_document], :assert_connected
    around [:query, :command], :time_around

    attr_reader :client, :type, :rid, :version, :class
    #
    # Intialize Vertex from result hash
    #
    #
    def initialize(client, hash) #:nodoc:
#      puts "Vertex.new #{hash}"
      @client = client
      @type = hash['@type']
      @rid = Rid.new hash['@rid']
      @version = hash['@version']
      @class = hash['@class']
      @properties = hash.select { |k,v| k =~ /^[^@]/ }
    end

    def to_s
      "Vertex #{@rid} : #{@properties.inspect}"
    end
    
    def method_missing name, *args
      @properties[name.to_s]
    end
  end

end
