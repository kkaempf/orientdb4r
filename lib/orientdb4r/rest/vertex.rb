module Orientdb4r

  class Vertex
    include Aop2


    before [:query, :command], :assert_connected
    before [:create_class, :get_class, :class_exists?, :drop_class, :create_property], :assert_connected
    before [:create_document, :get_document, :update_document, :delete_document], :assert_connected
    around [:query, :command], :time_around

    #
    # Intialize Vertex from result hash
    #
    # {"@type"=>"d", "@rid"=>"#11:218", "@version"=>1, "@class"=>"CIMClass", "name"=>"CIM_Location", "scheme"=>"Core", "superclass"=>"CIM_ManagedElement", "out_Superclass"=>"#11:110"}
    #
    def initialize(hash) #:nodoc:
      @type = hash['@type']
      @rid = Rid.new hash['@rid']
      @version = hash['@version']
      @class = hash['@class']
      @properties = hash.select { |k,v| k =~ /^[^@]/ }
    end

  end

end
