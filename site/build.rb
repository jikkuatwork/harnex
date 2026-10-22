#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds harnex.zyt.app, a static Holm app, into site/app/ from the
# repository's Markdown docs and the live CLI help, so the site and the gem
# never drift. Dev tooling only (not shipped in the gem); needs the kramdown,
# kramdown-parser-gfm and rouge gems.
#
#   ruby site/build.rb
#   holm app validate site/app --spec-v1
#   holm @zyt app deploy site/app --spec-v1 --host harnex.zyt.app --force

require "cgi"
require "digest"
require "erb"
require "fileutils"
require "json"
require "open3"
require "kramdown"
require "kramdown-parser-gfm"
require "rouge"

ROOT = File.expand_path("..", __dir__)
SITE = __dir__
SRC = File.join(SITE, "src")
APP = File.join(SITE, "app")
WEB = File.join(APP, "web")
SITE_URL = "https://harnex.zyt.app"
GITHUB = "https://github.com/jikkuatwork/harnex"
VERSION = File.read(File.join(ROOT, "lib/harnex/version.rb"))[/VERSION = "([^"]+)"/, 1]

PAGES = [
  { slug: "start", src: "GUIDE.md", title: "Getting started", group: "guide",
    summary: "Install, check the setup, your first lanes, and the session layer underneath." },
  { slug: "lanes", src: "docs/lanes.md", title: "Lanes", group: "guide",
    summary: "ask, delegate, result, reply, land, discard and lanes in depth." },
  { slug: "mcp", src: "docs/mcp.md", title: "MCP server", group: "guide",
    summary: "The lane verbs as native tools for Claude Code, Pi and any MCP client." },
  { slug: "agents", src: "docs/agents.md", title: "Coding agents", group: "guide",
    summary: "Driving harnex from Claude Code and Pi: MCP, the gpt subagent, the CLI." },
  { slug: "upgrading", src: "docs/upgrading-to-0.29.md", title: "Upgrading to 0.29", group: "guide",
    summary: "Breaking changes since 0.12 and what is new in the agent release." },
  { slug: "cli", src: :cli, title: "CLI reference", group: "reference",
    summary: "Every command's help, generated from the CLI itself." },
  { slug: "technical", src: "TECHNICAL.md", title: "Technical reference", group: "reference",
    summary: "Commands, patterns, the HTTP API, adapters and internals." },
  { slug: "configuration", src: "docs/configuration.md", title: "Configuration", group: "reference",
    summary: ".harnex/config.json: phases, retention and telemetry settings." },
  { slug: "events", src: "docs/events.md", title: "Events", group: "reference",
    summary: "The per-session JSONL event stream." },
  { slug: "telemetry", src: "docs/dispatch-telemetry.md", title: "Dispatch telemetry", group: "reference",
    summary: "The canonical dispatch history stream and its schema." },
  { slug: "pi-rpc", src: "docs/pi-rpc.md", title: "Pi RPC", group: "reference",
    summary: "How harnex drives Pi's structured RPC mode." },
  { slug: "changelog", src: "CHANGELOG.md", title: "Changelog", group: "project",
    summary: "Every release, newest first." }
].each { |page| page[:url] = page[:slug] == "changelog" ? "/changelog" : "/docs/#{page[:slug]}" }.freeze

GROUPS = PAGES.group_by { |page| page[:group] }.freeze

NAV = [
  ["home", "home", "/"],
  ["start", "start", "/docs/start"],
  ["lanes", "lanes", "/docs/lanes"],
  ["mcp", "mcp", "/docs/mcp"],
  ["agents", "agents", "/docs/agents"],
  ["cli", "cli", "/docs/cli"],
  ["changelog", "changelog", "/changelog"]
].freeze

CLI_COMMANDS = %w[ask delegate result reply land discard lanes mcp run send wait watch stop status logs events
                  history pane doctor preflight agents-guide recipes guide orchestration artifact-report telemetry].freeze

# Repo-relative Markdown paths that have a page here.
LINKS = PAGES.select { |page| page[:src].is_a?(String) }.to_h { |page| [page[:src], page[:url]] }
                 .merge("README.md" => "/").freeze

def h(text)
  CGI.escapeHTML(text.to_s)
end

def template(name)
  ERB.new(File.read(File.join(SRC, "templates", "#{name}.erb")), trim_mode: "<>")
end

def render_page(path:, title:, description:, current:, body:, markdown_path: nil)
  page_title = title == "harnex" ? "harnex — Pi workers as tools for your coding agents" : "#{title} · harnex"
  template("layout").result(binding)
end

def write(relative, content)
  file = File.join(WEB, relative)
  FileUtils.mkdir_p(File.dirname(file))
  File.write(file, content)
end

# Point a link in `source` (repo-relative path) at this site when the target
# has a page here, at GitHub otherwise.
def rewrite_href(href, source)
  return href if href.match?(%r{\A(?:[a-z]+:|#|/)}i)

  target, anchor = href.split("#", 2)
  resolved = File.expand_path(target, File.join(ROOT, File.dirname(source))).delete_prefix("#{ROOT}/")
  fragment = anchor ? "##{anchor}" : ""
  return "#{LINKS[resolved]}#{fragment}" if LINKS.key?(resolved)

  kind = File.directory?(File.join(ROOT, resolved)) ? "tree" : "blob"
  "#{GITHUB}/#{kind}/main/#{resolved}#{fragment}"
end

def markdown_to_html(markdown, source)
  html = Kramdown::Document.new(
    markdown,
    input: "GFM", hard_wrap: false, auto_ids: true,
    syntax_highlighter: "rouge", syntax_highlighter_opts: { default_lang: "text" }
  ).to_html
  html = html.gsub(/href="([^"]+)"/) { %(href="#{rewrite_href(CGI.unescapeHTML(Regexp.last_match(1)), source)}") }
  # Code blocks get a terminal header with the language and a copy button (site.js).
  html = html.gsub(%r{<div class="language-([\w+-]+) highlighter-rouge"><div class="highlight">(.*?)</div></div>}m) do
    lang = Regexp.last_match(1)
    label = { "bash" => "shell", "sh" => "shell", "console" => "shell", "text" => "text", "plaintext" => "text" }.fetch(lang, lang)
    %(<div class="codeblock"><div class="head"><span>#{label}</span></div>#{Regexp.last_match(2)}</div>)
  end
  # Fences without a language come out bare; give them the same frame.
  html = html.gsub(%r{<pre><code(?: class="language-([\w+-]+)")?>(.*?)</code></pre>}m) do
    label = Regexp.last_match(1) || "text"
    %(<div class="codeblock"><div class="head"><span>#{label}</span></div><pre><code>#{Regexp.last_match(2)}</code></pre></div>)
  end
  # Headings become links to themselves.
  html.gsub(%r{<(h[23]) id="([^"]+)">(.*?)</\1>}m) { %(<#{Regexp.last_match(1)} id="#{Regexp.last_match(2)}"><a class="anchor" href="##{Regexp.last_match(2)}">#{Regexp.last_match(3)}</a></#{Regexp.last_match(1)}>) }
end

def doc_markdown(page)
  text = File.read(File.join(ROOT, page[:src]))
  text.sub(/\A#[^#].*\n+/, "") # the page template prints the title
end

def cli_help(*args)
  out, status = Open3.capture2e(Gem.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "bin/harnex"), *args)
  raise "harnex #{args.join(' ')} failed:\n#{out}" unless status.success?

  out.rstrip
end

def cli_reference_html
  sections = CLI_COMMANDS.map do |command|
    %(<h2 id="#{command}"><a class="anchor" href="##{command}">harnex #{command}</a></h2>\n) +
      %(<div class="codeblock"><div class="head"><span>harnex help #{command}</span></div><pre>#{h(cli_help('help', command))}</pre></div>)
  end
  index = CLI_COMMANDS.map { |command| %(<a href="##{command}"><code>#{command}</code></a>) }.join(" · ")
  <<~HTML
    <p>Generated from <code>harnex help</code> for harnex #{VERSION}. The lane commands come first; the session commands below them are the layer underneath.</p>
    <p>#{index}</p>
    <div class="codeblock"><div class="head"><span>harnex --help</span></div><pre>#{h(cli_help('--help'))}</pre></div>
    #{sections.join("\n")}
  HTML
end

def cli_reference_markdown
  (["# CLI reference (harnex #{VERSION})", "", "```text", cli_help("--help"), "```"] +
    CLI_COMMANDS.flat_map { |command| ["", "## harnex #{command}", "", "```text", cli_help("help", command), "```"] }).join("\n") + "\n"
end

def build_docs
  PAGES.each_with_index do |page, index|
    markdown = page[:src] == :cli ? cli_reference_markdown : File.read(File.join(ROOT, page[:src]))
    html = page[:src] == :cli ? cli_reference_html : markdown_to_html(doc_markdown(page), page[:src])
    prev_page = index.positive? ? PAGES[index - 1] : nil
    next_page = PAGES[index + 1]
    body = template("doc").result(binding)
    file = page[:slug] == "changelog" ? "changelog.html" : "docs/#{page[:slug]}.html"
    write(file, render_page(path: page[:url], title: page[:title], description: page[:summary],
                            current: page[:slug], body: body, markdown_path: "#{page[:url]}.md"))
    write("#{page[:url].delete_prefix('/')}.md", markdown)
  end

  rows = GROUPS.map do |group, pages|
    items = pages.map do |page|
      %(<tr><td><a href="#{page[:url]}">#{h(page[:title])}</a></td><td>#{h(page[:summary])}</td></tr>)
    end
    %(<h2 id="#{group}">#{group}</h2>\n<table><tbody>#{items.join}</tbody></table>)
  end
  body = <<~HTML
    <div class="wrap"><div class="docs"><div></div><article class="doc">
      <p class="crumb"><a href="/">harnex</a> / docs</p>
      <h1>Documentation</h1>
      <p>Everything here is built from the Markdown in the <a href="#{GITHUB}">repository</a> and the CLI's own help, and each page links its raw Markdown for agents. Start with <a href="/docs/start">Getting started</a>; agents can read <a href="/llms.txt">llms.txt</a>.</p>
      #{rows.join("\n")}
    </article></div></div>
  HTML
  write("docs/index.html", render_page(path: "/docs/", title: "Documentation", current: "docs",
                                       description: "harnex documentation: lanes, MCP, coding agents, CLI reference.", body: body))
end

def build_home
  body = template("home").result(binding)
  write("index.html", render_page(path: "/", title: "harnex", current: "home", body: body,
                                  description: "Pi workers (GPT models) as tools for you and your coding agents: " \
                                               "delegate tasks into git worktrees, follow up with context, land the result. CLI and MCP."))
end

def build_not_found
  body = <<~HTML
    <div class="wrap center">
      <p class="big">404</p>
      <p>harnex: command not found. There is no page at this address.</p>
      <p><a href="/">home</a> · <a href="/docs/">docs</a> · <a href="/docs/cli">cli reference</a></p>
    </div>
  HTML
  write("404.html", render_page(path: "/404", title: "Not found", current: nil, body: body,
                                description: "There is no page at this address."))
end

def build_llms
  links = PAGES.map { |page| "- [#{page[:title]}](#{SITE_URL}#{page[:url]}.md): #{page[:summary]}" }
  write("llms.txt", <<~TEXT)
    # harnex

    > Pi workers (GPT models by default) as tools for you and your coding agents. Hand a question or a task to a Pi worker and get the reply back in one call: `harnex ask` (read-only), `harnex delegate [--worktree NAME]` (does the task, optionally in its own git worktree), `harnex result` (collect parallel lanes), `harnex reply NAME` (follow up; the worker keeps its context), `harnex land` (merge a worktree lane and clean up), `harnex discard`, `harnex lanes`. Every command prints the worker's reply and a `── NAME:` footer naming the next command. Exit codes: 0 done, 1 failed, 2 usage error, 124 still working (run `harnex result NAME`). `harnex mcp install` exposes the same verbs as MCP tools to Claude Code and Pi.

    Version #{VERSION}. Install: `gem install harnex` (Ruby 3.x, no dependencies; needs Pi 0.80.4+ and tmux).

    ## Docs

    #{links.join("\n")}

    ## Optional

    - [Source](#{GITHUB})
    - [Full text of the main guides](#{SITE_URL}/llms-full.txt)
  TEXT
  full = PAGES.first(5).map { |page| "# #{page[:title]}\n\nSource: #{SITE_URL}#{page[:url]}\n\n#{doc_markdown(page)}" }
  write("llms-full.txt", full.join("\n\n---\n\n"))
end

def copy_assets
  FileUtils.mkdir_p(File.join(WEB, "assets"))
  FileUtils.cp(Dir[File.join(SRC, "assets", "*")], File.join(WEB, "assets"))
  FileUtils.mkdir_p(File.join(WEB, "fonts"))
  FileUtils.cp(Dir[File.join(SRC, "fonts", "*")], File.join(WEB, "fonts"))
end

def write_service_worker
  sw = File.read(File.join(SRC, "sw.js")).gsub("__BUILD__", BUILD)
  write("sw.js", sw)
end

# Generated files are rebuilt from scratch; the identity set that
# `holm app identity generate` recorded in holm.generated.json is kept.
def clean
  identity = begin
    JSON.parse(File.read(File.join(APP, "holm.generated.json"))).fetch("outputs", {}).keys
  rescue Errno::ENOENT, JSON::ParserError
    []
  end
  keep = identity.map { |path| File.join(APP, path) }
  Dir.glob(File.join(WEB, "**", "*")).sort.reverse_each do |file|
    next if keep.include?(file)

    File.directory?(file) ? (Dir.empty?(file) && Dir.rmdir(file)) : File.delete(file)
  end
end

inputs = Dir[File.join(SRC, "**", "*")].select { |f| File.file?(f) } +
         PAGES.filter_map { |page| page[:src].is_a?(String) && File.join(ROOT, page[:src]) } +
         Dir[File.join(ROOT, "lib", "**", "*.rb")] + [__FILE__]
BUILD = Digest::SHA256.hexdigest(inputs.sort.map { |f| Digest::SHA256.file(f).hexdigest }.join)[0, 10]

clean
copy_assets
build_home
build_docs
build_not_found
build_llms
write_service_worker
puts "built harnex #{VERSION} site (#{BUILD}) into #{APP.delete_prefix("#{ROOT}/")}: " \
     "#{Dir.glob(File.join(WEB, '**', '*')).count { |f| File.file?(f) }} files"
