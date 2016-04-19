# coding: utf-8

require 'stringio'
require 'fileutils'
require_relative './datetime'

module Riso

class FileRecord
  
  attr_reader :volume, :data_size, :extent_location, :susp
  attr_accessor :encoding
  
  def initialize(iso, vd, record, parent_dir, enc=Encoding::default_external)
    @iso, @vd = iso, vd
    @root = parent_dir.nil?
    
    len = record[0].ord
    len_ear = record[1].ord
    @extent_location = record[2, 8].unpack('L<')[0]
    @data_size = record[10, 8].unpack('L<')[0]
    @datetime = DateTimeS.new(record[18, 7])
    @flag = record[25].ord
    @unit = record[26].ord
    @gap = record[27].ord
    @volume = record[28, 4].unpack('S<')[0]
    name_len = record[32].ord
    @name = record[33, name_len]
    case @name
    when "\x00" then @name = '.'
    when "\x01" then @name = '..'
    end
    pad = name_len.even? ? 1 : 0
    @dir = parent_dir
    @encoding = enc
    @susp = parse_rockridge(record[(33+name_len+pad+vd.susp_skip)..-1])
    @rr = (@susp && !@susp.empty?) ? true : false
    @susp ||= {}.freeze
    if @susp.has_key?(:NM)
      @name = @susp[:NM]
      @encoding = Encoding::UTF_8
    end
    if @susp.has_key?(:SL)
      @symlink = @susp[:SL]
    end
    
    # TODO
    raise '[REPORT] Extended Attribute Record found' if len_ear != 0
    raise '[REPORT] Associated File found' if associated_file?
    raise '[REPORT] Multi Extent File found' if multi_extent?
  end
  
  #def ==(other)
  #  return false unless other.kind_of?(FileRecord)
  #  %i{ volume data_size extent_location datetime }.all?{|sym| send(sym) == other.send(sym)}
  #end
  
  def parent
    @dir
  end
  
  def each_child
    return enum_for(__method__) unless block_given?
    @vd.path_table.each{|r| yield r if r.parent == self}
  end
  
  def children
    each_child.to_a
  end
  
  def path
    "#{dir}/#{name}".gsub(/\/+/, ?/)
  end
  
  def name
    #return '' if /\A[\x00\x01]\x00*\z/ =~ @name
    if root?
      ?/
    else
      @name.dup.force_encoding(encoding).rstrip.encode(Riso.external_encoding)
    end
  end
  
  def dir
    enc = encoding
    dirs = []
    cur = @dir
    while cur
      nm = cur.name
      dirs << nm if !nm.empty?
      cur = cur.parent
    end
    dirs.reverse.join(?/)
  end
  
  def ext
    return '' if is_directory?
    /\.([^\.]+)\z/ =~ name
    $1 ? $1.sub(/(;\d*)?\z/, '') : ''
  end
  
  def revision
    return nil if is_directory?
    /;(\d+)\z/ =~ name
    $1 ? $1.to_i : nil
  end
  
  def symlink
    case @symlink
    when :current then '.'
    when :parent  then '..'
    when :root    then '/'
    else @symlink
    end
  end
  
  def mode
    px = susp[:PX]
    if px && px[:st_mode]
      px[:st_mode]
    else
      directory? ? Riso.directory_mode : Riso.file_mode
    end
  end
  
  def mode_string
    p = mode
    owner = (p >> 6) & 7
    group = (p >> 3) & 7
    other = (p >> 0) & 7
    isvtx = p[9]  # sticky bit
    isgid = p[10] # set group id
    isuid = p[11] # set user id
    
    owner_read  = owner[2].odd? ? ?r : ?-
    owner_write = owner[1].odd? ? ?w : ?-
    owner_exec  = owner[0].odd? ? ?x : ?-
    group_read  = group[2].odd? ? ?r : ?-
    group_write = group[1].odd? ? ?w : ?-
    group_exec  = group[0].odd? ? ?x : ?-
    other_read  = other[2].odd? ? ?r : ?-
    other_write = other[1].odd? ? ?w : ?-
    other_exec  = other[0].odd? ? ?x : ?-
    
    if isgid.odd?
      group_exec = group_exec == ?x ? ?s : ?S
    end
    
    if isuid.odd?
      owner_exec = owner_exec == ?x ? ?s : ?S
    end
    
    if isvtx.odd?
      other_exec = other_exec == ?x ? ?t : ?T
    end
    
    t = case p & 0o170000
    when 0o140000 then ?s # socket
    when 0o120000 then ?l # symbolic link
    when 0o100000 then ?- # regular file
    when 0o060000 then ?b # block device
    when 0o040000 then ?d # directory
    when 0o020000 then ?c # character device
    when 0o010000 then ?p # named pipe
    else ??
    end
    
    "#{t}#{owner_read}#{owner_write}#{owner_exec}#{group_read}#{group_write}#{group_exec}#{other_read}#{other_write}#{other_exec}"
  end
  
  def nlink
    (susp[:PX] || {})[:st_nlink]
  end
  
  def uid
    (susp[:PX] || {})[:st_uid]
  end
  
  def gid
    (susp[:PX] || {})[:st_gid]
  end
  
  def time
    (susp[:TF] || {})[:mod] || @datetime
  end
  
  def rockridge?
    @rr
  end
  
  def is_root?
    @root
  end
  
  alias :root? :is_root?
  
  def interleaved?; @unit != 0 || @gap != 0 end
  
  def is_directory?; (@flag & 2) == 2 end
  
  alias :directory? :is_directory?
  
  def multi_extent?; (@flag & (2 << 7)) == (2 << 7) end
  
  def associated_file?
    (@flag & 4) == 4
  end
  
  def symlink?
    !@symlink.nil?
  end
  
  def relocated_from?
    (susp.has_key?(:RE) && !@relocation_resolved) || (parent.nil? ? false : parent.relocated_from?)
  end
  
  def relocated_to
    susp[:CL]
  end
  
  def relocate!(record)
    @dir = record.parent
    @relocation_resolved = true
  end
  
  def dump
    raise ISO9660Error, "[#{path}] invalid operation: attempt to dump relocated file" if relocated_to
    @iso.seek(extent_location * @vd.block_size)
    data = @iso.read(data_size)
    raise IOError, "[#{path}] fail to read ISO image" if (!data || data.bytesize != data_size)
    data
  end
  
  def binwrite(path=name.sub(/;\d+\z/, ''))
    case
    when directory?
      # do nothing
    when associated_file?
      raise NotImplementedError, "[#{self.path}] dumping associated file"
    when symlink?
      begin
        src = symlink
        FileUtils.ln_s(src, path)
      rescue NotImplementedError
        warn "couldn't create symbolic link (-> #{src})"
      end
    when multi_extent?
      raise NotImplementedError, "[#{self.path}] dumping multi-extent file"
    else
      # usual file
      IO.binwrite(path, dump)
    end
  end
  
  def ls
    each_child.collect {|record|
      mode = record.mode_string
      nlink = record.nlink || ??
      uid = record.uid || ??
      gid = record.gid || ??
      lbn = record.extent_location
      size = record.data_size
      time = record.time
      sym = record.symlink? ? " -> #{record.symlink}" : ''
      path = record.path + sym
      from = record.relocated_from? ? "RELOCATED" : ''
      to_lbn = record.relocated_to
      if to_lbn
        to = entries.find{|r| r.extent_location == to_lbn}
        to = "~> #{to ? to.path : ??} [LBN #{to_lbn}]"
      else
        to = ''
      end
      [mode, nlink, uid, gid, lbn, size, time, path, from, to].collect(&:to_s)
    }.transpose.collect {|strs|
      len = strs.max_by{|str|str.size}.size
      strs.collect{|str| [len, str]}
    }.transpose.collect {|mode, nlink, uid, gid, lbn, size, time, path, from, to|
      mode = mode[1].ljust(mode[0])
      nlink = nlink[1].rjust(nlink[0])
      uid = uid[1].rjust(uid[0])
      gid = gid[1].rjust(gid[0])
      lbn = "[LBN #{lbn[1].rjust(lbn[0])}]"
      size = size[1].rjust(size[0])
      time = time[1].ljust(time[0])
      path = path[1].ljust(path[0])
      from = from[1].ljust(from[0])
      to = to[1].ljust(to[0])
      "#{mode} #{nlink} #{uid} #{gid} #{lbn} #{size} #{time} #{path} #{from} #{to}".rstrip
    }.join(?\n)
  end
  
  def to_s
    #"#{mode_string} #{nlink || ??} #{uid || ??} #{gid || ??} #{'%4d' % data_size} #{time} #{path} [LBN #{'%4d' % extent_location}]".tap do |s|
    #  s << " -> #{symlink}" if symlink?
    #  #s << " RELOCATED" if relocated_from?
    #  #s << " ~> 
    #end
    inspect
  end
  
  def inspect
    "#{path} => volume: #{@volume}; block: #{@extent_location} (0x#{@extent_location.to_s(16)}); data size: #{@data_size} bytes; SUSP: #{@susp}"
  end
  
  private
  
  def warn(s)
    Kernel.warn "[#{path}] #{s}"
  end
  
  def parse_rockridge(str)
    # ref. IEEE P1281
    
    return nil if str.empty?
    
    entries = []
    
    io = StringIO.new(str, 'rb:ASCII-8BIT')
    until io.eof?
      sig = io.read(2)
      break unless /\A[A-Za-z][A-Za-z]\z/ =~ sig.to_s
      
      len = io.read(1).unpack(?C)[0]
      version = io.read(1).unpack(?C)[0]
      return nil if (len.nil? || version.nil?)
      # NOT ROCK RIDGE!
      
      data = io.read(len - 4)
      return nil if data.bytesize != len - 4
      # NOT ROCK RIDGE!
      
      sig = sig.intern
      entry = { :type => sig }
      
      case sig
      when :CE
        # other System Use Entries
        block = data[0, 8].unpack('L<L>')[0]
        offset = data[8, 8].unpack('L<L>')[0]
        size = data[16, 8].unpack('L<L>')[0]
        old_pos = @iso.pos
        @iso.seek(block * @vd.block_size + offset)
        str << @iso.read(size)
        @iso.seek(old_pos)
        next
      when :PD
        # padding entry
        # do nothing
        next
      when :SP
        # marker entry
        # "SP" System Use Entry must be at byte offset 0 or 15
        return nil if (io.pos != 7 && io.pos != 22)
        return nil if /\A\xBE\xEF.\z/n !~ data
        skip = data[2].ord
        entry[:skip] = skip
        io.seek(skip, IO::SEEK_CUR)
      when :ST
        # terminate indicator
        break
      when :ER
        # entended information
        return nil if data.bytesize < 4
        len_id, len_des, len_src, ext_ver = data.unpack('CCCC')
        #return nil if data.bytesize != 4 + len_id + len_des + len_src
        entry[:ext_ver] = ext_ver
        entry[:id] = data[4, len_id]
        entry[:descriptor] = data[4+len_id, len_des]
        entry[:source] = data[4+len_id+len_des, len_src]
      when :ES
        entry[:sequence] = data[0].ord
      when :PX
        # file attributes
        entry[:st_mode] = data[0, 8].unpack('L<')[0]
        entry[:st_nlink] = data[8, 8].unpack('L<')[0]
        entry[:st_uid] = data[16, 8].unpack('L<')[0]
        entry[:st_gid] = data[24, 8].unpack('L<')[0]
        entry[:st_ino] = data[32, 8].unpack('L<')[0]
      when :PN
        # device information
        entry[:dev_t_high] = data[0, 8].unpack('L<')[0]
        entry[:dev_t_low] = data[8, 8].unpack('L<')[0]
      when :SL
        # symbolic link information
        dio = StringIO.new(data, 'rb:ASCII-8BIT')
        flag = dio.read(1).ord
        s = ''
        comp_flag = 1
        while (comp_flag & 1) == 1
          comp_flag = dio.read(1).ord
          comp_len = dio.read(1).ord
          case comp_flag & 15
          when 0
            # end of component
            s << dio.read(comp_len)
            break
          when 1
            # continuous component
            s << dio.read(comp_len)
          when 2
            # current directory
            s = :current
            break
          when 4
            # parent directory
            s = :parent
            break
          when 8
            # root directory
            s = :root
            break
          else
            warn "invalid SL entry: #{data.inspect}"
            s = nil
            break
          end
        end
        entry[:flag] = flag
        entry[:path] = s
      when :NM
        flag = data[0].ord
        entry[:continue] = flag & 1 == 1
        entry[:current]  = flag & 2 == 2
        entry[:parent]   = flag & 4 == 4
        entry[:name] = data[1..-1]
      when :CL
        entry[:data] = data.unpack('L<')[0]
      when :PL
        next
      when :RE
        # this directory/file is relocated from another location
        # do nothing here
      when :TF
        # timestamp
        entry[:flag] = data[0].ord
        entry[:data] = data[1..-1]
      when :SF
        # sparse file
        # TODO
        warn 'Sparse File Entry exists'
        next
      else
        next
      end
      
      entries << entry
    end
    
    entries = entries.group_by{|entry| entry[:type]}
    
    # validate unique entries
    %i{ SP PX PN SF CL }.each do |word|
      if entries.has_key?(word)
        #return nil if 1 < entries[word].size
        warn "multiple SUSP Entry #{word} found" if 1 < entries[word].size
        entries[word] = entries[word].first
      end
    end
    
    # concatenate Symbolic Links
    if entries.has_key?(:SL)
      sl = entries[:SL]
      if sl.all?{|s| s[:path]}
        entries[:SL] = sl.each_with_object('') do |s, acc|
          case s[:path]
          when :current
            break :current
          when :parent
            break :parent
          when :root
            break :root
          else if (s[:flag] & 1) == 1
            acc << s[:path]
          else break acc + s[:path]
          end end
        end
      else
        # error
        entries.delete(:SL)
      end
    end
    
    # concatenate Alternative Names
    if entries.has_key?(:NM)
      nm = entries[:NM]
      if nm.any?{|n| 1 < n.values_at(:continue, :current, :parent).select{|a|a}.size}
        # no more than one of flag at bits 0, 1 and 2 shall be set to ONE
        entries.delete(:NM)
      else
        entries[:NM] = nm.each_with_object(''){|n, acc| acc << n[:name]; break acc unless n[:continue]}
      end
    end
    
    # process timestamp
    # multiple "TF" entries are allowed, but flag must be relatively prime
    if entries.has_key?(:TF)
      tf = {}
      entries[:TF].each do |entry|
        data = entry[:data]
        flag = entry[:flag]
        r = (flag & 128) == 128 ? ->(d){ d[0,17]=''; DateTimeL.new(d) } : ->(d){ d[0,7]=''; DateTimeS.new(d) }
        tf[:creation]  = r.(data) if (flag & 1) == 1
        tf[:mod]       = r.(data) if (flag & 2) == 2
        tf[:access]    = r.(data) if (flag & 4) == 4
        tf[:attr]      = r.(data) if (flag & 8) == 8
        tf[:backup]    = r.(data) if (flag & 16) == 16
        tf[:expire]    = r.(data) if (flag & 32) == 32
        tf[:effective] = r.(data) if (flag & 64) == 64
      end
      entries[:TF] = tf
    end
    
    if entries.has_key?(:CL)
      entries[:CL] = entries[:CL][:data]
    end
    
    entries.tap{|k,v| v.freeze}.freeze
  end
  
end

end
