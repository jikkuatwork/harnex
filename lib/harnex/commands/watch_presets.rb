module Harnex
  module WatchPresets
    TABLE = {
      "impl" => { stall_after_s: 8 * 60.0, max_resumes: 1 }.freeze,
      "plan" => { stall_after_s: 3 * 60.0, max_resumes: 2 }.freeze,
      "gate" => { stall_after_s: 15 * 60.0, max_resumes: 0 }.freeze
    }.freeze

    def self.fetch(name)
      TABLE[name]
    end

    def self.valid_names
      TABLE.keys
    end
  end
end
