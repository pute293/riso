# coding: utf-8

require_relative './descriptor'
require_relative './filerecord'

module Riso

class PathTable
  
  attr_reader :root
  
  def initialize(iso, vd, block, encoding_le)
    dirs = [nil]
    @iso = iso
    @vd = vd
    @le = encoding_le
    
    # retrieve only a root directory now
    # because a Path Table Record does not contain extended path
    iso.seek(block * vd.block_size)
    root = read_entry(iso)
    iso.seek(root[:offset])
    len, @root = read_dir(iso, nil)
    @records = resolve_relocation(each_file.to_a)
  end
  
  def each
    return enum_for(__method__) unless block_given?
    @records.each{|r| yield r}
  end
  
  include Enumerable
  
  def to_s
    "Path Table of Volume <#{@vd.volume_id.encode(Riso.external_encoding)}>"
    #enc = @le ? @vd.encoding_le : @vd.encoding_be
    #
    #hdr = "Path Table of Volume <#{@vd.volume_id.encode(Riso.external_encoding)}>"
    #return hdr if directories.empty?
    #
    #if enc
    #  max_len = directories.max_by{|entry| entry[:name].dup.force_encoding(enc).encode(Riso.external_encoding).size}[:name].dup.force_encoding(enc).encode(Riso.external_encoding).size
    #  fmt = "%-#{max_len}s"
    #  hdr + directories.collect {|dir| "\n  #{fmt % (dir[:name].empty? ? ?/ : dir[:name].dup.force_encoding(enc).encode(Riso.external_encoding))}  [offset=#{dir[:offset]} (0x#{dir[:offset].to_s(16)})]"}.join
    #else
    #  max_len = directories.max_by{|entry| entry[:name].size}[:name].size
    #  fmt = "%-#{max_len}s"
    #  hdr + directories.collect {|dir| "\n  #{fmt % (dir[:name].empty? ? ?/ : dir[:name])}  [offset=#{dir[:offset]} (0x#{dir[:offset].to_s(16)})]"}.join
    #end
  end
  
  private
  
  def each_file
    # a Directory Record can NOT straddle logical sectors
    # (i.e. each Directory Record must end in the logical sector in which it begins)
    
    return enum_for(__method__) unless block_given?
    
    io = @iso
    bs = @vd.block_size
    
    dirs = [root]
    until dirs.empty?
      dir_record = dirs.shift
      
      pos0 = dir_record.extent_location * bs
      pos = pos0
      
      # current directory
      io.seek(pos)
      len, current = read_dir(io, dir_record)
      pos += len
      
      # parent directory
      io.seek(pos)
      len, parent = read_dir(io, dir_record.parent)
      if parent.nil?
        # goto next logical block
        pos = (pos + bs - 1) & ~(bs - 1)
        io.seek(pos)
        len, parent = read_dir(io, dir_record.parent)
      end
      pos += len
      
      # total bytes in this Directory Record extent
      size = dir_record.data_size
      remain_bytes = size - (pos - pos0)
      
      while 0 < remain_bytes
        io.seek(pos)
        len, record = read_dir(io, dir_record)
        if record.nil?
          pos = (pos + bs - 1) & ~(bs - 1)
          remain_bytes = size - (pos - pos0)
          next
        end
        pos += len
        remain_bytes = size - (pos - pos0)
        
        dirs << record if record.directory?
        
        yield record
      end
    end
  end
  
  def resolve_relocation(records)
    relocated_to = records.select(&:relocated_to).to_a
    resolved = []
    relocated_to.each do |to|
      lbn = to.relocated_to
      from = records.find{|rr| rr.extent_location == lbn}
      if from
        from.relocate!(to)
        resolved << to
      else
        warn "[#{to.path}] invalid relocation (Directory Record at LBN #{lbn} was not found)"
      end
    end
    records.select{|r| !resolved.include?(r)}
  end
  
  def read_entry(io)
    # a Path Table Entry can straddle logical sectors
    # (i.e. each Path Table Entry can end in the logical sector in which it does NOT begin)
    
    len = io.read(1).ord
    if len.zero?
      #io.seek(-1, IO::SEEK_CUR)
      return nil
    end
    ex_attr_len = io.read(1).ord
    block_offset = read32(io)
    offset = @vd.block_size * block_offset
    parent = read16(io)
    nm = io.read(len)
    io.read(1) if len.odd?
    { :name => nm.gsub(/\A[\x00\x01]\z/, ''), :block_offset => block_offset, :offset => offset, :parent => parent }
  end
  
  def read_dir(io, parent_dir)
    len = io.read(1).ord
    return [0, nil] if len == 0
    
    r = if @vd.encoding_le
      FileRecord.new(@iso, @vd, len.chr + io.read(len - 1), parent_dir, @le ? @vd.encoding_le : @vd.encoding_be)
    else
      FileRecord.new(@iso, @vd, len.chr + io.read(len - 1), parent_dir)
    end
    
    [len, r]
  end
  
end

class TypeL < PathTable
  
  def initialize(iso, vd, block)
    super(iso, vd, block, true)
  end
  
  private
  
  def read32(io); io.read(4).unpack('L<')[0] end
  
  def read16(io); io.read(2).unpack('S<')[0] end
  
end

class TypeM < PathTable
  
  def initialize(iso, vd, block)
    super(iso, vd, block, false)
  end
  
  private
  
  def read32(io); io.read(4).unpack('L>')[0] end
  
  def read16(io); io.read(2).unpack('S>')[0] end
  
end

end

