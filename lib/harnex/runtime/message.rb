module Harnex
  Message = Struct.new(:id, :text, :submit, :enter_only, :force, :queued_at, :status, :delivered_at, :error, keyword_init: true) do
    def to_h
      {
        id: id,
        status: status.to_s,
        queued_at: queued_at&.iso8601,
        delivered_at: delivered_at&.iso8601,
        error: error
      }
    end
  end
end
