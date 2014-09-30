# encoding: UTF-8

require 'logger'
require 'socket'
require 'spec_helper'
require 'girl_friday'

begin
  require 'sucker_punch'
  require 'sucker_punch/testing/inline'
rescue LoadError
end

describe Rollbar do

  describe '.report_exception' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
      end

      begin
        foo = bar
      rescue => e
        @exception = e
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }

    it 'should report exceptions without person or request data' do
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      Rollbar.report_exception(@exception)
    end

    it 'should not report anything when disabled' do
      logger_mock.should_not_receive(:info).with('[Rollbar] Success')
      Rollbar.configure do |config|
        config.enabled = false
      end

      Rollbar.report_exception(@exception)

      Rollbar.configure do |config|
        config.enabled = true
      end
    end

    it 'should be enabled when freshly configured' do
      Rollbar.configuration.enabled.should == true
    end

    it 'should not be enabled when not configured' do
      Rollbar.unconfigure

      Rollbar.configuration.enabled.should be_nil
      Rollbar.report_exception(@exception).should == 'disabled'
    end

    it 'should stay disabled if configure is called again' do
      Rollbar.unconfigure

      # configure once, setting enabled to false.
      Rollbar.configure do |config|
        config.enabled = false
      end

      # now configure again (perhaps to change some other values)
      Rollbar.configure do |config| end

      Rollbar.configuration.enabled.should == false
      Rollbar.report_exception(@exception).should == 'disabled'
    end

    it 'should report exceptions with request and person data' do
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      request_data = {
        :params => { :foo => "bar" },
        :url => 'http://localhost/',
        :user_ip => '127.0.0.1',
        :headers => {},
        :GET => { "baz" => "boz" },
        :session => { :user_id => 123 },
        :method => "GET",
      }
      person_data = {
        :id => 1,
        :username => "test",
        :email => "test@example.com"
      }
      Rollbar.report_exception(@exception, request_data, person_data)
    end

    it "should work with an IO object as rack.errors" do
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      request_data = {
        :params => { :foo => "bar" },
        :url => 'http://localhost/',
        :user_ip => '127.0.0.1',
        :headers => {},
        :GET => { "baz" => "boz" },
        :session => { :user_id => 123 },
        :method => "GET",
        :env => { :"rack.errors" => IO.new(2, File::WRONLY) },
      }
      person_data = {
        :id => 1,
        :username => "test",
        :email => "test@example.com"
      }
      Rollbar.report_exception(@exception, request_data, person_data)
    end

    it 'should ignore ignored exception classes' do
      saved_filters = Rollbar.configuration.exception_level_filters
      Rollbar.configure do |config|
        config.exception_level_filters = { 'NameError' => 'ignore' }
      end

      logger_mock.should_not_receive(:info)
      logger_mock.should_not_receive(:warn)
      logger_mock.should_not_receive(:error)

      Rollbar.report_exception(@exception)

      Rollbar.configure do |config|
        config.exception_level_filters = saved_filters
      end
    end

    it 'should ignore ignored persons' do
      Rollbar.configure do |config|
        config.ignored_person_ids += [1]
      end

      logger_mock.should_not_receive(:info)
      logger_mock.should_not_receive(:warn)
      logger_mock.should_not_receive(:error)

      person_data = {
        :id => 1,
        :username => "test",
        :email => "test@example.com"
      }
      Rollbar.report_exception(@exception, {}, person_data)
    end

    it 'should not ignore non-ignored persons' do
      Rollbar.configure do |config|
        config.ignored_person_ids += [1]
      end

      Rollbar.last_report = nil

      person_data = {
        :id => 1,
        :username => "test",
        :email => "test@example.com"
      }
      Rollbar.report_exception(@exception, {}, person_data)
      Rollbar.last_report.should be_nil

      person_data = {
        :id => 2,
        :username => "test2",
        :email => "test2@example.com"
      }
      Rollbar.report_exception(@exception, {}, person_data)
      Rollbar.last_report.should_not be_nil
    end

    it 'should allow callables to set exception filtered level' do
      callable_mock = double
      saved_filters = Rollbar.configuration.exception_level_filters
      Rollbar.configure do |config|
        config.exception_level_filters = { 'NameError' => callable_mock }
      end

      callable_mock.should_receive(:call).with(@exception).at_least(:once).and_return("info")
      logger_mock.should_receive(:info)
      logger_mock.should_not_receive(:warn)
      logger_mock.should_not_receive(:error)

      Rollbar.report_exception(@exception)

      Rollbar.configure do |config|
        config.exception_level_filters = saved_filters
      end
    end

    it 'should not report exceptions when silenced' do
      Rollbar.should_not_receive :schedule_payload

      begin
        test_var = 1
        Rollbar.silenced do
          test_var = 2
          raise
        end
      rescue => e
        Rollbar.report_exception(e)
      end

      test_var.should == 2
    end

    it 'should report exception objects with no backtrace' do
      payload = nil
      Rollbar.stub(:schedule_payload) do |*args|
        payload = args[0]
      end
      Rollbar.report_exception(StandardError.new("oops"))
      payload["data"][:body][:trace][:frames].should == []
      payload["data"][:body][:trace][:exception][:class].should == "StandardError"
      payload["data"][:body][:trace][:exception][:message].should == "oops"
    end

    it 'should return the exception data with a uuid, on platforms with SecureRandom' do
      if defined?(SecureRandom) and SecureRandom.respond_to?(:uuid)
        Rollbar.stub(:schedule_payload) do |*args| end
        exception_data = Rollbar.report_exception(StandardError.new("oops"))
        exception_data[:uuid].should_not be_nil
      end
    end

    it 'should report exception objects with nonstandard backtraces' do
      payload = nil
      Rollbar.stub(:schedule_payload) do |*args|
        payload = args[0]
      end

      class CustomException < StandardError
        def backtrace
          ["custom backtrace line"]
        end
      end

      exception = CustomException.new("oops")

      Rollbar.report_exception(exception)

      payload["data"][:body][:trace][:frames][0][:method].should == "custom backtrace line"
    end

    it 'should report exceptions with a custom level' do
      payload = nil
      Rollbar.stub(:schedule_payload) do |*args|
        payload = args[0]
      end

      Rollbar.report_exception(@exception)

      payload["data"][:level].should == 'error'

      Rollbar.report_exception(@exception, nil, nil, 'debug')

      payload["data"][:level].should == 'debug'
    end
  end

  context 'report_message' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }
    let(:user) { User.create(:email => 'email@example.com', :encrypted_password => '', :created_at => Time.now, :updated_at => Time.now) }

    it 'should report simple messages' do
      logger_mock.should_receive(:info).with('[Rollbar] Scheduling payload')
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      Rollbar.report_message("Test message")
    end

    it 'should not report anything when disabled' do
      logger_mock.should_not_receive(:info).with('[Rollbar] Success')
      Rollbar.configure do |config|
        config.enabled = false
      end

      Rollbar.report_message("Test message that should be ignored")

      Rollbar.configure do |config|
        config.enabled = true
      end
    end

    it 'should report messages with extra data' do
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      Rollbar.report_message("Test message with extra data", 'debug', :foo => "bar",
                               :hash => { :a => 123, :b => "xyz" })
    end

    it 'should not crash with circular extra_data' do
      a = { :foo => "bar" }
      b = { :a => a }
      c = { :b => b }
      a[:c] = c

      logger_mock.should_receive(:error).with(/\[Rollbar\] Reporting internal error encountered while sending data to Rollbar./)

      Rollbar.report_message("Test message with circular extra data", 'debug', a)
    end

    it 'should be able to report form validation errors when they are present' do
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      user.errors.add(:example, "error")
      user.report_validation_errors_to_rollbar
    end

    it 'should not report form validation errors when they are not present' do
      logger_mock.should_not_receive(:info).with('[Rollbar] Success')
      user.errors.clear
      user.report_validation_errors_to_rollbar
    end

    after(:each) do
      Rollbar.configure do |config|
        config.logger = ::Rails.logger
      end
    end
  end

  context 'report_message_with_request' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }
    let(:user) { User.create(:email => 'email@example.com', :encrypted_password => '', :created_at => Time.now, :updated_at => Time.now) }

    it 'should report simple messages' do
      logger_mock.should_receive(:info).with('[Rollbar] Scheduling payload')
      logger_mock.should_receive(:info).with('[Rollbar] Success')
      Rollbar.report_message_with_request("Test message")

      Rollbar.last_report[:request].should be_nil
      Rollbar.last_report[:person].should be_nil
    end

    it 'should report messages with request, person data and extra data' do
      Rollbar.last_report = nil

      logger_mock.should_receive(:info).with('[Rollbar] Scheduling payload')
      logger_mock.should_receive(:info).with('[Rollbar] Success')

      request_data = {
        :params => {:foo => 'bar'}
      }

      person_data = {
        :id => 123,
        :username => 'username'
      }

      extra_data = {
        :extra_foo => 'extra_bar'
      }

      Rollbar.report_message_with_request("Test message", 'info', request_data, person_data, extra_data)

      Rollbar.last_report[:request].should == request_data
      Rollbar.last_report[:person].should == person_data
      Rollbar.last_report[:body][:message][:extra_foo].should == 'extra_bar'
    end
  end

  context 'payload_destination' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
        config.filepath = 'test.rollbar'
      end

      begin
        foo = bar
      rescue => e
        @exception = e
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }

    it 'should send the payload over the network by default' do
      logger_mock.should_not_receive(:info).with('[Rollbar] Writing payload to file')
      logger_mock.should_receive(:info).with('[Rollbar] Sending payload').once
      logger_mock.should_receive(:info).with('[Rollbar] Success').once
      Rollbar.report_exception(@exception)
    end

    it 'should save the payload to a file if set' do
      logger_mock.should_not_receive(:info).with('[Rollbar] Sending payload')
      logger_mock.should_receive(:info).with('[Rollbar] Writing payload to file').once
      logger_mock.should_receive(:info).with('[Rollbar] Success').once

      filepath = ''

      Rollbar.configure do |config|
        config.write_to_file = true
        filepath = config.filepath
      end

      Rollbar.report_exception(@exception)

      File.exist?(filepath).should == true
      File.read(filepath).should include test_access_token
      File.delete(filepath)

      Rollbar.configure do |config|
        config.write_to_file = false
      end
    end
  end

  context 'asynchronous_handling' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
      end

      begin
        foo = bar
      rescue => e
        @exception = e
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }

    it 'should send the payload using the default asynchronous handler girl_friday' do
      logger_mock.should_receive(:info).with('[Rollbar] Scheduling payload')
      logger_mock.should_receive(:info).with('[Rollbar] Sending payload')
      logger_mock.should_receive(:info).with('[Rollbar] Success')

      Rollbar.configure do |config|
        config.use_async = true
        GirlFriday::WorkQueue::immediate!
      end

      Rollbar.report_exception(@exception)

      Rollbar.configure do |config|
        config.use_async = false
        GirlFriday::WorkQueue::queue!
      end
    end

    it 'should send the payload using a user-supplied asynchronous handler' do
      logger_mock.should_receive(:info).with('Custom async handler called')
      logger_mock.should_receive(:info).with('[Rollbar] Sending payload')
      logger_mock.should_receive(:info).with('[Rollbar] Success')

      Rollbar.configure do |config|
        config.use_async = true
        config.async_handler = Proc.new { |payload|
          logger_mock.info 'Custom async handler called'
          Rollbar.process_payload(payload)
        }
      end

      Rollbar.report_exception(@exception)

      Rollbar.configure do |config|
        config.use_async = false
        config.async_handler = Rollbar.method(:default_async_handler)
      end
    end

    # We should be able to send String payloads, generated
    # by a previous version of the gem. This can happend just
    # after a deploy with an gem upgrade.
    context 'with a payload generated as String' do
      let(:async_handler) do
        proc do |payload|
          # simulate previous gem version
          string_payload = MultiJson.dump(payload)

          Rollbar.process_payload(string_payload)
        end
      end

      before do
        Rollbar.configuration.stub(:use_async).and_return(true)
        Rollbar.configuration.stub(:async_handler).and_return(async_handler)
      end

      it 'sends a payload generated as String, not as a Hash' do
        logger_mock.should_receive(:info).with('[Rollbar] Success')

        Rollbar.report_exception(@exception)
      end
    end

    describe "#use_sucker_punch", :if => defined?(SuckerPunch) do
      it "should send the payload to sucker_punch delayer" do
        logger_mock.should_receive(:info).with('[Rollbar] Scheduling payload')
        logger_mock.should_receive(:info).with('[Rollbar] Sending payload')
        logger_mock.should_receive(:info).with('[Rollbar] Success')

        Rollbar.configure do |config|
          config.use_sucker_punch
        end

        Rollbar.report_exception(@exception)

        Rollbar.configure do |config|
          config.use_async = false
          config.async_handler = Rollbar.method(:default_async_handler)
        end
      end
    end

    describe "#use_sidekiq", :if => defined?(Sidekiq) do
      it "should instanciate sidekiq delayer with custom values" do
        Rollbar::Delay::Sidekiq.should_receive(:new).with('queue' => 'test_queue')
        config = Rollbar::Configuration.new
        config.use_sidekiq 'queue' => 'test_queue'
      end

      it "should send the payload to sidekiq delayer" do
        handler = double('sidekiq_handler_mock')
        handler.should_receive(:call)

        Rollbar.configure do |config|
          config.use_sidekiq
          config.async_handler = handler
        end

        Rollbar.report_exception(@exception)

        Rollbar.configure do |config|
          config.use_async = false
          config.async_handler = Rollbar.method(:default_async_handler)
        end
      end
    end
  end

  context 'message_data' do
    before(:each) do
      configure
      @message_body = "This is a test"
      @level = 'debug'
    end

    it 'should build a message' do
      data = Rollbar.send(:message_data, @message_body, @level, {})
      data[:body][:message][:body].should == @message_body
      data[:level].should == @level
      data[:custom].should be_nil
    end

    it 'should accept extra_data' do
      user_id = 123
      name = "Tester"

      data = Rollbar.send(:message_data, @message_body, 'info',
                            :user_id => user_id, :name => name)

      data[:level].should == 'info'
      message = data[:body][:message]
      message[:body].should == @message_body
      message[:user_id].should == user_id
      message[:name].should == name
    end

    it 'should build a message with custom data when configured' do
      Rollbar.configure do |config|
        config.custom_data_method = lambda { {:foo => "bar", :hello => [1, 2, 3]} }
      end

      data = Rollbar.send(:message_data, @message_body, @level, {})

      data[:level].should == @level
      data[:body][:message][:body].should == @message_body
      data[:custom].should_not be_nil
      data[:custom][:foo].should == "bar"
      data[:custom][:hello][2].should == 3

      Rollbar.configure do |config|
        config.custom_data_method = nil
      end
    end
  end

  context 'exception_data' do
    before(:each) do
      configure
      begin
        foo = bar
      rescue => e
        @exception = e
      end
    end

    it 'should accept force_level' do
      level = 'critical'
      data = Rollbar.send(:exception_data, @exception, level)
      data[:level].should == level
    end

    it 'should build valid exception data' do
      data = Rollbar.send(:exception_data, @exception)

      data[:level].should_not be_nil
      data[:custom].should be_nil

      trace = data[:body][:trace]

      frames = trace[:frames]
      frames.should be_a_kind_of(Array)
      frames.each do |frame|
        frame[:filename].should be_a_kind_of(String)
        frame[:lineno].should be_a_kind_of(Fixnum)
        if frame[:method]
          frame[:method].should be_a_kind_of(String)
        end
      end

      # should be NameError, but can be NoMethodError sometimes on rubinius 1.8
      # http://yehudakatz.com/2010/01/02/the-craziest-fing-bug-ive-ever-seen/
      trace[:exception][:class].should match(/^(NameError|NoMethodError)$/)
      trace[:exception][:message].should match(/^(undefined local variable or method `bar'|undefined method `bar' on an instance of)/)
    end

    it 'should include custom data when configured' do
      Rollbar.configure do |config|
        config.custom_data_method = lambda { {:foo => "baz", :hello => [4, 5, 6]} }
      end

      data = Rollbar.send(:exception_data, @exception)
      data[:body][:trace].should_not be_nil
      data[:custom][:foo].should == "baz"
      data[:custom][:hello][2].should == 6

      Rollbar.configure do |config|
        config.custom_data_method = nil
      end
    end

  end

  context 'exception_data_with_locals_enabled' do
    before(:each) do
      def test_func(test_param)
        local_func_var = "local_func_var_value"
        test_param.non_existent_method
      end

      configure
      Rollbar.configure do |config|
        config.locals[:enabled] = true
      end

      begin
        local_var = "local_var_value"
        test_func("test_param_value")
      rescue => e
        @exception = e
        @data = Rollbar.send(:exception_data, @exception)
      end
    end

    context 'when using Ruby 1.9.3 and above' do
      next unless Method.method_defined? :parameters
      it 'should include local variables and args for each stack frame when enabled' do
        top_frame = @data[:body][:trace][:frames].last
        top_frame[:locals].keys.count.should eq 1
        top_frame[:locals][:local_func_var].should eq "local_func_var_value"
        top_frame[:args][:test_param].should eq "test_param_value"
        top_frame[:args].keys.count.should eq 1

        next_frame = @data[:body][:trace][:frames][-2]
        next_frame[:locals].keys.count.should eq 1
        next_frame[:locals][:local_var].should eq "local_var_value"
      end
    end

    # In Ruby 1.8.7, we don't have the Method#parameters method
    # Thus, all local variables, including method arguments will be
    # available in the frame's :local key. The :args key will not be available
    context 'when using Ruby 1.8.7 and below' do
      next if Method.method_defined? :parameters
      it 'should include local variables for each stack frame when enabled' do
        top_frame = @data[:body][:trace][:frames].last
        top_frame[:args].should be_nil
        top_frame[:locals].keys.count.should eq 2
        top_frame[:locals][:local_func_var].should eq "local_func_var_value"
        top_frame[:locals][:test_param].should eq "test_param_value"

        next_frame = @data[:body][:trace][:frames][-2]
        next_frame[:locals].keys.count.should eq 1
        next_frame[:locals][:local_var].should eq "local_var_value"
      end
    end

  end

  context 'logger' do
    before(:each) do
      reset_configuration
    end

    it 'should have use the Rails logger when configured to do so' do
      configure
      Rollbar.send(:logger).should == ::Rails.logger
    end

    it 'should use the default_logger when no logger is set' do
      logger = Logger.new(STDERR)
      Rollbar.configure do |config|
        config.default_logger = lambda { logger }
      end
      Rollbar.send(:logger).should == logger
    end

    it 'should have a default default_logger' do
      Rollbar.send(:logger).should_not be_nil
    end

    after(:each) do
      reset_configuration
    end
  end

  context 'build_payload' do
    before(:each) do
      configure
      Rollbar.configure do |config|
        config.logger = logger_mock
      end
    end

    let(:logger_mock) { double("Rails.logger").as_null_object }

    it 'should build valid json' do
      data = { :foo => { :bar => 'baz'}}
      payload = Rollbar.send(:build_payload, data)
      payload["data"][:foo][:bar].should == "baz"
    end

    it 'should strip out invalid utf-8' do
      payload = Rollbar.send(:build_payload, {
        :good_key => "\255bad value",
        "bad\255 key" => "good value",
        "bad key 2\255" => "bad \255value",
        :hash => {
          "bad array \255key" => ["bad\255 array element", "good array element"]
        }
      })

      payload["data"][:good_key].should == 'bad value'
      payload["data"]["bad key"].should == 'good value'
      payload["data"]["bad key 2"].should == 'bad value'
      payload["data"][:hash].should == {
        "bad array key" => ["bad array element", "good array element"]
      }
    end

    it 'should truncate large strings if the payload is too big' do
      data = {:foo => {:bar => "baz"}, :large => 'a' * (128 * 1024), :small => 'b' * 1024}
      payload = Rollbar.send(:build_payload, data)
      json = Rollbar.send(:dump_payload, payload)

      hash = MultiJson.load(json)
      hash["data"]["large"].should == '%s...' % ('a' * 1021)
      hash["data"]["small"].should == 'b' * 1024
    end

    it 'should send a failsafe message if the payload cannot be reduced enough' do
      logger_mock.should_receive(:error).with(/Sending failsafe response due to Could not send payload due to it being too large after truncating attempts/)
      logger_mock.should_receive(:info).with('[Rollbar] Success')

      orig_max = Rollbar::MAX_PAYLOAD_SIZE
      Rollbar::MAX_PAYLOAD_SIZE = 1
      orig_send_failsafe = Rollbar.method(:send_failsafe)

      Rollbar.stub(:send_failsafe) do |message, exception|
        Rollbar::MAX_PAYLOAD_SIZE = orig_max
        orig_send_failsafe.call(message, exception)
      end

      Rollbar.report_exception(@exception)
    end
  end

  context 'enforce_valid_utf8' do
    it 'should replace invalid utf8 values' do
      payload = {
        :bad_value => "bad value 1\255",
        :bad_value_2 => "bad\255 value 2",
        "bad\255 key" => "good value",
        :hash => {
          :inner_bad_value => "\255\255bad value 3",
          "inner \255bad key" => 'inner good value',
          "bad array key\255" => [
            'good array value 1',
            "bad\255 array value 1\255",
            {
              :inner_inner_bad => "bad inner \255inner value"
            }
          ]
        }
      }

      payload_copy = payload.clone
      Rollbar.send(:enforce_valid_utf8, payload_copy)

      payload_copy[:bad_value].should == "bad value 1"
      payload_copy[:bad_value_2].should == "bad value 2"
      payload_copy["bad key"].should == "good value"
      payload_copy.keys.should_not include("bad\456 key")
      payload_copy[:hash][:inner_bad_value].should == "bad value 3"
      payload_copy[:hash]["inner bad key"].should == 'inner good value'
      payload_copy[:hash]["bad array key"].should == [
        'good array value 1',
        'bad array value 1',
        {
          :inner_inner_bad => 'bad inner inner value'
        }
      ]
    end
  end

  context 'truncate_payload' do
    it 'should truncate all nested strings in the payload' do
      payload = {
        :truncated => '1234567',
        :not_truncated => '123456',
        :hash => {
          :inner_truncated => '123456789',
          :inner_not_truncated => '567',
          :array => ['12345678', '12', {:inner_inner => '123456789'}]
        }
      }

      payload_copy = payload.clone
      Rollbar.send(:truncate_payload, payload_copy, 6)

      payload_copy[:truncated].should == '123...'
      payload_copy[:not_truncated].should == '123456'
      payload_copy[:hash][:inner_truncated].should == '123...'
      payload_copy[:hash][:inner_not_truncated].should == '567'
      payload_copy[:hash][:array].should == ['123...', '12', {:inner_inner => '123...'}]
    end

    it 'should truncate utf8 strings properly' do
      payload = {
        :truncated => 'Ŝǻмρļẻ śţяịņģ',
        :not_truncated => '123456',
      }

      payload_copy = payload.clone
      Rollbar.send(:truncate_payload, payload_copy, 6)

      payload_copy[:truncated].should == "Ŝǻм..."
      payload_copy[:not_truncated].should == '123456'
    end
  end

  context 'base_data' do
    before(:each) { configure }

    it 'should have the correct notifier name' do
      Rollbar.send(:base_data)[:notifier][:name].should == 'rollbar-gem'
    end

    it 'should have the correct notifier version' do
      Rollbar.send(:base_data)[:notifier][:version].should == Rollbar::VERSION
    end

    it 'should have all the required keys' do
      data = Rollbar.send(:base_data)
      data[:timestamp].should_not be_nil
      data[:environment].should_not be_nil
      data[:level].should_not be_nil
      data[:language].should == 'ruby'
      data[:framework].should match(/^Rails/)
    end

    it 'should have default environment "unspecified"' do
      data = Rollbar.send(:base_data)
      data[:environment].should == 'unspecified'
    end

    it 'should have an overridden environment' do
      Rollbar.configure do |config|
        config.environment = 'overridden'
      end

      data = Rollbar.send(:base_data)
      data[:environment].should == 'overridden'
    end

    it 'should not have custom data under default configuration' do
      data = Rollbar.send(:base_data)
      data[:custom].should be_nil
    end

    it 'should have custom data when custom_data_method is configured' do
      Rollbar.configure do |config|
        config.custom_data_method = lambda { {:a => 1, :b => [2, 3, 4]} }
      end

      data = Rollbar.send(:base_data)
      data[:custom].should_not be_nil
      data[:custom][:a].should == 1
      data[:custom][:b][2].should == 4
    end
  end

  context 'server_data' do
    it 'should have the right hostname' do
      Rollbar.send(:server_data)[:host] == Socket.gethostname
    end

    it 'should have root and branch set when configured' do
      configure
      Rollbar.configure do |config|
        config.root = '/path/to/root'
        config.branch = 'master'
      end

      data = Rollbar.send(:server_data)
      data[:root].should == '/path/to/root'
      data[:branch].should == 'master'
    end
  end

  context "project_gems" do
    it "should include gem paths for specified project gems in the payload" do
      gems = ['rack', 'rspec-rails']
      gem_paths = []

      Rollbar.configure do |config|
        config.project_gems = gems
      end

      gems.each {|gem|
        gem_paths.push(Gem::Specification.find_by_name(gem).gem_dir)
      }

      data = Rollbar.send(:message_data, 'test', 'info', {})
      data[:project_package_paths].kind_of?(Array).should == true
      data[:project_package_paths].length.should == gem_paths.length

      data[:project_package_paths].each_with_index{|path, index|
        path.should == gem_paths[index]
      }
    end

    it "should handle regex gem patterns" do
      gems = ["rack", /rspec/, /roll/]
      gem_paths = []

      Rollbar.configure do |config|
        config.project_gems = gems
      end

      gem_paths = gems.map{|gem| Gem::Specification.find_all_by_name(gem).map(&:gem_dir) }.flatten.compact.uniq
      gem_paths.length.should > 1

      gem_paths.any?{|path| path.include? 'rollbar-gem'}.should == true
      gem_paths.any?{|path| path.include? 'rspec-rails'}.should == true

      data = Rollbar.send(:message_data, 'test', 'info', {})
      data[:project_package_paths].kind_of?(Array).should == true
      data[:project_package_paths].length.should == gem_paths.length
      (data[:project_package_paths] - gem_paths).length.should == 0
    end

    it "should not break on non-existent gems" do
      gems = ["this_gem_does_not_exist", "rack"]

      Rollbar.configure do |config|
        config.project_gems = gems
      end

      data = Rollbar.send(:message_data, 'test', 'info', {})
      data[:project_package_paths].kind_of?(Array).should == true
      data[:project_package_paths].length.should == 1
    end
  end

  context "report_internal_error" do
    it "should not crash when given an exception object" do
      begin
        1 / 0
      rescue => e
        Rollbar.send(:report_internal_error, e)
      end
    end
  end

  context "send_failsafe" do
    it "should not crash when given a message and exception" do
      begin
        1 / 0
      rescue => e
        Rollbar.send(:send_failsafe, "test failsafe", e)
      end
    end

    it "should not crash when given all nils" do
      Rollbar.send(:send_failsafe, nil, nil)
    end
  end

  context "request_data_extractor" do
    before(:each) do
      class DummyClass
      end
      @dummy_class = DummyClass.new
      @dummy_class.extend(Rollbar::RequestDataExtractor)
    end

    context "rollbar_headers" do
      it "should not include cookies" do
        env = {"HTTP_USER_AGENT" => "test", "HTTP_COOKIE" => "cookie"}
        headers = @dummy_class.send(:rollbar_headers, env)
        headers.should have_key "User-Agent"
        headers.should_not have_key "Cookie"
      end
    end
  end

  # configure with some basic params
  def configure
    Rollbar.reconfigure do |config|
      # special test access token
      config.access_token = test_access_token
      config.logger = ::Rails.logger
      config.root = ::Rails.root
      config.framework = "Rails: #{::Rails::VERSION::STRING}"
      config.request_timeout = 60
    end
  end

  def test_access_token
    'aaaabbbbccccddddeeeeffff00001111'
  end

end
