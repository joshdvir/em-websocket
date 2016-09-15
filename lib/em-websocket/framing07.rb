# encoding: BINARY

module EventMachine
  module WebSocket
    module Framing07

      def initialize_framing
        @data = MaskedString.new
        @application_data_buffer = '' # Used for MORE frames
        @frame_type = nil
      end

      def process_data
        frame = Frame.new
        error = false

        while !error && @data.size >= 2
          pointer = 0

          frame.final = (@data.getbyte(pointer) & 0b10000000) == 0b10000000
          frame.rsv1 = (@data.getbyte(pointer) & 0b01000000) == 0b01000000
          frame.rsv2 = (@data.getbyte(pointer) & 0b00100000) == 0b00100000
          frame.rsv3 = (@data.getbyte(pointer) & 0b00010000) == 0b00010000
          frame.opcode = @data.getbyte(pointer) & 0b00001111
          pointer += 1

          unless @connection.extensions.valid_frame_rsv(frame)
            raise WSProtocolError, "Invalid RSV bits set"
          end

          mask = (@data.getbyte(pointer) & 0b10000000) == 0b10000000
          length = @data.getbyte(pointer) & 0b01111111
          pointer += 1

          # raise WebSocketError, 'Data from client must be masked' unless mask

          payload_length = case length
          when 127 # Length defined by 8 bytes
            # Check buffer size
            if @data.getbyte(pointer+8-1) == nil
              debug [:buffer_incomplete, @data]
              error = true
              next
            end

            # Only using the last 4 bytes for now, till I work out how to
            # unpack 8 bytes. I'm sure 4GB frames will do for now :)
            l = @data.getbytes(pointer+4, 4).unpack('N').first
            pointer += 8
            l
          when 126 # Length defined by 2 bytes
            # Check buffer size
            if @data.getbyte(pointer+2-1) == nil
              debug [:buffer_incomplete, @data]
              error = true
              next
            end

            l = @data.getbytes(pointer, 2).unpack('n').first
            pointer += 2
            l
          else
            length
          end

          # Compute the expected frame length
          frame_length = pointer + payload_length
          frame_length += 4 if mask

          if frame_length > @connection.max_frame_size
            raise WSMessageTooBigError, "Frame length too long (#{frame_length} bytes)"
          end

          # Check buffer size
          if @data.getbyte(frame_length - 1) == nil
            debug [:buffer_incomplete, @data]
            error = true
            next
          end

          # Remove frame header
          @data.slice!(0...pointer)
          pointer = 0

          # Read application data (unmasked if required)
          @data.read_mask if mask
          pointer += 4 if mask
          application_data = @data.getbytes(pointer, payload_length)
          pointer += payload_length
          @data.unset_mask if mask

          # Throw away data up to pointer
          @data.slice!(0...pointer)

          frame_type = opcode_to_type(frame.opcode)

          if frame_type == :continuation
            if !@frame_type
              raise WSProtocolError, 'Continuation frame not expected'
            end
          else # Not a continuation frame
            if @frame_type && data_frame?(frame_type)
              raise WSProtocolError, "Continuation frame expected"
            end
          end

          # Validate that control frames are not fragmented
          if !frame.final && !data_frame?(frame_type)
            raise WSProtocolError, 'Control frames must not be fragmented'
          end

          if !frame.final
            debug [:moreframe, frame_type, application_data]
            @application_data_buffer << application_data
            # The message type is passed in the first frame
            @frame_type ||= frame_type
          else
            # Message is complete
            msg = Message.new
            msg.rsv1 = frame.rsv1
            msg.rsv2 = frame.rsv2
            msg.rsv3 = frame.rsv3
            msg.opcode = frame.opcode
            if frame_type == :continuation
              @application_data_buffer << application_data
              msg.data = @application_data_buffer
              message(@frame_type, '', msg)
              @application_data_buffer = ''
              @frame_type = nil
            else
              msg.data = application_data
              message(frame_type, '', msg)
            end
          end
        end # end while
      end

      def send_frame(frame_type, application_data)
        debug [:sending_frame, frame_type, application_data]

        message = Message.new
        message.opcode = type_to_opcode(frame_type)
        message.data = application_data
        message = @connection.extensions.process_outgoing_message(message)

        if @state == :closing && data_frame?(frame_type)
          raise WebSocketError, "Cannot send data frame since connection is closing"
        end

        frame = ''

        opcode = type_to_opcode(frame_type)
        byte1 = opcode | 0b10000000 | (message.rsv1 ? 0b01000000 : 0) |
                                      (message.rsv2 ? 0b00100000 : 0) |
                                      (message.rsv3 ? 0b00010000 : 0)
        frame << byte1

        length = message.data.size
        if length <= 125
          byte2 = length # since rsv4 is 0
          frame << byte2
        elsif length < 65536 # write 2 byte length
          frame << 126
          frame << [length].pack('n')
        else # write 8 byte length
          frame << 127
          frame << [length >> 32, length & 0xFFFFFFFF].pack("NN")
        end

        frame << message.data

        @connection.send_data(frame)
      end

      def send_text_frame(data)
        send_frame(:text, data)
      end

      private

      FRAME_TYPES = {
        :continuation => 0,
        :text => 1,
        :binary => 2,
        :close => 8,
        :ping => 9,
        :pong => 10,
      }
      FRAME_TYPES_INVERSE = FRAME_TYPES.invert
      # Frames are either data frames or control frames
      DATA_FRAMES = [:text, :binary, :continuation]

      def type_to_opcode(frame_type)
        FRAME_TYPES[frame_type] || raise("Unknown frame type")
      end

      def opcode_to_type(opcode)
        FRAME_TYPES_INVERSE[opcode] || raise(WSProtocolError, "Unknown opcode #{opcode}")
      end

      def data_frame?(type)
        DATA_FRAMES.include?(type)
      end
    end
  end
end
