require 'digest'
require 'sidekiq_unique_jobs/connectors'

REQUIRE_FILES = lambda do
  if SidekiqUniqueJobs.config.testing_enabled?# && Sidekiq::Testing.fake? # modded to require test_overrides for inline! mode as well
    require 'sidekiq_unique_jobs/sidekiq_test_overrides'
  end
end

module SidekiqUniqueJobs
  module Middleware
    module Client
      module Strategies
        class Unique
          def self.elegible?
            true
          end

          def self.review(worker_class, item, queue, redis_pool = nil, log_duplicate_payload = false)
            new(worker_class, item, queue, redis_pool, log_duplicate_payload).review do
              yield
            end
          end

          def initialize(worker_class, item, queue, redis_pool = nil, log_duplicate_payload = false)
            @worker_class = SidekiqUniqueJobs.worker_class_constantize(worker_class)
            @item = item
            @queue = queue
            @redis_pool = redis_pool
            @log_duplicate_payload = log_duplicate_payload
            REQUIRE_FILES.call
          end

          def review
            item['unique_hash'] = payload_hash

            unless unique_for_connection?
              Sidekiq.logger.warn "payload is not unique #{item}" if @log_duplicate_payload
              return
            end

            yield
          end

          private

          attr_reader :item, :worker_class, :redis_pool, :queue, :log_duplicate_payload

          def unique_for_connection?
            send("#{storage_method}_unique_for?")
          end

          def storage_method
            SidekiqUniqueJobs.config.unique_storage_method
          end

          def old_unique_for?
            unique = nil
            connection do |conn|
              conn.watch(payload_hash)

              unique_key = conn.get(payload_hash)

              if unique_key.nil? || unique_key == item['jid']
                expires_at = unique_job_expiration || SidekiqUniqueJobs.config.default_expiration
                expires_at = ((Time.at(item['at']) - Time.now.utc) + expires_at).to_i if item['at']


                unique = conn.multi do
                  conn.setex(payload_hash, expires_at, item['jid'])
                end
              else
                conn.unwatch
              end
            end

            unique
          end

          def new_unique_for?
            connection do |conn|
              return conn.set(payload_hash, item['jid'], nx: true, ex: expires_at) || conn.get(payload_hash) == item['jid']
            end
          end

          def expires_at
            # if the job was previously scheduled and is now being queued,
            # or we've never seen it before
            ex = unique_job_expiration || SidekiqUniqueJobs.config.default_expiration
            ex = ((Time.at(item['at']) - Time.now.utc) + ex).to_i if item['at']
            ex
          end

          def connection(&block)
            SidekiqUniqueJobs::Connectors.connection(redis_pool, &block)
          end

          def payload_hash
            SidekiqUniqueJobs::PayloadHelper.get_payload(item['class'], item['queue'], item['args'])
          end

          def unique_job_expiration
            worker_class.get_sidekiq_options['unique_job_expiration']
          end
        end
      end
    end
  end
end
