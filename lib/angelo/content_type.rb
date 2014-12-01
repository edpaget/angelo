module Angelo

  class ContentType
    attr_reader :mime

    def initialize mime, lambda_or_class=nil
      @mime, @lambda_or_class = mime, lambda_or_class
    end

    def respond body 
      @lambda_or_class.class(body)
    end

    def respond_with?
      
    end
  end

end
