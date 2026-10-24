#!/usr/bin/env ruby
# frozen_string_literal: true

# Draws the 1200x630 social card, site/src/assets/og.png, from
# src/templates/card.erb with a headless Chrome: the app icon, the wordmark,
# the tagline and the hero terminal. layout.erb names it in og:image and
# twitter:image, which win over the social_preview.png Holm generates.
# Dev tooling, like build.rb; run it after changing the card, the symbol or
# iconStyle (and `holm app identity generate site/app`), then run build.rb.
#
#   ruby site/card.rb
#
# Set CHROME to a Chrome, Chromium or chrome-headless-shell binary, or have
# one on PATH (Playwright's downloads are found too).

require "base64"
require "erb"
require "fileutils"
require "tmpdir"

SITE = __dir__
SRC = File.join(SITE, "src")
OUT = File.join(SRC, "assets", "og.png")
ICON = File.join(SITE, "app", "web", "icon-512.png")
WIDTH = 1200
HEIGHT = 630

def fail!(message)
  warn message
  exit 1
end

def data_url(file, type)
  "data:#{type};base64,#{Base64.strict_encode64(File.binread(file))}"
end

def on_path(name)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }
     .find { |bin| File.executable?(bin) }
end

# Playwright's headless shell before a system Chromium, which may be a snap
# that can't read the temp folder.
def chrome
  return ENV["CHROME"] if ENV["CHROME"]

  on_path("chrome-headless-shell") ||
    Dir[File.expand_path("~/.cache/ms-playwright/chromium_headless_shell-*/*/chrome-headless-shell")].max ||
    %w[google-chrome chromium chromium-browser].filter_map { |name| on_path(name) }.first ||
    fail!("No headless Chrome found. Set CHROME to a Chrome, Chromium or chrome-headless-shell binary.")
end

fail!("#{ICON} is missing; run `holm app identity generate site/app` first") unless File.exist?(ICON)
font = %w[Regular Bold ExtraBold].to_h do |weight|
  [weight, data_url(File.join(SRC, "fonts", "JetBrainsMono-#{weight}.woff2"), "font/woff2")]
end
icon = data_url(ICON, "image/png")
html = ERB.new(File.read(File.join(SRC, "templates", "card.erb"))).result(binding)

FileUtils.rm_f(OUT)
Dir.mktmpdir("harnex-card-") do |dir|
  page = File.join(dir, "card.html")
  File.write(page, html)
  system(chrome, "--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
         "--window-size=#{WIDTH},#{HEIGHT}", "--virtual-time-budget=3000", "--screenshot=#{OUT}", "file://#{page}",
         out: File::NULL, err: File::NULL)
end
fail!("Chrome wrote no #{OUT}; set CHROME to another browser") unless File.exist?(OUT)
size = File.binread(OUT, 8, 16).unpack("NN")
fail!("#{OUT}: Chrome drew #{size.join('x')}, not #{WIDTH}x#{HEIGHT}") unless size == [WIDTH, HEIGHT]
puts "#{OUT.delete_prefix("#{File.dirname(SITE)}/")}  #{File.size(OUT) / 1024} KB"
