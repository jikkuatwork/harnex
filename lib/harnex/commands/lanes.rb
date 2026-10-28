module Harnex
  # `harnex lanes` (#87): the lanes in this repo (or everywhere), newest
  # first, with what each needs next.
  class LanesCommand
    def self.usage
      <<~TEXT
        Usage: harnex lanes [--all] [--closed] [--json]

        List the lanes of this repo: name, state, age, model, branch and what
        to do next. Landed and discarded lanes are hidden unless --closed.

        Options:
          --all      Lanes of every repo
          --closed   Include landed and discarded lanes
          --json     JSON array of lane records
          -h, --help Show this help
      TEXT
    end

    def initialize(argv, out: $stdout)
      @argv = argv.dup
      @out = out
    end

    def run
      unknown = @argv - %w[--all --closed --json -h --help]
      raise OptionParser::InvalidOption, "harnex lanes: unknown argument #{unknown.first}" unless unknown.empty?

      if (@argv & %w[-h --help]).any?
        @out.puts self.class.usage
        return 0
      end

      Lanes.sweep_merged(Lanes.main_root(Dir.pwd))
      lanes = selected
      if @argv.include?("--json")
        @out.puts JSON.generate(lanes.map { |lane| Lanes.snapshot(lane) })
      elsif lanes.empty?
        @out.puts "no lanes#{@argv.include?('--all') ? '' : ' in this repo'} (start one with `harnex delegate`)"
      else
        @out.puts table(lanes)
      end
      0
    end

    private

    def selected
      root = Lanes.main_root(Dir.pwd) || File.expand_path(Dir.pwd)
      lanes = Lanes.all
      lanes = lanes.select { |lane| lane["repo_root"] == root } unless @argv.include?("--all")
      lanes = lanes.select { |lane| Lanes.open?(lane) } unless @argv.include?("--closed")
      lanes.sort_by { |lane| lane["launched_at"] || lane["created_at"] || "" }.reverse
    end

    def table(lanes)
      rows = lanes.map do |lane|
        [lane["name"], state(lane), Lanes.duration(lane["launched_at"] || lane["created_at"]),
         lane["model"] || lane["requested_model"] || "-", lane["branch"] || lane["kind"], next_step(lane)]
      end
      header = %w[NAME STATE AGE MODEL BRANCH NEXT]
      widths = header.each_index.map { |i| ([header[i]] + rows.map { |r| r[i].to_s }).map(&:length).max }
      ([header] + rows).map { |row| row.each_with_index.map { |cell, i| i == row.length - 1 ? cell.to_s : cell.to_s.ljust(widths[i]) }.join("  ") }.join("\n")
    end

    def state(lane)
      return lane["state"] unless lane["state"] == "running"
      return "finished, uncollected" unless Lanes.live?(lane)

      detail = Lanes.progress_line(lane)[/ · (now .*|thinking)\z/, 1]
      detail ? "working (#{detail})" : "working"
    end

    def next_step(lane)
      name = lane["name"]
      case lane["state"]
      when "running" then "harnex result #{name}"
      when "done" then lane["branch"] ? "harnex land #{name}" : "harnex reply #{name} \"...\""
      when "failed" then "harnex reply #{name} \"Continue...\""
      else "-"
      end
    end
  end
end
