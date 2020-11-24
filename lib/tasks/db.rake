require 'httpclient'
require 'retryable'

namespace :db do
  desc 'Create a Sequel migration in ./db/migrate'
  task :create_migration do
    RakeConfig.context = :migrate

    name = ENV['NAME']
    abort('no NAME specified. use `rake db:create_migration NAME=add_users`') if !name

    migrations_dir = File.join('db', 'migrations')

    version = ENV['VERSION'] || Time.now.utc.strftime('%Y%m%d%H%M%S')
    filename = "#{version}_#{name}.rb"
    FileUtils.mkdir_p(migrations_dir)

    File.open(File.join(migrations_dir, filename), 'w') do |f|
      f.write <<~RUBY
        Sequel.migration do
          change do
          end
        end
      RUBY
      puts '*' * 134
      puts ''
      puts "The migration is in #{File.join(migrations_dir, filename)}"
      puts ''
      puts 'Before writing a migration review our style guide: https://github.com/cloudfoundry/cloud_controller_ng/wiki/CAPI-Migration-Style-Guide'
      puts ''
      puts '*' * 134
    end
  end

  desc 'Perform Sequel migration to database'
  task :migrate do
    RakeConfig.context = :migrate

    migrate
  end

  desc 'Make up to 5 attempts to connect to the database. Succeed it one is successful, and fail otherwise.'
  task :connect do
    RakeConfig.context = :migrate

    connect
  end

  desc 'Rollback migrations to the database (one migration by default)'
  task :rollback, [:number_to_rollback] do |_, args|
    RakeConfig.context = :migrate

    number_to_rollback = (args[:number_to_rollback] || 1).to_i
    rollback(number_to_rollback)
  end

  desc 'Randomly select between postgres and mysql'
  task :pick do
    unless ENV['DB_CONNECTION_STRING']
      ENV['DB'] ||= %w[mysql postgres].sample
      puts "Using #{ENV['DB']}"
    end
  end

  desc 'Create the database set in spec/support/bootstrap/db_config'
  task :create do
    RakeConfig.context = :migrate

    require_relative '../../spec/support/bootstrap/db_config'
    db_config = DbConfig.new
    host, port, user, pass, passenv = parse_db_connection_string

    case ENV['DB']
    when 'postgres'
      sh "#{passenv} psql -q #{host} #{port} #{user} -c 'create database #{db_config.name};'"
      extensions = 'CREATE EXTENSION IF NOT EXISTS citext; CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; CREATE EXTENSION IF NOT EXISTS pgcrypto;'
      sh "#{passenv} psql -q #{host} #{port} #{user} -d #{db_config.name} -c '#{extensions}'"
    when 'mysql'
      if ENV['TRAVIS'] == 'true'
        sh "mysql -e 'create database #{db_config.name};' -u root"
      else
        sh "mysql #{host} #{port} #{user} #{pass} -e 'create database #{db_config.name};'"
      end
    else
      puts 'rake db:create requires DB to be set to create a database'
    end
  end

  desc 'Drop the database set in spec/support/bootstrap/db_config'
  task :drop do
    RakeConfig.context = :migrate

    require_relative '../../spec/support/bootstrap/db_config'
    db_config = DbConfig.new
    host, port, user, pass, passenv = parse_db_connection_string

    case ENV['DB']
    when 'postgres'
      sh "#{passenv} psql -q #{host} #{port} #{user} -c 'drop database if exists #{db_config.name};'"
    when 'mysql'
      if ENV['TRAVIS'] == 'true'
        sh "mysql -e 'drop database if exists #{db_config.name};' -u root"
      else
        sh "mysql #{host} #{port} #{user} #{pass} -e 'drop database if exists #{db_config.name};'"
      end
    else
      puts 'rake db:drop requires DB to be set to create a database'
    end
  end

  desc 'Drop and create the database set in spec/support/bootstrap/db_config'
  task recreate: %w[drop create]

  desc 'Seed the database'
  task :seed do
    RakeConfig.context = :api

    require 'cloud_controller/seeds'
    BackgroundJobEnvironment.new(RakeConfig.config).setup_environment do
      VCAP::CloudController::Seeds.write_seed_data(RakeConfig.config)
    end
  end

  desc 'Migrate and seed database'
  task :setup_database do
    Rake::Task['db:migrate'].invoke
    Rake::Task['db:seed'].invoke
  end

  desc 'Ensure migrations in DB match local migration files'
  task :ensure_migrations_are_current do
    RakeConfig.context = :migrate

    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new($stdout)]))
    db_logger = Steno.logger('cc.db.migrations')
    VCAP::CloudController::Encryptor.db_encryption_key = RakeConfig.config.get(:db_encryption_key)
    db = VCAP::CloudController::DB.connect(RakeConfig.config.get(:db), db_logger)

    latest_migration_in_db = db[:schema_migrations].order(Sequel.desc(:filename)).first[:filename]
    latest_migration_in_dir = File.basename(Dir['db/migrations/*'].max)

    unless latest_migration_in_db == latest_migration_in_dir
      puts "Expected latest migration #{latest_migration_in_db} to equal #{latest_migration_in_dir}"
      exit 1
    end

    puts 'Successfully applied latest migrations to CF deployment'
  end

  desc 'Connect to the database set in spec/support/bootstrap/db_config'
  task :connect do
    RakeConfig.context = :migrate

    require_relative '../../spec/support/bootstrap/db_config'
    db_config = DbConfig.new
    host, port, user, pass, passenv = parse_db_connection_string

    case ENV['DB']
    when 'postgres'
      sh "#{passenv} psql -q #{host} #{port} #{user} -d #{db_config.name}"
    when 'mysql'
      sh "mysql #{host} #{port} #{user} #{pass}"
    else
      puts 'rake db:connect requires DB to be set to connect to a database'
    end
  end

  desc 'Validate Deployments are not missing encryption keys'
  task :validate_encryption_keys do
    RakeConfig.context = :api

    require 'cloud_controller/validate_database_keys'
    BackgroundJobEnvironment.new(RakeConfig.config).setup_environment do
      VCAP::CloudController::ValidateDatabaseKeys.validate!(RakeConfig.config)
    rescue VCAP::CloudController::ValidateDatabaseKeys::ValidateDatabaseKeysError => e
      puts e.class
      puts e.message
      exit 1
    end
  end

  namespace :dev do
    desc 'Migrate the database set in spec/support/bootstrap/db_config'
    task :migrate do
      RakeConfig.context = :migrate

      require_relative '../../spec/support/bootstrap/db_config'

      for_each_database { migrate }
    end

    desc 'Rollback the database migration set in spec/support/bootstrap/db_config'
    task :rollback, [:number_to_rollback] do |_, args|
      RakeConfig.context = :migrate

      require_relative '../../spec/support/bootstrap/db_config'
      number_to_rollback = (args[:number_to_rollback] || 1).to_i
      for_each_database { rollback(number_to_rollback) }
    end

    desc 'Dump schema to file'
    task :dump_schema do
      require_relative '../../spec/support/bootstrap/db_config'
      require_relative '../../spec/support/bootstrap/table_recreator'

      db = DbConfig.new.connection

      puts 'Recreating tables...'
      TableRecreator.new(db).recreate_tables(without_fake_tables: true)

      db.extension(:schema_dumper)
      puts 'Dumping schema...'
      schema = db.dump_schema_migration(indexes: true, foreign_keys: true)

      File.open('db/schema.rb', 'w') { |f|
        f.write("# rubocop:disable all\n")
        f.write(schema)
        f.write("# rubocop:enable all\n")
      }

      puts 'Wrote db/schema.rb'
    end
  end

  namespace :parallel do
    desc 'Drop and create the database set in spec/support/bootstrap/db_config in parallel'
    task recreate: %w[parallel:drop parallel:create]
  end

  def connect
    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new($stdout)]))
    logger = Steno.logger('cc.db.connect')
    log_method = lambda do |retries, exception|
      logger.info("[Attempt ##{retries}] Retrying because [#{exception.class} - #{exception.message}]: #{exception.backtrace.first(5).join(' | ')}")
    end

    Retryable.retryable(sleep: 1, tries: 5, log_method: log_method) do
      VCAP::CloudController::DB.connect(RakeConfig.config.get(:db), logger)
    end

    logger.info("Successfully connected to database")
  end

  def migrate
    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new($stdout)]))
    db_logger = Steno.logger('cc.db.migrations')
    DBMigrator.from_config(RakeConfig.config, db_logger).apply_migrations
  end

  def rollback(number_to_rollback)
    Steno.init(Steno::Config.new(sinks: [Steno::Sink::IO.new($stdout)]))
    db_logger = Steno.logger('cc.db.migrations')
    DBMigrator.from_config(RakeConfig.config, db_logger).rollback(number_to_rollback)
  end

  def parse_db_connection_string
    host = port = passenv = ''
    case ENV['DB']
    when 'postgres'
      user = '-U postgres'
      pass = ''
      if ENV['DB_CONNECTION_STRING']
        uri = URI.parse(ENV['DB_CONNECTION_STRING'])
        host = "-h #{uri.host}"
        port = "-p #{uri.port}" if uri.port
        if uri.user
          user = "-U #{uri.user}"
        end
        passenv = "PGPASSWORD=#{uri.password}" if uri.password
      end
    when 'mysql'
      user = '-u root'
      pass = '--password=password'
      if ENV['DB_CONNECTION_STRING']
        uri = URI.parse(ENV['DB_CONNECTION_STRING'])
        host = "-h #{uri.host}"
        port = "-P #{uri.port}" if uri.port
        if uri.user
          user = "-u #{uri.user}"
        end
        if uri.password
          pass = "--password=#{uri.password}"
        end
      end
    end
    [host, port, user, pass, passenv]
  end

  def for_each_database
    if ENV['DB'] || ENV['DB_CONNECTION_STRING']
      connection_string = DbConfig.new.connection_string
      RakeConfig.config.set(:db, RakeConfig.config.get(:db).merge(database: connection_string))

      yield
    else
      %w(postgres mysql).each do |db_type|
        connection_string = DbConfig.new(db_type: db_type).connection_string
        RakeConfig.config.set(:db, RakeConfig.config.get(:db).merge(database: connection_string))
        yield

        DbConfig.reset_environment
      end
    end
  end
end
