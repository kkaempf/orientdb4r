module Orientdb4r

  class Edge
    include Aop2


    before [:query, :command], :assert_connected
    before [:create_class, :get_class, :class_exists?, :drop_class, :create_property], :assert_connected
    before [:create_document, :get_document, :update_document, :delete_document], :assert_connected
    around [:query, :command], :time_around

    attr_reader :client, :type, :version, :class, :in, :out
    
    # convert vertex-like expression to sql
    # vertex can be
    # - a Vertex
    # - a Rid
    # - a Rid-like string
    # - a SELECT-like string
    def self.target vertex
      case vertex
      when Vertex
        self.target vertex.rid
      when Rid
        vertex.to_s
      when /^#(\d+):(\d+)$/ # Rid-like string
        vertex
      when String
        "(#{vertex})"
      else
        "(#{vertex})"
      end
    end
    #
    # Intialize Edge from result hash
    #
    #Edge: [{"@type"=>"d", "@version"=>0, "@class"=>"Superclass", "in"=>"#11:110", "out"=>"#11:218"}]
    
    def initialize(client, hash) #:nodoc:
#      puts "Edge.new #{hash}"
      @client = client
      @type = hash['@type']
      @version = hash['@version']
      @class = hash['@class']
      @in = hash['in']
      @out = hash['out']
    end

    def to_s
      "Edge #{@class} : #{@in} -> #{@out}"
    end
    
  end

end
