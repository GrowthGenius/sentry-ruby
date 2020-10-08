require "json"
require "base64"
require "sentry/transports"
require "sentry/client/state"
require 'sentry/utils/deep_merge'

module Sentry
  class Client
    PROTOCOL_VERSION = '5'
    USER_AGENT = "sentry-ruby/#{Sentry::VERSION}"
    CONTENT_TYPE = 'application/json'

    attr_reader :transport, :configuration

    def initialize(configuration)
      @configuration = configuration
      @state = State.new
      @transport = case configuration.scheme
        when 'http', 'https'
          Transports::HTTP.new(configuration)
        when 'stdout'
          Transports::Stdout.new(configuration)
        when 'dummy'
          Transports::Dummy.new(configuration)
        else
          fail "Unknown transport scheme '#{configuration.scheme}'"
        end
    end

    def capture_exception(exception, scope:, **options, &block)
      event = event_from_exception(exception, **options)
      block.call(event) if block
      capture_event(event, scope)
    end

    def capture_message(message, scope:, **options, &block)
      event = event_from_message(message, **options)
      block.call(event) if block
      capture_event(event, scope)
    end

    def capture_event(event, scope)
      scope.apply_to_event(event)
      send_event(event)
      event
    end

    def event_from_exception(exception, **options)
      exception_context =
        if exception.instance_variable_defined?(:@__sentry_context)
          exception.instance_variable_get(:@__sentry_context)
        elsif exception.respond_to?(:sentry_context)
          exception.sentry_context
        else
          {}
        end

      options = Utils::DeepMergeHash.deep_merge(exception_context, options)

      return unless @configuration.exception_class_allowed?(exception)

      options = Event::Options.new(**options)

      Event.new(configuration: configuration, options: options) do |evt|
        evt.add_exception_interface(exception)
      end
    end

    def event_from_message(message, **options)
      options.merge!(message: message)
      options = Event::Options.new(options)
      Event.new(configuration: configuration, options: options)
    end

    def generate_auth_header
      now = Time.now.to_i.to_s
      fields = {
        'sentry_version' => PROTOCOL_VERSION,
        'sentry_client' => USER_AGENT,
        'sentry_timestamp' => now,
        'sentry_key' => configuration.public_key
      }
      fields['sentry_secret'] = configuration.secret_key unless configuration.secret_key.nil?
      'Sentry ' + fields.map { |key, value| "#{key}=#{value}" }.join(', ')
    end

    def send_event(event, hint = nil)
      return false unless configuration.sending_allowed?(event)

      event = configuration.before_send.call(event, hint) if configuration.before_send
      if event.nil?
        configuration.logger.info "Discarded event because before_send returned nil"
        return
      end

      # Convert to hash
      event_hash = event.to_hash

      unless @state.should_try?
        failed_send(nil, event_hash)
        return
      end

      event_id = event_hash[:event_id] || event_hash['event_id']
      configuration.logger.info "Sending event #{event_id} to Sentry"

      content_type, encoded_data = encode(event_hash)

      begin
        if configuration.async?
          begin
            # We have to convert to a JSON-like hash, because background job
            # processors (esp ActiveJob) may not like weird types in the event hash
            configuration.async.call(event.to_json_compatible)
          rescue => e
            configuration.logger.error("async event sending failed: #{e.message}")
            transport.send_event(generate_auth_header, encoded_data, content_type: content_type)
          end
        else
          transport.send_event(generate_auth_header, encoded_data, content_type: content_type)
        end

        successful_send
      rescue => e
        failed_send(e, event_hash)
        return
      end

      event
    end

    private

    def encode(event)
      encoded = JSON.fast_generate(event.to_hash)

      case configuration.encoding
      when 'gzip'
        ['application/octet-stream', Base64.strict_encode64(Zlib::Deflate.deflate(encoded))]
      else
        ['application/json', encoded]
      end
    end

    def successful_send
      @state.success
    end

    def failed_send(e, event)
      if e # exception was raised
        @state.failure
        configuration.logger.warn "Unable to record event with remote Sentry server (#{e.class} - #{e.message}):\n#{e.backtrace[0..10].join("\n")}"
      else
        configuration.logger.warn "Not sending event due to previous failure(s)."
      end
      configuration.logger.warn("Failed to submit event: #{get_log_message(event)}")
    end

    def get_log_message(event)
      (event && event[:message]) || (event && event['message']) || get_message_from_exception(event) || '<no message value>'
    end

    def get_message_from_exception(event)
      (
        event &&
        event[:exception] &&
        event[:exception][:values] &&
        event[:exception][:values][0] &&
        event[:exception][:values][0][:type] &&
        event[:exception][:values][0][:value] &&
        "#{event[:exception][:values][0][:type]}: #{event[:exception][:values][0][:value]}"
      )
    end
  end
end