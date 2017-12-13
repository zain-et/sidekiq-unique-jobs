require 'sidekiq/testing'

module Sidekiq
  module Worker
    module ClassMethods
      module Overrides
        def self.included(base)
          override_methods(base) unless base.method_defined?(:execute_job)

          base.class_eval do
            alias_method :execute_job_orig, :execute_job
            alias_method :execute_job, :execute_job_ext

            alias_method :clear_orig, :clear
            alias_method :clear, :clear_ext
          end
        end

        # Patch - unlock jobs before or after they're executed based on unlock_order then call after_unlock
        def execute_job_ext(worker, args)
          unlock_order =
            if worker.class.respond_to?(:get_sidekiq_options) && !worker.class.get_sidekiq_options['unique_unlock_order'].nil?
              worker.class.get_sidekiq_options['unique_unlock_order']
            else
              SidekiqUniqueJobs.config.default_unlock_order
            end

          payload_hash = SidekiqUniqueJobs::PayloadHelper.get_payload(worker.class.name, get_sidekiq_options['queue'], args)

          if unlock_order == :before_yield
            SidekiqUniqueJobs::Connectors.connection { |conn| conn.del(payload_hash) }
          end

          execute_job_orig(worker, args)

          if unlock_order == :after_yield
            SidekiqUniqueJobs::Connectors.connection { |conn| conn.del(payload_hash) }
          end

          if Sidekiq::Testing.inline?
            if worker.respond_to?(:after_unlock)
              worker.after_unlock
            end
          end
        end

        def clear_ext
          payload_hashes = jobs.map { |job| job['unique_hash'] }
          clear_orig
          return if payload_hashes.empty?

          Sidekiq.redis { |conn| conn.del(*payload_hashes) }
        end

        # Disable rubocop because methods are lifted directly out of Sidekiq
        # rubocop:disable all
        def override_methods(base)
          base.class_eval do
            define_method(:drain) do
              while job = jobs.shift do
                worker = new
                worker.jid = job['jid']
                execute_job(worker, job['args'])
              end
            end

            define_method(:perform_one) do
              raise(EmptyQueueError, "perform_one called with empty job queue") if jobs.empty?
              job = jobs.shift
              worker = new
              worker.jid = job['jid']
              execute_job(worker, job['args'])
            end

            define_method(:execute_job) do |worker, args|
              worker.perform(*args)
            end
          end
        end
        # rubocop:enable all

        module_function :override_methods
        private_class_method :override_methods
      end

      include Overrides
    end
  end
end

module Sidekiq
  module Worker
    module Overrides
      def self.included(base)
        base.extend ClassMethods

        base.class_eval do
          class << self
            alias_method :clear_all_orig, :clear_all
            alias_method :clear_all, :clear_all_ext
          end
        end
      end

      module ClassMethods
        def clear_all_ext
          clear_all_orig
          unique_prefix = SidekiqUniqueJobs.config.unique_prefix
          unique_keys = Sidekiq.redis { |conn| conn.keys("#{unique_prefix}*") }
          return if unique_keys.empty?

          Sidekiq.redis { |conn| conn.del(*unique_keys) }
        end
      end
    end

    include Overrides
  end
end
