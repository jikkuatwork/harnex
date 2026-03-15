require_relative "../test_helper"

class WatcherTest < Minitest::Test
  def test_available_always_true
    assert Harnex::Watcher.available?
  end

  def test_backend_returns_symbol
    backend = Harnex::Watcher.backend
    assert_includes %i[inotify polling], backend
  end

  def test_inotify_available_on_linux
    if RUBY_PLATFORM.include?("linux")
      assert Harnex::Inotify.available?
      assert_equal :inotify, Harnex::Watcher.backend
    else
      refute Harnex::Inotify.available?
      assert_equal :polling, Harnex::Watcher.backend
    end
  end

  def test_polling_always_available
    assert Harnex::Polling.available?
  end

  def test_inotify_constants_accessible
    assert_equal 0x00000004, Harnex::Inotify::IN_ATTRIB
    assert_equal 0x00000008, Harnex::Inotify::IN_CLOSE_WRITE
    assert_equal 0x00000100, Harnex::Inotify::IN_CREATE
    assert_equal 0x00000080, Harnex::Inotify::IN_MOVED_TO
  end
end

class PollingIOTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("harnex-poll-test")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_detects_new_file
    io = Harnex::Polling::PollingIO.new(@dir)
    thread = Thread.new { io.readpartial(4096) }

    sleep 0.1
    File.write(File.join(@dir, "test.txt"), "hello")

    result = thread.value
    assert_kind_of String, result
    assert result.bytesize > 0

    # Verify it encodes the filename in inotify event format
    assert result.include?("test.txt")
    io.close
  end

  def test_detects_modified_file
    File.write(File.join(@dir, "existing.txt"), "v1")
    io = Harnex::Polling::PollingIO.new(@dir)
    thread = Thread.new { io.readpartial(4096) }

    sleep 0.1
    File.write(File.join(@dir, "existing.txt"), "v2 longer")

    result = thread.value
    assert result.include?("existing.txt")
    io.close
  end

  def test_close_raises_on_read
    io = Harnex::Polling::PollingIO.new(@dir)
    io.close
    assert io.closed?
    assert_raises(IOError) { io.readpartial(4096) }
  end

  def test_close_interrupts_blocking_read
    io = Harnex::Polling::PollingIO.new(@dir)
    thread = Thread.new do
      io.readpartial(4096)
    rescue IOError
      :interrupted
    end

    sleep 0.2
    io.close
    assert_equal :interrupted, thread.value
  end

  def test_encode_events_matches_inotify_format
    io = Harnex::Polling::PollingIO.new(@dir)
    thread = Thread.new { io.readpartial(4096) }

    sleep 0.1
    File.write(File.join(@dir, "a.txt"), "data")

    result = thread.value
    # Should have at least one 16-byte header + filename
    assert result.bytesize >= 16 + 5 # "a.txt"

    # Parse the header
    _wd, mask, _cookie, name_len = result.byteslice(0, 16).unpack("iIII")
    assert_equal Harnex::Inotify::IN_CLOSE_WRITE, mask
    assert name_len > 0

    name = result.byteslice(16, name_len).delete("\0")
    assert_equal "a.txt", name
    io.close
  end
end
