#!/usr/bin/env ruby

require 'chronic_duration'

require 'flapjack/redis_proxy'

require 'flapjack/filters/acknowledgement'
require 'flapjack/filters/ok'
require 'flapjack/filters/scheduled_maintenance'
require 'flapjack/filters/unscheduled_maintenance'
require 'flapjack/filters/delays'

require 'flapjack/data/check'
require 'flapjack/data/notification'
require 'flapjack/data/event'
require 'flapjack/exceptions'
require 'flapjack/utility'

module Flapjack

  class Processor

    include Flapjack::Utility

    def initialize(opts = {})
      @lock = opts[:lock]

      @config = opts[:config]
      @logger = opts[:logger]

      @boot_time    = opts[:boot_time]

      @queue = @config['queue'] || 'events'

      @notifier_queue = @config['notifier_queue'] || 'notifications'

      @archive_events        = @config['archive_events'] || false
      @events_archive_maxage = @config['events_archive_maxage']

      ncsm_duration_conf = @config['new_check_scheduled_maintenance_duration'] || '100 years'
      @ncsm_duration = ChronicDuration.parse(ncsm_duration_conf)

      @exit_on_queue_empty = !! @config['exit_on_queue_empty']

      filter_opts = {:logger => opts[:logger]}

      @filters = [Flapjack::Filters::Ok.new(filter_opts),
                  Flapjack::Filters::ScheduledMaintenance.new(filter_opts),
                  Flapjack::Filters::UnscheduledMaintenance.new(filter_opts),
                  Flapjack::Filters::Delays.new(filter_opts),
                  Flapjack::Filters::Acknowledgement.new(filter_opts)]

      fqdn          = `/bin/hostname -f`.chomp
      pid           = Process.pid
      @instance_id  = "#{fqdn}:#{pid}"
    end

    # expire instance keys after one week
    # TODO: set up a separate timer to reset key expiry every minute
    # and reduce the expiry to, say, five minutes
    # TODO: remove these keys on process exit
    def touch_keys
      Flapjack.redis.expire("executive_instance:#{@instance_id}", 1036800)
      Flapjack.redis.expire("event_counters:#{@instance_id}", 1036800)
    end

    def start
      @logger.info("Booting main loop.")

      begin
        # FIXME: add an administrative function to reset all event counters
        counters = Flapjack.redis.hget('event_counters', 'all')

        Flapjack.redis.multi

        if counters.nil?
          Flapjack.redis.hmset('event_counters',
                       'all', 0, 'ok', 0, 'failure', 0, 'action', 0)
        end

        # Flapjack.redis.zadd('executive_instances', @boot_time.to_i, @instance_id)
        Flapjack.redis.hset("executive_instance:#{@instance_id}", 'boot_time', @boot_time.to_i)
        Flapjack.redis.hmset("event_counters:#{@instance_id}",
                             'all', 0, 'ok', 0, 'failure', 0, 'action', 0)
        touch_keys

        Flapjack.redis.exec

        parse_json_proc = Proc.new {|event_json|
          begin
            Flapjack::Data::Event.new( ::Oj.load( event_json ) )
          rescue Oj::Error => e
            @logger.warn("Error deserialising event json: #{e}, raw json: #{event_json.inspect}")
            nil
          end
        }

        loop do
          @lock.synchronize do
            foreach_on_queue(:archive_events => @archive_events,
                             :events_archive_maxage => @events_archive_maxage) do |event_json|
              event = parse_json_proc.call(event_json)
              process_event(event) if event
            end
          end

          raise Flapjack::GlobalStop if @config['exit_on_queue_empty']

          wait_for_queue
        end

      ensure
        Flapjack.redis.quit
      end
    end

    def stop_type
      :exception
    end

  private

    def foreach_on_queue(opts = {})
      if opts[:archive_events]
        dest = "events_archive:#{Time.now.utc.strftime "%Y%m%d%H"}"
        while event_json = Flapjack.redis.rpoplpush(@queue, dest)
          Flapjack.redis.expire(dest, opts[:events_archive_maxage])
          yield event_json
        end
      else
        while event_json = Flapjack.redis.rpop(@queue)
          yield event_json
        end
      end
    end

    def wait_for_queue
      Flapjack.redis.brpop("#{@queue}_actions")
    end

    def process_event(event)
      pending = Flapjack::Data::Event.pending_count(@queue)
      @logger.debug("#{pending} events waiting on the queue")
      @logger.debug("Raw event received: #{event.inspect}")

      event_str = "#{event.id}, #{event.type}, #{event.state}, #{event.summary}"
      event_str << ", #{Time.at(event.time).to_s}" if event.time
      @logger.debug("Processing Event: #{event_str}")

      timestamp = Time.now.to_i

      entity_name, check_name = event.id.split(':', 2);
      entity_check = Flapjack::Data::Check.intersect(:entity_name => entity_name,
        :name => check_name).all.first

      entity_for_check = nil

      if entity_check.nil?
        unless entity = Flapjack::Data::Entity.intersect(:name => entity_name).all.first
          entity = Flapjack::Data::Entity.new(:name => entity_name, :enabled => true)
          entity.save
        end

        entity_for_check = entity
        entity_check = Flapjack::Data::Check.new(:entity_name => entity_name,
          :name => check_name)

        # not saving yet as check state isn't set, requires that for validation
        # TODO maybe change that?

      end

      should_notify, previous_state = update_keys(event, entity_check, timestamp)

      entity_check.save

      if @ncsm_sched_maint
        entity_check.add_scheduled_maintenance(@ncsm_sched_maint)
        @ncsm_sched_maint = nil
      end

      unless entity_for_check.nil?
        # created a new check, so add it to the entity's check list
        entity_for_check.checks << entity_check
      end

      if !should_notify
        @logger.debug("Not generating notification for event #{event.id} because filtering was skipped")
        return
      elsif blocker = @filters.find {|filter| filter.block?(event, entity_check, previous_state) }
        @logger.debug("Not generating notification for event #{event.id} because this filter blocked: #{blocker.name}")
        return
      end

      # redis_record rework -- up to here
      @logger.info("Generating notification for event #{event_str}")
      generate_notification(event, entity_check, timestamp, previous_state)
    end

    def update_keys(event, entity_check, timestamp)
      touch_keys

      result = true
      previous_state = nil

      event.counter = Flapjack.redis.hincrby('event_counters', 'all', 1)
      Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'all', 1)

      # FIXME skip if entity_check.nil?

      # FIXME: validate that the event is sane before we ever get here
      # FIXME: create an event if there is dodgy data

      case event.type
      # Service events represent current state of checks on monitored systems
      when 'service'
        Flapjack.redis.multi
        if Flapjack::Data::CheckState.ok_states.include?( event.state )
          Flapjack.redis.hincrby('event_counters', 'ok', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'ok', 1)
        elsif Flapjack::Data::CheckState.failing_states.include?( event.state )
          Flapjack.redis.hincrby('event_counters', 'failure', 1)
          Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'failure', 1)
          # Flapjack.redis.hset('unacknowledged_failures', event.counter, event.id)
        end
        Flapjack.redis.exec

        # not available from an unsaved check
        unless entity_check.id.nil?
          previous_state = entity_check.states.last
        end

        if previous_state.nil?
          @logger.info("No previous state for event #{event.id}")

          if @ncsm_duration >= 0
            @logger.info("Setting scheduled maintenance for #{time_period_in_words(@ncsm_duration)}")

            @ncsm_sched_maint = Flapjack::Data::ScheduledMaintenance.new(:start_time => timestamp,
              :end_time => timestamp + @ncsm_duration,
              :summary => 'Automatically created for new check')
          end

          # If the service event's state is ok and there was no previous state, don't alert.
          # This stops new checks from alerting as "recovery" after they have been added.
          if Flapjack::Data::CheckState.ok_states.include?( event.state )
            @logger.debug("setting skip_filters to true because there was no previous state and event is ok")
            result = false
          end
        end

        # NB this creates a new entry in entity_check.states, through the magic
        # of callbacks
        entity_check.state       = event.state
        entity_check.summary     = event.summary
        entity_check.details     = event.details
        entity_check.count       = event.counter
        entity_check.last_update = timestamp

      # Action events represent human or automated interaction with Flapjack
      when 'action'
        # When an action event is processed, store the event.
        Flapjack.redis.multi
        # Flapjack.redis.hset(event.id + ':actions', timestamp, event.state)
        Flapjack.redis.hincrby('event_counters', 'action', 1)
        Flapjack.redis.hincrby("event_counters:#{@instance_id}", 'action', 1)

        if event.acknowledgement? && event.acknowledgement_id
          # Flapjack.redis.hdel('unacknowledged_failures', event.acknowledgement_id)
        end
        Flapjack.redis.exec
      end

      [result, previous_state]
    end

    def generate_notification(event, entity_check, timestamp, previous_state)
      max_notified_severity = entity_check.max_notified_severity_of_current_failure

      current_state = entity_check.states.last

      # TODO should probably look these up by 'timestamp', last may not be safe...
      case event.type
      when 'service'
        if Flapjack::Data::CheckState.failing_states.include?( event.state )
          entity_check.last_problem_alert = timestamp
          entity_check.save
        end

        current_state.notified = true
        current_state.last_notification_count = event.counter
        current_state.save
      when 'action'
        if event.state == 'acknowledgement'
          unsched_maint = entity_check.unscheduled_maintenances_by_start.last
          unsched_maint.notified = true
          unsched_maint.last_notification_count = event.counter
          unsched_maint.save
        end
      end

      severity = Flapjack::Data::Notification.severity_for_state(event.state,
                   max_notified_severity)

      @logger.debug("Notification is being generated for #{event.id}: " + event.inspect)

      notification = Flapjack::Data::Notification.new(
        :entity_check_id   => entity_check.id,
        :state_id          => (current_state ? current_state.id : nil),
        :state_duration    => (current_state ? (timestamp - current_state.timestamp.to_i) : nil),
        :previous_state_id => (previous_state ? previous_state.id : nil),
        :severity          => severity,
        :type              => event.notification_type,
        :time              => event.time,
        :duration          => event.duration,
        :tags              => entity_check.tags,
      )

      Flapjack::Data::Notification.push(@notifier_queue, notification)
    end

  end
end

