#!/usr/bin/env ruby

# This class encapsulates the config data and environmental setup used
# by the various Flapjack components.
#
# "In Australia and New Zealand, small pancakes (about 75 mm in diameter) known as pikelets
# are also eaten. They are traditionally served with jam and/or whipped cream, or solely
# with butter, at afternoon tea, but can also be served at morning tea."
#    from http://en.wikipedia.org/wiki/Pancake

require 'log4r/outputter/consoleoutputters'
require 'log4r/outputter/syslogoutputter'

module Flapjack
  module Pikelet
    attr_accessor :bootstrapped, :persistence, :logger, :config, :should_stop

    def bootstrapped?
      !!@bootstrapped
    end

    def stop
      @should_stop = true
    end

    def bootstrap(opts = {})
      return if bootstrapped?

      defaults = {
        :redis => {
          :db => 0
        }
      }
      options = defaults.merge(opts)
      @persistence = ::Redis.new(options[:redis])

      unless @logger = options[:logger]
        @logger = Log4r::Logger.new("flapjack")
        @logger.add(Log4r::StdoutOutputter.new("flapjack"))
        @logger.add(Log4r::SyslogOutputter.new("flapjack"))
      end

      @config = options[:config] || {}

      @should_stop = false

      @bootstrapped = true
    end

  end
end
