# encoding: utf-8

module Train
  class File
    class Remote < Train::File
      def basename(suffix = nil, sep = '/')
        fail 'Not yet supported: Suffix in file.basename' unless suffix.nil?
        @basename ||= detect_filename(path, sep || '/')
      end

      def stat
        return @stat if defined?(@stat)
        @stat = Train::Extras::Stat.stat(@spath, @backend, @follow_symlink)
      end

      # helper methods provided to any implementing class
      private

      def detect_filename(path, sep)
        idx = path.rindex(sep)
        return path if idx.nil?
        idx += 1
        return detect_filename(path[0..-2], sep) if idx == path.length
        path[idx..-1]
      end
    end
  end
end
