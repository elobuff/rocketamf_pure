require 'rocketamf/pure/io_helpers'

module RocketAMF
  module Pure
    # Pure ruby deserializer for AMF0 and AMF3
    class Deserializer
      attr_accessor :source

      # Pass in the class mapper instance to use when deserializing. This
      # enables better caching behavior in the class mapper and allows
      # one to change mappings between deserialization attempts.
      def initialize class_mapper
        @class_mapper = class_mapper
      end

      # Deserialize the source using AMF0 or AMF3. Source should either
      # be a string or StringIO object. If you pass a StringIO object,
      # it will have its position updated to the end of the deserialized
      # data.
      def deserialize version, source
        raise ArgumentError, "unsupported version #{version}" unless [0,3].include?(version)
        @version = version

        if StringIO === source
          @source = source
        elsif source
          @source = StringIO.new(source)
        elsif @source.nil?
          raise AMFError, "no source to deserialize"
        end

        if @version == 0
          @ref_cache = []
          return amf0_deserialize
        else
          @string_cache = []
          @object_cache = []
          @trait_cache = []
          return amf3_deserialize
        end
      end

      # Reads an object from the deserializer's stream and returns it.
      def read_object
        if @version == 0
          return amf0_deserialize
        else
          return amf3_deserialize
        end
      end

      private
      include RocketAMF::Pure::ReadIOHelpers

      def amf0_deserialize type=nil
        type = read_int8 @source unless type
        case type
        when AMF0_NUMBER_MARKER
          amf0_read_number
        when AMF0_BOOLEAN_MARKER
          amf0_read_boolean
        when AMF0_STRING_MARKER
          amf0_read_string
        when AMF0_OBJECT_MARKER
          amf0_read_object
        when AMF0_NULL_MARKER
          nil
        when AMF0_UNDEFINED_MARKER
          nil
        when AMF0_REFERENCE_MARKER
          amf0_read_reference
        when AMF0_HASH_MARKER
          amf0_read_hash
        when AMF0_STRICT_ARRAY_MARKER
          amf0_read_array
        when AMF0_DATE_MARKER
          amf0_read_date
        when AMF0_LONG_STRING_MARKER
          amf0_read_string true
        when AMF0_UNSUPPORTED_MARKER
          nil
        when AMF0_XML_MARKER
          amf0_read_string true
        when AMF0_TYPED_OBJECT_MARKER
          amf0_read_typed_object
        when AMF0_AMF3_MARKER
          deserialize(3, nil)
        else
          raise AMFError, "Invalid type: #{type}"
        end
      end

      def amf0_read_number
        res = read_double @source
        (res.is_a?(Float) && res.nan?) ? nil : res # check for NaN and convert them to nil
      end

      def amf0_read_boolean
        read_int8(@source) != 0
      end

      def amf0_read_string long=false
        len = long ? read_word32_network(@source) : read_word16_network(@source)
        str = @source.read(len)
        str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
        str
      end

      def amf0_read_reference
        index = read_word16_network(@source)
        @ref_cache[index]
      end

      def amf0_read_array
        len = read_word32_network(@source)
        array = []
        @ref_cache << array

        0.upto(len - 1) do
          array << amf0_deserialize
        end
        array
      end

      def amf0_read_date
        seconds = read_double(@source).to_f/1000
        time = Time.at(seconds)
        tz = read_word16_network(@source) # Unused
        time
      end

      def amf0_read_props obj={}, key_type=:sym
        while true
          key = amf0_read_string
          type = read_int8 @source
          break if type == AMF0_OBJECT_END_MARKER
          key = key.to_sym if key_type == :sym
          obj[key] = amf0_deserialize(type)
        end
        obj
      end

      def amf0_read_hash
        len = read_word32_network(@source) # Read and ignore length
        obj = {}
        @ref_cache << obj
        amf0_read_props obj, :string
      end

      def amf0_read_object add_to_ref_cache=true
        # Create "object" and add to ref cache (it's always a Hash)
        obj = @class_mapper.get_ruby_obj ""
        @ref_cache << obj

        # Populate object
        props = amf0_read_props
        @class_mapper.populate_ruby_obj obj, props
        return obj
      end

      def amf0_read_typed_object
        # Create object to add to ref cache
        class_name = amf0_read_string
        obj = @class_mapper.get_ruby_obj class_name
        @ref_cache << obj

        # Populate object
        props = amf0_read_props
        @class_mapper.populate_ruby_obj obj, props
        return obj
      end

      def amf3_deserialize
        type = read_int8 @source
        case type
        when AMF3_UNDEFINED_MARKER
          nil
        when AMF3_NULL_MARKER
          nil
        when AMF3_FALSE_MARKER
          false
        when AMF3_TRUE_MARKER
          true
        when AMF3_INTEGER_MARKER
          amf3_read_integer
        when AMF3_DOUBLE_MARKER
          amf3_read_number
        when AMF3_STRING_MARKER
          amf3_read_string
        when AMF3_XML_DOC_MARKER, AMF3_XML_MARKER
          amf3_read_xml
        when AMF3_DATE_MARKER
          amf3_read_date
        when AMF3_ARRAY_MARKER
          amf3_read_array
        when AMF3_OBJECT_MARKER
          amf3_read_object
        when AMF3_BYTE_ARRAY_MARKER
          amf3_read_byte_array
        when AMF3_DICT_MARKER
          amf3_read_dict
        else
          raise AMFError, "Invalid type: #{type}"
        end
      end

      def amf3_read_integer
        n = 0
        b = read_word8(@source) || 0
        result = 0

        while ((b & 0x80) != 0 && n < 3)
          result = result << 7
          result = result | (b & 0x7f)
          b = read_word8(@source) || 0
          n = n + 1
        end

        if (n < 3)
          result = result << 7
          result = result | b
        else
          #Use all 8 bits from the 4th byte
          result = result << 8
          result = result | b

          #Check if the integer should be negative
          if (result > MAX_INTEGER)
            result -= (1 << 29)
          end
        end
        result
      end

      def amf3_read_number
        res = read_double @source
        (res.is_a?(Float) && res.nan?) ? nil : res # check for NaN and convert them to nil
      end

      def amf3_read_string
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0

        if is_reference
          reference = type >> 1
          return @string_cache[reference]
        else
          length = type >> 1
          str = ""
          if length > 0
            str = @source.read(length)
            str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
            @string_cache << str
          end
          return str
        end
      end

      def amf3_read_xml
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0

        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          str = ""
          if length > 0
            str = @source.read(length)
            str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
            @object_cache << str
          end
          return str
        end
      end

      def amf3_read_byte_array
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0

        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          obj = StringIO.new @source.read(length)
          @object_cache << obj
          obj
        end
      end

      def amf3_read_array
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0

        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          property_name = amf3_read_string
          array = property_name.length > 0 ? {} : []
          @object_cache << array

          while property_name.length > 0
            value = amf3_deserialize
            array[property_name] = value
            property_name = amf3_read_string
          end
          0.upto(length - 1) {|i| array[i] = amf3_deserialize }

          array
        end
      end

      def amf3_read_object
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0

        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          class_type = type >> 1
          class_is_reference = (class_type & 0x01) == 0

          if class_is_reference
            reference = class_type >> 1
            traits = @trait_cache[reference]
          else
            externalizable = (class_type & 0x02) != 0
            dynamic = (class_type & 0x04) != 0
            attribute_count = class_type >> 3
            class_name = amf3_read_string

            class_attributes = []
            attribute_count.times{class_attributes << amf3_read_string} # Read class members

            traits = {
                      :class_name => class_name,
                      :members => class_attributes,
                      :externalizable => externalizable,
                      :dynamic => dynamic
                     }
            @trait_cache << traits
          end

          # Optimization for deserializing ArrayCollection
          if traits[:class_name] == "flex.messaging.io.ArrayCollection"
            arr = amf3_deserialize # Adds ArrayCollection array to object cache
            @object_cache << arr # Add again for ArrayCollection source array
            return arr
          end

          obj = @class_mapper.get_ruby_obj traits[:class_name]
          @object_cache << obj

          if traits[:externalizable]
            obj.read_external self
          else
            props = {}
            traits[:members].each do |key|
              value = amf3_deserialize
              props[key.to_sym] = value
            end

            dynamic_props = nil
            if traits[:dynamic]
              dynamic_props = {}
              while (key = amf3_read_string) && key.length != 0  do # read next key
                value = amf3_deserialize
                dynamic_props[key.to_sym] = value
              end
            end

            @class_mapper.populate_ruby_obj obj, props, dynamic_props
          end
          obj
        end
      end

      def amf3_read_date
        type = amf3_read_integer
        is_reference = (type & 0x01) == 0
        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          seconds = read_double(@source).to_f/1000
          time = Time.at(seconds)
          @object_cache << time
          time
        end
      end

      def amf3_read_dict
        type = amf3_read_integer
        # Currently duplicate dictionaries send false, but I'll leave this in here just in case
        is_reference = (type & 0x01) == 0
        if is_reference
          reference = type >> 1
          return @object_cache[reference]
        else
          dict = {}
          @object_cache << dict
          length = type >> 1
          skip = amf3_read_integer # TODO: Handle when specs are updated
          0.upto(length - 1) do |i|
            dict[amf3_deserialize] = amf3_deserialize
          end
          dict
        end
      end
    end
  end
end