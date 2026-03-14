require "json"
require "socket"

module Harnex
  class ApiServer
    def initialize(session)
      @session = session
      @server = TCPServer.new(session.host, session.port)
      @server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      @thread = nil
    end

    def start
      @thread = Thread.new do
        loop do
          socket = @server.accept
          Thread.new(socket) { |client| handle(client) }
        rescue IOError, Errno::EBADF
          break
        end
      end
    end

    def stop
      @server.close
      @thread&.join(1)
    rescue IOError, Errno::EBADF
      nil
    end

    private

    def handle(client)
      request_line = client.gets("\r\n")
      return unless request_line

      method, target, = request_line.split(" ", 3)
      headers = {}
      while (line = client.gets("\r\n"))
        line = line.strip
        break if line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.to_s.strip
      end

      body = +""
      length = headers.fetch("content-length", "0").to_i
      body = client.read(length) if length.positive?

      path = target.to_s.split("?", 2).first

      case [method, path]
      when ["GET", "/health"], ["GET", "/status"]
        return unauthorized(client) unless authorized?(headers)

        json(client, 200, @session.status_payload)
      when ["POST", "/exit"]
        return unauthorized(client) unless authorized?(headers)

        result = @session.inject_exit
        json(client, 200, result.merge(ok: true, signal: "exit_sequence_sent"))
      when ["POST", "/send"]
        return unauthorized(client) unless authorized?(headers)

        payload = parse_send_body(headers, body)
        if payload[:mode] == :adapter
          return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty? && !payload[:enter_only]

          result = @session.inbox.enqueue(
            text: payload[:text],
            submit: payload[:submit],
            enter_only: payload[:enter_only],
            force: payload[:force]
          )
          http_code = result.delete(:http_status) || 200
          json(client, http_code, result)
        else
          return json(client, 400, ok: false, error: "text is required") if payload[:text].to_s.empty?

          json(client, 200, @session.inject(payload[:text], newline: payload[:newline]))
        end
      else
        if method == "GET" && path =~ %r{\A/messages/([a-f0-9]+)\z}
          return unauthorized(client) unless authorized?(headers)

          msg_id = Regexp.last_match(1)
          msg = @session.inbox.message_status(msg_id)
          if msg
            json(client, 200, msg)
          else
            json(client, 404, ok: false, error: "message not found")
          end
        else
          json(client, 404, ok: false, error: "not found")
        end
      end
    rescue JSON::ParserError
      json(client, 400, ok: false, error: "invalid json")
    rescue ArgumentError => e
      json(client, 409, ok: false, error: e.message)
    rescue StandardError => e
      json(client, 500, ok: false, error: e.message)
    ensure
      client.close unless client.closed?
    end

    def parse_send_body(headers, body)
      if headers["content-type"].to_s.include?("application/json")
        parsed = JSON.parse(body.empty? ? "{}" : body)
        if parsed.key?("submit") || parsed.key?("enter_only") || parsed.key?("force")
          {
            mode: :adapter,
            text: parsed["text"].to_s,
            submit: parsed.fetch("submit", true),
            enter_only: parsed.fetch("enter_only", false),
            force: parsed.fetch("force", false)
          }
        else
          {
            mode: :legacy,
            text: parsed["text"].to_s,
            newline: parsed.fetch("newline", true)
          }
        end
      else
        {
          mode: :legacy,
          text: body.to_s,
          newline: true
        }
      end
    end

    def authorized?(headers)
      @session.auth_ok?(headers["authorization"].to_s)
    end

    def unauthorized(client)
      json(client, 401, ok: false, error: "unauthorized")
    end

    def json(client, code, payload)
      body = JSON.generate(payload)
      client.write("HTTP/1.1 #{code} #{http_reason(code)}\r\n")
      client.write("Content-Type: application/json\r\n")
      client.write("Content-Length: #{body.bytesize}\r\n")
      client.write("Connection: close\r\n")
      client.write("\r\n")
      client.write(body)
    end

    def http_reason(code)
      {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        409 => "Conflict",
        404 => "Not Found",
        500 => "Internal Server Error"
      }.fetch(code, "OK")
    end
  end
end
