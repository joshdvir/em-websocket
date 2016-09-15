# encoding: BINARY

module EventMachine
  module WebSocket
    module MessageProcessor03
      def message(message_type, extension_data, message)
        case message_type
        when :close
          @close_info = {
            :code => 1005,
            :reason => "",
            :was_clean => true,
          }
          if @state == :closing
            # TODO: Check that message body matches sent data
            # We can close connection immediately since there is no more data
            # is allowed to be sent or received on this connection
            @connection.close_connection
          else
            # Acknowlege close
            # The connection is considered closed
            send_frame(:close, message.data)
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
