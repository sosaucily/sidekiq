module Sidekiq

  class Testing
    class << self
      attr_accessor :__test_mode

      def __set_test_mode(mode, &block)
        if block
          current_mode = self.__test_mode
          begin
            self.__test_mode = mode
            block.call
          ensure
            self.__test_mode = current_mode
          end
        else
          self.__test_mode = mode
        end
      end

      def disable!(&block)
        __set_test_mode(:disable, &block)
      end

      def fake!(&block)
        __set_test_mode(:fake, &block)
      end

      def inline!(&block)
        __set_test_mode(:inline, &block)
      end

      def enabled?
        self.__test_mode != :disable
      end

      def disabled?
        self.__test_mode == :disable
      end

      def fake?
        self.__test_mode == :fake
      end

      def inline?
        self.__test_mode == :inline
      end
    end
  end

  # Default to fake testing to keep old behavior
  Sidekiq::Testing.fake!

  class EmptyQueueError < RuntimeError; end

  class Client
    class << self
      alias_method :raw_push_real, :raw_push

      def raw_push(payloads)
        if Sidekiq::Testing.fake?
          payloads.each do |job|
            job['class'].constantize.jobs << Sidekiq.load_json(Sidekiq.dump_json(job))
          end
          true
        elsif Sidekiq::Testing.inline?
          payloads.each do |item|
            marshalled = Sidekiq.load_json(Sidekiq.dump_json(item))
            marshalled['class'].constantize.new.perform(*marshalled['args'])
          end
          true
        else
          raw_push_real(payloads)
        end
      end
    end
  end

  module Worker
    ##
    # The Sidekiq testing infrastructure overrides perform_async
    # so that it does not actually touch the network.  Instead it
    # stores the asynchronous jobs in a per-class array so that
    # their presence/absence can be asserted by your tests.
    #
    # This is similar to ActionMailer's :test delivery_method and its
    # ActionMailer::Base.deliveries array.
    #
    # Example:
    #
    #   require 'sidekiq/testing'
    #
    #   assert_equal 0, HardWorker.jobs.size
    #   HardWorker.perform_async(:something)
    #   assert_equal 1, HardWorker.jobs.size
    #   assert_equal :something, HardWorker.jobs[0]['args'][0]
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   MyMailer.delay.send_welcome_email('foo@example.com')
    #   assert_equal 1, Sidekiq::Extensions::DelayedMailer.jobs.size
    #
    # You can also clear and drain all workers' jobs:
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 0, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    #   MyMailer.delay.send_welcome_email('foo@example.com')
    #   MyModel.delay.do_something_hard
    #
    #   assert_equal 1, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 1, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    #   Sidekiq::Worker.clear_all # or .drain_all
    #
    #   assert_equal 0, Sidekiq::Extensions::DelayedMailer.jobs.size
    #   assert_equal 0, Sidekiq::Extensions::DelayedModel.jobs.size
    #
    # This can be useful to make sure jobs don't linger between tests:
    #
    #   RSpec.configure do |config|
    #     config.before(:each) do
    #       Sidekiq::Worker.clear_all
    #     end
    #   end
    #
    # or for acceptance testing, i.e. with cucumber:
    #
    #   AfterStep do
    #     Sidekiq::Worker.drain_all
    #   end
    #
    #   When I sign up as "foo@example.com"
    #   Then I should receive a welcome email to "foo@example.com"
    #
    module ClassMethods

      # Jobs queued for this worker
      def jobs
        Worker.jobs[self]
      end

      # Clear all jobs for this worker
      def clear
        jobs.clear
      end

      # Drain and run all jobs for this worker
      def drain
        while job = jobs.shift do
          worker = new
          worker.jid = job['jid']
          worker.perform(*job['args'])
        end
      end

      # Pop out a single job and perform it
      def perform_one
        raise(EmptyQueueError, "perform_one called with empty job queue") if jobs.empty?
        job = jobs.shift
        worker = new
        worker.jid = job['jid']
        worker.perform(*job['args'])
      end
    end

    class << self
      def jobs # :nodoc:
        @jobs ||= Hash.new { |hash, key| hash[key] = [] }
      end

      # Clear all queued jobs across all workers
      def clear_all
        jobs.clear
      end

      # Drain all queued jobs across all workers
      def drain_all
        until jobs.values.all?(&:empty?) do
          jobs.keys.each(&:drain)
        end
      end
    end
  end

  module SpecHelpers
    def self.delayed_a_job_for(method, delay_time = nil)
      matched_job = Sidekiq::Extensions::DelayedMailer.jobs.find do |job|
        delayed_method_string = job['args'][0]
        !delayed_method_string.match(":" + method + '\n').nil?
      end

      unless matched_job
        return false
      end

      time_matched = true
      if matched_job && delay_time
        planned_run_time = matched_job['at']
        enqueued_at = matched_job['enqueued_at']

        return false if planned_run_time.nil? || enqueued_at.nil?

        time_matched = Time.at(planned_run_time).to_i == (Time.at(enqueued_at) + delay_time).to_i
      end
      
      return time_matched
    end
  end
end
