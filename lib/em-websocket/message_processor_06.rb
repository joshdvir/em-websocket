module EventMachine
  module WebSocket
    module MessageProcessor06
      def message(message_type, extension_data, message)
        debug [:message_received, message_type, message]

        case message_type
        when :close
          status_code = case message.data.length
          when 0
            # close messages MAY contain a body
            nil
          when 1
            # Illegal close frame
            raise WSProtocolError, "Close frames with a body must contain a 2 byte status code"
          else
            message.data.slice!(0, 2).unpack('n').first
          end

          debug [:close_frame_received, status_code, message.data]

          @close_info = {
            :code => status_code || 1005,
            :reason => message.data,
            :was_clean => true,
          }

          if @state == :closing
            # We can close connection immediately since no more data may be
            # sent or received on this connection
            @connection.close_connection
          elsif @state == :connected
            # Acknowlege close & echo status back to client
            # The connection is considered closed
            close_data = [status_code || 1000].pack('n')
            send_frame(:close, close_data)
            @connection.close_connection_after_writing
          end
        when :ping
          # Pong back the same data
          send_frame(:pong, message.data)
          @connection.trigger_on_ping(message.data)
        when :pong
          @connection.trigger_on_pong(message.data)
        when :text
          message = @connection.extensions.process_incoming_message(message)
          if message.data.respond_to?(:force_encoding)
            message.data.force_encoding("UTF-8")
            unless message.data.valid_encoding?
              raise InvalidDataError, "Invalid UTF8 data"
            end
          end
          @connection.trigger_on_message(message.data)
        when :binary
          message = @connection.extensions.process_incoming_message(message)
          @connection.trigger_on_binary(message.data)
        end
      end

      # Ping & Pong supported
      def pingable?
        true
      end
    end
  end
end
