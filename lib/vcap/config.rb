require 'cloud_controller/yaml_config'
require 'yaml'
require 'membrane'
require 'active_support'
require 'active_support/core_ext'

module VCAP
  class Config
    module Dsl
      class << self
        def omit_on_k8s(config, **schema_section)
          return {} if config.key?(:kubernetes)

          schema_section.each.with_object({}) do |(key, schema), result|
            result[key] = schema
          end
        end
      end
    end

    class << self
      attr_reader :schema_block

      def define_schema(&blk)
        @schema_block = blk
      end

      def schema(config_hash)
        blk = schema_block
        Membrane::SchemaParser.parse { instance_eval blk.call(config_hash) }
      end

      def from_file(filename, secrets_hash: {})
        config = VCAP::CloudController::YAMLConfig.safe_load_file(filename)
        config = deep_symbolize_keys_except_in_arrays(config)
        secrets_hash = deep_symbolize_keys_except_in_arrays(secrets_hash)

        config = config.deep_merge(secrets_hash)
        schema(config).validate(config)

        config
      end

      private

      def deep_symbolize_keys_except_in_arrays(hash)
        return hash unless hash.is_a? Hash

        hash.each.with_object({}) do |(k, v), new_hash|
          new_hash[k.to_sym] = deep_symbolize_keys_except_in_arrays(v)
        end
      end
    end
  end
end
