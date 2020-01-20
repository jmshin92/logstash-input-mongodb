# encoding: utf-8
require "logstash/inputs/base"
require "logstash/timestamp"
require "mongo"
require 'json'
require 'date'
require 'sequel'
require 'jdbc/sqlite3'

class LogStash::Inputs::Mongodb < LogStash::Inputs::Base
  config_name "mongodb"

  default :codec, "plain"

  # fails several times to watch collection at specific jruby version (https://github.com/elastic/logstash/issues/11267)
  MAX_RETRY = 5
  SINCE_TABLE = :since_table
  VALID_OPERATIONS=["insert", "update", "delete"]

  # mongodb connection uri. example: mongodb://127.0.0.1:27017
  config :uri, :validate => :string, :required => true
  # mongodb database
  config :database, :validate => :string, :required => true
  # mongodb collection to watch
  config :collection, :validate => :string, :required => true
  # return events occurred at or after the specified time.
  config :start_at, :validate => :string
  # watch interval time
  config :watch_interval, :validate => :number, :default => 1

  # since_db(sqlite)
  config :since_db_path, :validate => :string, :default => "logstash-mongodb-sqlite.db"
  # field to set event type
  config :operation_field, :validate => :string, :default => "[@metadata][mongodb_operation]"
  # field to set event occurred time
  config :event_time_field, :validate => :string, :default => "[@metadata][mongodb_event_time]"

  def create_since_table(db)
    begin
      db.create_table SINCE_TABLE do
        String :collection
        String :resume_token
      end
    rescue
      @logger.info("since table already exists")
    end
  end

  def get_since_token(db, collection)
    table = db[SINCE_TABLE]
    x = table.where(:collection=> collection)
    if x[:resume_token].nil?
      init_placeholder(db, collection)
      return nil
    else
      token = x[:resume_token][:resume_token]
      return token
    end
  end

  def init_placeholder(db, collection)
    table = db[SINCE_TABLE]
    table.insert(:collection => collection, :resume_token => "")
  end

  def update_since_token(db, collection, token)
    table = db[SINCE_TABLE]
    table.where(:collection => collection).update(:resume_token => token)
  end

  public
  def register
    @retry_count = 0
    @closed = Concurrent::AtomicBoolean.new(false)

    # Mongo db
    Mongo::Logger.logger.level = Logger::INFO
    conn = Mongo::Client.new(@uri)
    @mongo_coll = conn.use(@database)[@collection]

    # Since db
    @since_db = Sequel.connect("jdbc:sqlite:#{@since_db_path}")
    create_since_table(@since_db)
  end # def register

  def run(queue)
    token = get_since_token(@since_db, @collection)
    begin
      if !token.nil? && token.length > 0
        # resume_after
        @stream = @mongo_coll.watch([], :resume_after => BSON::Document.new(:_data => token))
        @logger.info("Stream resume_after: #{token}")
      elsif defined?(@start_at)
        # start_at
        start_at_operation_time = BSON::Timestamp.new(Time.parse(@start_at).to_i, 1)
        @stream = @mongo_coll.watch([], :start_at_operation_time => start_at_operation_time)
        @logger.info("Stream start_at: #{@start_at}")
      else
        # start from now
        @stream = @mongo_coll.watch([])
        @logger.info("Stream from now")
      end

      enum = @stream.to_enum
    rescue
      # changestream to enum throws exception several times.
      retry if (@retry_count += 1) < MAX_RETRY
    end

    while @closed.false?
      inserted = false
      while bson_doc = enum.try_next
        doc = JSON.parse(bson_doc.to_json)

        typ = doc["operationType"]
        case typ
        when "insert"
          fullDoc = doc['fullDocument']
          event = LogStash::Event.new(fullDoc)
        when "update"
          updateDoc = doc['updateDescription']['updatedFields']
          event = LogStash::Event.new(updateDoc)
        when "delete"
          deletedKey = doc['documentKey']
          event = LogStash::Event.new(deletedKey)
        else
          @logger.debug("unsupported event #{typ}")
          next
        end

        # operation type
        event.set(@operation_field, typ)

        # event time
        t = Time.at(bson_doc["clusterTime"].seconds).to_datetime
        event.set(@event_time_field, t.iso8601.force_encoding(Encoding::UTF_8))

        decorate(event)
        queue << event

        inserted = true
      end

      if inserted
        token = @stream.resume_token[:_data]
        update_since_token(@since_db, @collection, token)
        @logger.debug("updated resume token #{token}")
      end

      @logger.debug("sleep for interval #{@watch_interval}")
      sleep(@watch_interval)
    end

    @logger.info("stopped watching collection")
  end # def run

  public
  def stop
    @logger.info("stopping...")
    @stream.close if !@stream.closed?
    @closed.make_true
    @logger.info("stopped!")
  end
end # class LogStash::Inputs::Mongodb
