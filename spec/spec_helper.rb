if ENV['COVERAGE']
  require 'simplecov'
  SimpleCov.start do
    add_filter '/spec/'
  end
  SimpleCov.at_exit do
    Oj.default_options = { :mode => :compat }
    SimpleCov.result.format!
  end
end

FLAPJACK_ENV = ENV["FLAPJACK_ENV"] || 'test'
ENV['RACK_ENV'] = ENV["FLAPJACK_ENV"]

require 'bundler'
Bundler.require(:default, :test)

require 'webmock/rspec'
WebMock.disable_net_connect!

$:.unshift(File.dirname(__FILE__) + '/../lib')

require 'oj'
Oj.mimic_JSON
Oj.default_options = { :indent => 0, :mode => :strict }
require 'active_support/json'

# Requires supporting files with custom matchers and macros, etc,
# in ./support/ and its subdirectories.
Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each {|f| require f}

class MockLogger
  attr_accessor :messages, :errors

  def initialize
    @messages = []
    @errors   = []
  end

  %w(debug info warn).each do |level|
    class_eval <<-RUBY
      def #{level}(msg)
        @messages << '#{level.upcase}' + ': ' + msg
      end
    RUBY
  end

  %w(error fatal).each do |level|
    class_eval <<-ERRORS
      def #{level}(msg)
        @messages << '#{level.upcase}' + ': ' + msg
        @errors   << '#{level.upcase}' + ': ' + msg
      end
    ERRORS
  end

  %w(debug info warn error fatal).each do |level|
    class_eval <<-LEVELS
      def #{level}?
        true
      end
    LEVELS
  end

end

require 'mail'
::Mail.defaults do
  delivery_method :test
end

require 'hiredis'
require 'redis'
require 'sandstorm'
require 'flapjack/redis_proxy'

# This file was generated by the `rspec --init` command. Conventionally, all
# specs live under a `spec` directory, which RSpec adds to the `$LOAD_PATH`.
# Require this file using `require "spec_helper"` to ensure that it is only
# loaded once.
#
# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  config.run_all_when_everything_filtered = true
  config.filter_run :focus

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = 'random'

  unless (ENV.keys & ['SHOW_LOGGER_ALL', 'SHOW_LOGGER_ERRORS']).empty?
    config.instance_variable_set('@formatters', [])
    config.add_formatter(:documentation)
  end

  config.around(:each, :redis => true) do |example|
    Flapjack::RedisProxy.config = {:db => 14, :driver => :hiredis}
    Flapjack.redis.flushdb
    example.run
    Flapjack.redis.quit
  end

  config.around(:each, :logger => true) do |example|
    @logger = MockLogger.new
    example.run

    if ENV['SHOW_LOGGER_ALL']
      puts @logger.messages.compact.join("\n")
    end

    if ENV['SHOW_LOGGER_ERRORS']
      puts @logger.errors.compact.join("\n")
    end

    @logger.errors.clear
  end

  config.after(:each, :time => true) do
    Delorean.back_to_the_present
  end

  config.after(:each) do
    WebMock.reset!
  end

  config.include Factory, :redis => true
  config.include ErbViewHelper, :erb_view => true
  config.include Rack::Test::Methods, :sinatra => true
end
