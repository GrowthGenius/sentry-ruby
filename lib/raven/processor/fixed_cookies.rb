# frozen_string_literal: true

# From: https://github.com/getsentry/raven-ruby/pull/904
# See also: https://github.com/getsentry/raven-ruby/issues/900

module Raven
  class Processor
    class FixedCookies < ::Raven::Processor
      def process(data)
        process_if_symbol_keys(data) if data[:request]
        process_if_string_keys(data) if data['request']

        data
      end

      private

      def process_if_symbol_keys(data)
        data[:request][:cookies] = data[:request][:cookies].merge(data[:request][:cookies]) { |_key, _val| STRING_MASK } if data[:request][:cookies]

        return unless data[:request][:headers] && data[:request][:headers]['Cookie']

        data[:request][:headers]['Cookie'] = STRING_MASK
      end

      def process_if_string_keys(data)
        data['request']['cookies'] = data['request']['cookies'].merge(data['request']['cookies']) { |_key, _val| STRING_MASK } if data['request']['cookies']

        return unless data['request']['headers'] && data['request']['headers']['Cookie']

        data['request']['headers']['Cookie'] = STRING_MASK
      end
    end
  end
end