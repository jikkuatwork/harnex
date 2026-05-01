require "digest"
require "fileutils"
require "optparse"
require "securerandom"
require "set"
require "socket"

module Harnex
  class BinaryNotFound < RuntimeError; end

  module_function

  def env_value(name, default: nil)
    ENV.fetch(name, default)
  end

  DEFAULT_HOST = env_value("HARNEX_HOST", default: "127.0.0.1")
  DEFAULT_BASE_PORT = Integer(env_value("HARNEX_BASE_PORT", default: "43000"))
  DEFAULT_PORT_SPAN = Integer(env_value("HARNEX_PORT_SPAN", default: "4000"))
  DEFAULT_ID = "default"
  WATCH_DEBOUNCE_SECONDS = 1.0
  STATE_DIR = File.expand_path(env_value("HARNEX_STATE_DIR", default: "~/.local/state/harnex"))
  SESSIONS_DIR = File.join(STATE_DIR, "sessions")
  WatchConfig = Struct.new(:absolute_path, :display_path, :hook_message, :debounce_seconds, keyword_init: true)
  ID_ADJECTIVES = %w[
    bold blue calm cool dark dry fast gold gray green
    keen loud mint pale pink red shy slim soft warm
  ].freeze
  ID_NOUNS = %w[
    ant bat bee cat cod cow cub doe elk fox
    hen jay kit owl pug ram ray seal wasp yak
  ].freeze

  def resolve_repo_root(path = Dir.pwd)
    output, status = Open3.capture2("git", "rev-parse", "--show-toplevel", chdir: path)
    status.success? ? output.strip : File.expand_path(path)
  rescue StandardError
    File.expand_path(path)
  end

  def parse_duration_seconds(value, option_name:)
    text = value.to_s.strip
    raise OptionParser::InvalidArgument, "#{option_name} requires a value" if text.empty?

    match = text.match(/\A([0-9]+(?:\.[0-9]+)?)([smhSMH]?)\z/)
    unless match
      raise OptionParser::InvalidArgument,
            "#{option_name} must be a positive duration (examples: 30, 30s, 5m, 2h)"
    end

    amount = Float(match[1])
    multiplier =
      case match[2].downcase
      when "", "s" then 1.0
      when "m" then 60.0
      when "h" then 3600.0
      else
        raise OptionParser::InvalidArgument, "#{option_name} has an unsupported duration suffix"
      end

    seconds = amount * multiplier
    raise OptionParser::InvalidArgument, "#{option_name} must be greater than 0" if seconds <= 0.0

    seconds
  end

  def harness_version
    VERSION
  end

  def host_info
    {
      host: Socket.gethostname,
      platform: RUBY_PLATFORM
    }
  rescue StandardError
    {
      host: nil,
      platform: RUBY_PLATFORM
    }
  end

  def strip_ansi(text)
    text.to_s.gsub(/\e\[[0-9;]*[a-zA-Z]/, "")
  end

  def git_capture_start(repo_root)
    sha = git_output(repo_root, "rev-parse", "HEAD")
    branch = git_output(repo_root, "rev-parse", "--abbrev-ref", "HEAD")
    return {} if sha.empty? || branch.empty?

    {
      sha: sha,
      branch: branch
    }
  rescue StandardError
    {}
  end

  def git_capture_end(repo_root, start_sha)
    start_sha = start_sha.to_s.strip
    return {} if start_sha.empty?

    end_sha = git_output(repo_root, "rev-parse", "HEAD")
    range = "#{start_sha}..#{end_sha}"
    shortstat = git_output(repo_root, "diff", "--shortstat", range)
    commits = Integer(git_output(repo_root, "rev-list", "--count", range))
    stats = parse_git_shortstat(shortstat)

    {
      sha: end_sha,
      loc_added: stats.fetch(:loc_added),
      loc_removed: stats.fetch(:loc_removed),
      files_changed: stats.fetch(:files_changed),
      commits: commits
    }
  rescue StandardError
    {}
  end

  def repo_key(repo_root)
    Digest::SHA256.hexdigest(repo_root)[0, 16]
  end

  def normalize_id(id)
    value = id.to_s.strip
    raise "id is required" if value.empty?

    value
  end

  def id_key(id)
    normalize_id(id).downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def cli_key(cli)
    value = cli.to_s.strip.downcase
    return nil if value.empty?

    value.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
  end

  def current_session_context(env = ENV)
    session_id = env["HARNEX_SESSION_ID"].to_s.strip
    cli = env["HARNEX_SESSION_CLI"].to_s.strip
    id = env["HARNEX_ID"].to_s.strip
    repo_root = env["HARNEX_SESSION_REPO_ROOT"].to_s.strip
    return nil if session_id.empty? || cli.empty? || id.empty?

    {
      session_id: session_id,
      cli: cli,
      id: id,
      repo_root: repo_root.empty? ? nil : repo_root
    }
  end

  def format_relay_message(text, from:, id:, at: Time.now)
    header = "[harnex relay from=#{from} id=#{normalize_id(id)} at=#{at.iso8601}]"
    body = text.to_s
    return header if body.empty?

    "#{header}\n#{body}"
  end

  def active_session_ids(repo_root)
    active_sessions(repo_root).map { |session| session["id"].to_s.downcase }.to_set
  end

  def generate_id(repo_root)
    taken = active_session_ids(repo_root)
    ID_ADJECTIVES.product(ID_NOUNS).shuffle.each do |adj, noun|
      candidate = "#{adj}-#{noun}"
      return candidate unless taken.include?(candidate)
    end

    "session-#{SecureRandom.hex(4)}"
  end

  def registry_path(repo_root, id = DEFAULT_ID)
    FileUtils.mkdir_p(SESSIONS_DIR)
    File.join(SESSIONS_DIR, "#{session_file_slug(repo_root, id)}.json")
  end

  def exit_status_path(repo_root, id)
    exit_dir = File.join(STATE_DIR, "exits")
    FileUtils.mkdir_p(exit_dir)
    File.join(exit_dir, "#{session_file_slug(repo_root, id)}.json")
  end

  def output_log_path(repo_root, id)
    output_dir = File.join(STATE_DIR, "output")
    FileUtils.mkdir_p(output_dir)
    File.join(output_dir, "#{session_file_slug(repo_root, id)}.log")
  end

  def events_log_path(repo_root, id)
    events_dir = File.join(STATE_DIR, "events")
    FileUtils.mkdir_p(events_dir)
    File.join(events_dir, "#{session_file_slug(repo_root, id)}.jsonl")
  end

  def session_file_slug(repo_root, id)
    slug = id_key(id)
    slug = "default" if slug.empty?
    "#{repo_key(repo_root)}--#{slug}"
  end

  def active_sessions(repo_root = nil, id: nil, cli: nil)
    FileUtils.mkdir_p(SESSIONS_DIR)
    pattern =
      if repo_root
        File.join(SESSIONS_DIR, "#{repo_key(repo_root)}--*.json")
      else
        File.join(SESSIONS_DIR, "*.json")
      end

    target_id_key = id.nil? ? nil : id_key(id)
    normalized_cli = cli_key(cli)

    Dir.glob(pattern).sort.filter_map do |path|
      data = JSON.parse(File.read(path))
      if data["pid"] && alive_pid?(data["pid"])
        session = data.merge("registry_path" => path)
        next if target_id_key && id_key(session["id"].to_s) != target_id_key
        next if normalized_cli && cli_key(session_cli(session)) != normalized_cli

        session
      else
        FileUtils.rm_f(path)
        nil
      end
    rescue JSON::ParserError
      FileUtils.rm_f(path)
      nil
    end
  end

  def alive_pid?(pid)
    Process.kill(0, Integer(pid))
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def read_registry(repo_root, id = DEFAULT_ID, cli: nil)
    sessions = active_sessions(repo_root, id: id, cli: cli)
    return nil unless sessions.length == 1

    sessions.first
  end

  def tmux_pane_for_pid(pid)
    target_pid = Integer(pid)
    stdout, status = Open3.capture2(
      "tmux", "list-panes", "-a", "-F",
      "\#{pane_id}\t\#{pane_pid}\t\#{session_name}\t\#{window_name}"
    )
    return nil unless status.success?

    panes = stdout.each_line.filter_map do |line|
      pane_id, pane_pid, session_name, window_name = line.chomp.split("\t", 4)
      next if pane_id.to_s.empty?

      {
        target: pane_id,
        pane_id: pane_id,
        pane_pid: pane_pid.to_i,
        session_name: session_name,
        window_name: window_name
      }
    end

    pane_pids = panes.map { |p| p[:pane_pid] }.to_set

    # Direct match first
    matches = panes.select { |p| p[:pane_pid] == target_pid }

    # If no direct match, walk up the process tree from target_pid
    # to find an ancestor that is a tmux pane root process.
    if matches.empty?
      ancestor = parent_pid(target_pid)
      while ancestor && ancestor > 1
        if pane_pids.include?(ancestor)
          matches = panes.select { |p| p[:pane_pid] == ancestor }
          break
        end
        ancestor = parent_pid(ancestor)
      end
    end

    return nil unless matches.length == 1

    result = matches.first
    result.delete(:pane_pid)
    result
  rescue ArgumentError, Errno::ENOENT
    nil
  end

  def parent_pid(pid)
    stat = File.read("/proc/#{pid}/stat")
    # Field 4 is ppid (fields are space-separated, field 1 is pid,
    # field 2 is (comm) which may contain spaces, field 3 is state, field 4 is ppid)
    parts = stat.match(/\A\d+\s+\(.*?\)\s+\S+\s+(\d+)/)
    parts ? parts[1].to_i : nil
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end

  def write_registry(path, payload)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, JSON.pretty_generate(payload))
    File.rename(tmp, path)
  end

  def allocate_port(repo_root, id, requested_port = nil, host: DEFAULT_HOST)
    if requested_port
      return requested_port if port_available?(host, requested_port)

      raise "port #{requested_port} is already in use on #{host}"
    end

    seed = Digest::SHA256.hexdigest("#{repo_root}\0#{normalize_id(id)}").to_i(16)
    offset = seed % DEFAULT_PORT_SPAN

    DEFAULT_PORT_SPAN.times do |index|
      port = DEFAULT_BASE_PORT + ((offset + index) % DEFAULT_PORT_SPAN)
      return port if port_available?(host, port)
    end

    raise "could not find a free port in #{DEFAULT_BASE_PORT}-#{DEFAULT_BASE_PORT + DEFAULT_PORT_SPAN - 1}"
  end

  def port_available?(host, port)
    server = TCPServer.new(host, port)
    server.close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES
    false
  end

  def build_adapter(cli, argv)
    raise ArgumentError, "cli is required" if cli.to_s.strip.empty?

    Adapters.build(cli, argv)
  end

  def session_cli(session)
    (session["cli"] || Array(session["command"]).first).to_s
  end

  def build_watch_config(path, repo_root)
    return nil if path.nil?

    raise "file watch is unsupported on this system" unless Watcher.available?

    display_path = path.to_s.strip
    raise ArgumentError, "--watch requires a value" if display_path.empty?

    absolute_path = File.expand_path(display_path, repo_root)
    FileUtils.mkdir_p(File.dirname(absolute_path))

    WatchConfig.new(
      absolute_path: absolute_path,
      display_path: display_path,
      hook_message: "file-change-hook: read #{display_path}",
      debounce_seconds: WATCH_DEBOUNCE_SECONDS
    )
  end

  def git_output(repo_root, *args)
    stdout, _stderr, status = Open3.capture3("git", "-C", repo_root.to_s, *args)
    raise "git #{args.join(' ')} failed" unless status.success?

    stdout.strip
  end

  def parse_git_shortstat(text)
    {
      files_changed: text.to_s[/(\d+)\s+files?\s+changed/, 1].to_i,
      loc_added: text.to_s[/(\d+)\s+insertions?\(\+\)/, 1].to_i,
      loc_removed: text.to_s[/(\d+)\s+deletions?\(-\)/, 1].to_i
    }
  end
end
