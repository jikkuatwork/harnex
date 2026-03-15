module Harnex
  Message = Struct.new(:id, :text, :submit, :enter_only, :force, :queued_at, :status, :delivered_at, :error, keyword_init: true) do
    def to_h
      {
        id: id,
        status: status.to_s,
        queued_at: queued_at&.iso8601,
        delivered_at: delivered_at&.iso8601,
        text_preview: preview_text,
        error: error
      }
    end

    private

    def preview_text(limit = 80)
      compact = text.to_s.gsub(/\s+/, " ").strip
      return compact if compact.length <= limit

      "#{compact[0, limit - 3]}..."
    end
  end
end
