require 'thread'

require 'concurrent/obligation'
require 'concurrent/options_parser'

module Concurrent

  # {include:file:doc/promise.md}
  class Promise
    # TODO unify promise and future to single class, with dataflow
    include Obligation

    # Initialize a new Promise with the provided options.
    #
    # @param [Hash] opts the options used to define the behavior at update and deref
    #
    # @option opts [Promise] :parent the parent `Promise` when building a chain/tree
    # @option opts [Proc] :on_fulfill fulfillment handler
    # @option opts [Proc] :on_reject rejection handler
    #
    # @option opts [Boolean] :operation (false) when `true` will execute the future on the global
    #   operation pool (for long-running operations), when `false` will execute the future on the
    #   global task pool (for short-running tasks)
    # @option opts [object] :executor when provided will run all operations on
    #   this executor rather than the global thread pool (overrides :operation)
    #
    # @option opts [String] :dup_on_deref (false) call `#dup` before returning the data
    # @option opts [String] :freeze_on_deref (false) call `#freeze` before returning the data
    # @option opts [String] :copy_on_deref (nil) call the given `Proc` passing the internal value and
    #   returning the value returned from the proc
    #
    # @see http://wiki.commonjs.org/wiki/Promises/A
    # @see http://promises-aplus.github.io/promises-spec/
    def initialize(opts = {}, &block)
      opts.delete_if { |k, v| v.nil? }

      @executor = OptionsParser::get_executor_from(opts) || Concurrent.configuration.global_operation_pool
      @parent = opts.fetch(:parent) { nil }
      @on_fulfill = opts.fetch(:on_fulfill) { Proc.new { |result| result } }
      @on_reject = opts.fetch(:on_reject) { Proc.new { |reason| raise reason } }

      @promise_body = block || Proc.new { |result| result }
      @state = :unscheduled
      @children = []

      init_obligation
    end

    # @return [Promise]
    def self.fulfill(value, opts = {})
      Promise.new(opts).tap { |p| p.send(:synchronized_set_state!, true, value, nil) }
    end


    # @return [Promise]
    def self.reject(reason, opts = {})
      Promise.new(opts).tap { |p| p.send(:synchronized_set_state!, false, nil, reason) }
    end

    # @return [Promise]
    # @since 0.5.0
    def execute
      if root?
        if compare_and_set_state(:pending, :unscheduled)
          set_pending
          realize(@promise_body)
        end
      else
        @parent.execute
      end
      self
    end

    # @since 0.5.0
    def self.execute(opts = {}, &block)
      new(opts, &block).execute
    end

    # @return [Promise] the new promise
    def then(rescuer = nil, &block)
      raise ArgumentError.new('rescuers and block are both missing') if rescuer.nil? && !block_given?
      block = Proc.new { |result| result } if block.nil?
      child = Promise.new(
        parent: self,
        executor: @executor,
        on_fulfill: block,
        on_reject: rescuer
      )

      mutex.synchronize do
        child.state = :pending if @state == :pending
        child.on_fulfill(apply_deref_options(@value)) if @state == :fulfilled
        child.on_reject(@reason) if @state == :rejected
        @children << child
      end

      child
    end

    # @return [Promise]
    def on_success(&block)
      raise ArgumentError.new('no block given') unless block_given?
      self.then &block
    end

    # @return [Promise]
    def rescue(&block)
      self.then(block)
    end

    alias_method :catch, :rescue
    alias_method :on_error, :rescue

    # Yield the successful result to the block that returns a promise. If that
    # promise is also successful the result is the result of the yielded promise.
    # If either part fails the whole also fails.
    #
    # @example
    #   Promise.execute { 1 }.flat_map { |v| Promise.execute { v + 2 } }.value! #=> 3
    #
    # @return [Promise]
    def flat_map(&block)
      child = Promise.new(
        parent: self,
        executor: ImmediateExecutor.new,
      )

      on_error { |e| child.on_reject(e) }
      on_success do |result1|
        begin
          inner = block.call(result1)
          inner.execute
          inner.on_success { |result2| child.on_fulfill(result2) }
          inner.on_error { |e| child.on_reject(e) }
        rescue => e
          child.on_reject(e)
        end
      end

      child
    end

    # Builds a promise that produces the result of promises in an Array
    # and fails if any of them fails.
    #
    # @param [Array<Promise>] promises
    #
    # @return [Promise<Array>]
    def self.zip(*promises)
      zero = fulfill([], executor: ImmediateExecutor.new)

      promises.reduce(zero) do |p1, p2|
        p1.flat_map do |results|
          p2.then do |next_result|
            results << next_result
          end
        end
      end
    end

    # Builds a promise that produces the result of self and others in an Array
    # and fails if any of them fails.
    #
    # @param [Array<Promise>] others
    #
    # @return [Promise<Array>]
    def zip(*others)
      self.class.zip(self, *others)
    end

    protected

    def set_pending
      mutex.synchronize do
        @state = :pending
        @children.each { |c| c.set_pending }
      end
    end

    # @!visibility private
    def root? # :nodoc:
      @parent.nil?
    end

    # @!visibility private
    def on_fulfill(result)
      realize Proc.new { @on_fulfill.call(result) }
      nil
    end

    # @!visibility private
    def on_reject(reason)
      realize Proc.new { @on_reject.call(reason) }
      nil
    end

    def notify_child(child)
      if_state(:fulfilled) { child.on_fulfill(apply_deref_options(@value)) }
      if_state(:rejected) { child.on_reject(@reason) }
    end

    # @!visibility private
    def realize(task)
      @executor.post do
        success, value, reason = SafeTaskExecutor.new(task).execute

        children_to_notify = mutex.synchronize do
          set_state!(success, value, reason)
          @children.dup
        end

        children_to_notify.each { |child| notify_child(child) }
      end
    end

    def set_state!(success, value, reason)
      set_state(success, value, reason)
      event.set
    end

    def synchronized_set_state!(success, value, reason)
      mutex.lock
      set_state!(success, value, reason)
    ensure
      mutex.unlock
    end
  end
end
