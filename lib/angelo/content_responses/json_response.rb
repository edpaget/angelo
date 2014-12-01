module Angelo

  module ContentResponses
    class JSONResponse
      def call body
        case body
        when String
          JSON.parse body # for the raises
          body
        when Hash
          body.to_json
        when NilClass
          EMPTY_STRING
        end
      end
    end
  end
  
end
