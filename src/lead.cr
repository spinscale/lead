require "clim"
require "colorize"
require "yaml"
require "http/client"
require "crinja"

module Lead
  VERSION = "0.1.0"

  class Cli < Clim
    main_command do
      desc "lead - Little Elasticsearch Alerting Deployer"
      usage "lead [delete|deploy|dump|list|verify] [arguments]"
      version "lead version: #{Lead::VERSION}"
      run do |options, arguments|
        # help string
        puts options.help
      end
      sub_command "verify" do
        desc "verify local watches consistency"
        usage "lead verify"
        option "-c config", "--config=path", type: String, desc: "configuration path", default: ENV["LEAD_CONFIG"]? || ""
        run do |options, arguments|
          config = Config.new(options.config)
          VerifyStage.new(config).run
        end
      end
      sub_command "list" do
        desc "list local watches"
        usage "lead list"
        option "-c config", "--config=path", type: String, desc: "configuration path", default: ENV["LEAD_CONFIG"]? || ""
        run do |options, arguments|
          config = Config.new(options.config)
          io = IO::Memory.new
          verifyStage = VerifyStage.new(config, io)
          verifyStage.run
          STDOUT << "\n"
          verifyStage.watches.keys.each { |id|
            STDOUT << sprintf "%-60s\n", id
          }
        end
      end
      sub_command "deploy" do
        desc "deploy watches to remote cluster instance, runs verify stage"
        usage "lead deploy"
        option "-c config", "--config=path", type: String, desc: "configuration path", default: ENV["LEAD_CONFIG"]? || ""
        option "-f", "--force", type: Bool, desc: "deploy watches remotely", default: true
        run do |options, arguments|
          config = Config.new(options.config)
          verifyStage = VerifyStage.new(config)
          verifyStage.run
          deployStage = DeployStage.new(config, options.force, verifyStage.watches)
          deployStage.run
        end
      end
      sub_command "delete" do
        desc "deletes watch remotely that do not exist in the configuration"
        usage "lead delete"
        option "-c config", "--config=path", type: String, desc: "configuration path", default: ENV["LEAD_CONFIG"]? || ""
        option "-f", "--force", type: Bool, desc: "delete watches remotely", default: true
        run do |options, arguments|
          config = Config.new(options.config)
          stage = DeleteStage.new(config, options.force)
          stage.run
        end
      end
      sub_command "dump" do
        desc "dumps the JSON of a single watch"
        usage "lead dump watch_id"
        option "-c config", "--config=path", type: String, desc: "configuration path", default: ENV["LEAD_CONFIG"]? || ""
        run do |options, arguments|
          if arguments.size == 1
            config = Config.new(options.config)
            stage = DumpStage.new(config, arguments[0])
            stage.run
          else
            STDOUT << "please supply watch id. Exiting...\n"
            Process.exit(-1)
          end
        end
      end
    end
  end

  class DeleteStage
    @io : IO

    def initialize(@config : Config, @force : Bool, @io = STDOUT)
      @headers = HTTP::Headers.new
      @headers.add "Content-Type", "application/json"
    end

    def run
      # retrieve local watch ids
      localIds = Dir.glob(@config.path + "/watches/" + "*.json").map { |name| File.basename(name, ".json") }

      # retrieve remote watch ids
      client = Lead.createHttpClient(@config)
      json = %q{{ "size": 10, "_source": false, "sort": [ "_doc" ]} }
      # try to retrieve the minimal JSON, just the ids and the scroll
      response = client.post "/.watches/_search?scroll=1m&filter_path=_scroll_id,hits.total,hits.hits._id", @headers, body: json
      searchJson = JSON.parse(response.body)
      scroll_id = searchJson["_scroll_id"]
      remoteIds = searchJson["hits"]["hits"].as_a.map { |hit| hit["_id"].as_s }

      # keep doing scrolls until no more hits
      while true
        json = "{ \"scroll\" : \"1m\", \"scroll_id\"  : \"#{scroll_id}\" } "
        response = client.post "/_search/scroll?filter_path=_scroll_id,hits.total,hits.hits._id", @headers, body: json
        searchJson = JSON.parse(response.body)
        scroll_id = searchJson["_scroll_id"]
        break if !searchJson["hits"].as_h.has_key?("hits")
        remoteIds += searchJson["hits"]["hits"].as_a.map { |hit| hit["_id"].as_s }
      end

      # close scroll
      client.delete "_search/scroll", @headers, "{ \"scroll_id\"  : \"#{scroll_id}\" } "

      # find diff
      idsToBeDeleted = remoteIds - localIds

      # delete or print watches
      if idsToBeDeleted.size == 0
        @io << "No watches need to be deleted, cluster is in sync\n\n"
      end
      idsToBeDeleted.each { |id|
        @io << sprintf "\n%-60s", id
        if @force
          response = client.delete "_xpack/watcher/watch/#{id}"
          case response.status_code
          when 200
            @io << "... " << "deleted".colorize(:green)
          else
            @io << "... " << "failed".colorize(:red) << JSON.parse(response.body).to_s
          end
        end
      }

      @io << "\n"
      client.close
    end
  end

  class DumpStage
    @io : IO

    def initialize(@config : Config, @id : String, @io = STDOUT)
    end

    def run
      file = @config.path + "/watches/#{@id}.json"
      if File.exists?(file)
        crinja = Crinja.new
        crinja.loader = Crinja::Loader::FileSystemLoader.new(@config.path + "/watches")

        templateName = File.basename(file)
        template = crinja.get_template(templateName)

        ctx = @config.yaml["vars"].as_h
        ctx = ctx.merge Hash{"_id" => @id}

        if @config.yaml["watches"][@id]? && @config.yaml["watches"][@id]["vars"]?
          ctx = ctx.merge @config.yaml["watches"][@id]["vars"].as_h
        end

        json = template.render ctx
        @io << "\n\n\nPUT _xpack/watcher/watch/" << @id.colorize(:green) << "\n"
        @io << JSON.parse(json).to_pretty_json << "\n"
      end
      # TODO else throw proper error messages
    end
  end

  class DeployStage
    @io : IO
    @client : HTTP::Client

    def initialize(@config : Config, @force : Bool, @watches : Hash(String, String), @io = STDOUT)
      @headers = HTTP::Headers.new
      @headers.add "Content-Type", "application/json"
      @client = Lead.createHttpClient @config
    end

    def run
      @io << sprintf "\nPer watch update overview (#{@watches.size} watches)\n"
      @io << sprintf "\n%-30s action\n", "watch id"
      @io << "-------------------------------------\n"
      @watches.each { |id, json|
        response = @client.get "_xpack/watcher/watch/#{id}"

        case response.status_code
        when 403
          @io << sprintf "%-30s %s not allowed get watch", id, "403".colorize(:red)
        when 404
          @io << sprintf "%-30s %s... ", id, "create".colorize(:light_cyan)
          putWatch(id, json)
        when 200
          remoteJson = JSON.parse(response.body)["watch"]
          localJson = JSON.parse(json)
          if remoteJson == localJson
            @io << sprintf "%-30s %s", id, "no update needed".colorize(:dark_gray)
          else
            @io << sprintf "%-30s %s... ", id, "update".colorize(:light_cyan)
            putWatch(id, json)
          end
        end
        @io << "\n"
      }
      @client.close
    end

    def putWatch(id : String, json : String)
      if @force
        response = @client.put "_xpack/watcher/watch/#{id}", @headers, json
        case response.status_code
        when 200, 201
          @io << "OK".colorize(:green)
        else
          @io << sprintf "%s: %s %s", "failed".colorize(:red), response.status_code, response.body
        end
      end
    end
  end

  class VerifyStage
    @io : IO
    getter watches

    def initialize(@config : Config, @io = STDOUT)
      @watches = Hash(String, String).new
    end

    def run
      @io << "Running verify stage...\n\n"
      @io << "Compiling watches                                      "
      compileWatches()
      @io << " ... " << "ok".colorize(:green) << " (#{@watches.size} watches)\n"
      @io << "Ensuring all templates are valid JSON                  "
      ensureWatchesAreValidJson()
      @io << " ... " << "ok".colorize(:green) << "\n"
    end

    def ensureWatchesAreValidJson
      errors = false
      @watches.each { |id, rendered|
        begin
          JSON.parse(rendered)
        rescue ex
          errors = true
          @io << "\nInvalid JSON for watch " << id.colorize(:red) << ": " << ex.message
        end
      }
      if errors
        @io << "\n\nEnsure all JSON is valid. Exiting...\n\n"
        Process.exit -1
      end
    end

    def compileWatches
      crinja = Crinja.new
      crinja.loader = Crinja::Loader::FileSystemLoader.new(@config.path + "watches/")
      Dir.glob(@config.path + "/watches/" + "*.json").sort.each { |file|
        id = File.basename(file, ".json")
        template = crinja.get_template(File.basename(file))
        ctx = @config.yaml["vars"].as_h.merge Hash{"_id" => id}

        if @config.yaml["watches"][id]? && @config.yaml["watches"][id]["vars"]?
          ctx = ctx.merge @config.yaml["watches"][id]["vars"].as_h
        end

        watches[id] = template.render(ctx)
      }
    end
  end

  def self.createHttpClient(config : Config)
    # TODO make SSL work!
    host = config.yaml["elasticsearch"]["host"].as_s
    port = config.yaml["elasticsearch"]["port"]? ? config.yaml["elasticsearch"]["port"].as_i? : 9200
    client = HTTP::Client.new host, port
    user = config.yaml["elasticsearch"]["user"].as_s
    pass = config.yaml["elasticsearch"]["pass"].as_s
    if user && pass
      client.basic_auth user, pass
    end
    return client
  end

  class Config
    getter yaml : YAML::Any
    getter path

    def initialize(@path : String)
      @yaml = File.open(@path + "/lead.yml") do |content|
        YAML.parse(content)
      end
    end
  end
end

STDOUT << %q{
        _                      _
       | |   ___    __ _    __| |
       | |  / _ \  / _` |  / _` |
       | | |  __/ | (_| | | (_| |
       |_|  \___|  \__,_|  \__,_|

}.colorize(:light_cyan)
Lead::Cli.start(ARGV)
