require "json"
require "net/http"

require_relative "../../test_helper"

class ApiServerTest < Minitest::Test
  class FakeInbox
    def initialize(messages = [])
      @messages = messages.map(&:dup)
    end

    def pending_messages
      @messages.map(&:dup)
    end

    def drop(message_id)
      index = @messages.index { |message| message[:id] == message_id }
      return nil unless index

      message = @messages.delete_at(index)
      message[:status] = "dropped"
      message
    end

    def clear
      count = @messages.length
      @messages.clear
      count
    end

    def message_status(message_id)
      @messages.find { |message| message[:id] == message_id }&.dup
    end
  end

  class FakeSession
    attr_reader :host, :port, :token, :inbox

    def initialize(host:, port:, token:, inbox:)
      @host = host
      @port = port
      @token = token
      @inbox = inbox
    end

    def auth_ok?(header)
      header == "Bearer #{token}"
    end

    def status_payload
      { ok: true }
    end
  end

  def setup
    @host = "127.0.0.1"
    @port = Harnex.allocate_port(Dir.pwd, "api-server-test-#{SecureRandom.hex(4)}", nil, host: @host)
    @token = "secret-token"
    messages = [
      {
        id: "a1b2c3d4",
        status: "queued",
        queued_at: Time.now.iso8601,
        delivered_at: nil,
        text_preview: "first message",
        error: nil
      },
      {
        id: "deadbeef",
        status: "queued",
        queued_at: Time.now.iso8601,
        delivered_at: nil,
        text_preview: "second message",
        error: nil
      }
    ]
    @session = FakeSession.new(host: @host, port: @port, token: @token, inbox: FakeInbox.new(messages))
    @server = Harnex::ApiServer.new(@session)
    @server.start
    sleep 0.05
  end

  def teardown
    @server&.stop
  end

  def test_get_inbox_lists_pending_messages
    response = request("GET", "/inbox")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["ok"]
    assert_equal 2, body["messages"].length
    assert_equal "first message", body["messages"][0]["text_preview"]
  end

  def test_delete_inbox_message_drops_specific_pending_message
    response = request("DELETE", "/inbox/a1b2c3d4")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["ok"]
    assert_equal "dropped", body["message"]["status"]

    list_response = request("GET", "/inbox")
    list_body = JSON.parse(list_response.body)
    assert_equal ["deadbeef"], list_body["messages"].map { |message| message["id"] }
  end

  def test_delete_inbox_clears_all_pending_messages
    response = request("DELETE", "/inbox")
    body = JSON.parse(response.body)

    assert_equal "200", response.code
    assert_equal true, body["ok"]
    assert_equal 2, body["cleared"]

    list_response = request("GET", "/inbox")
    list_body = JSON.parse(list_response.body)
    assert_empty list_body["messages"]
  end

  private

  def request(method, path)
    uri = URI("http://#{@host}:#{@port}#{path}")
    request_class = {
      "GET" => Net::HTTP::Get,
      "DELETE" => Net::HTTP::Delete
    }.fetch(method)
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{@token}"

    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end
end
