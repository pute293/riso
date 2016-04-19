# coding: utf-8

require 'stringio'
require_relative './datetime'
require_relative './filerecord'

module Riso

class DescriptorBase
  
  def initialize(iso, desc)
    @iso = iso
    @descriptor_type = desc[0].ord
    @descriptor_id = desc[1, 5]
    @descriptor_version = desc[6].ord
    @info = [:descriptor_type, :descriptor_id, :descriptor_version]
  end
  
  def to_s
    s = ''
    @info.each do |sym|
      v = instance_variable_get("@#{sym}")
      v = "#{v} (0x#{v.to_s(16)})" if v.kind_of?(Integer)
      s << "#{sym}: #{v.to_s.encode(Riso.external_encoding)}\n"
    end
    s
  end
  
  private
  
  def dstr(s)
    if /\A[\dA-Z_]*\z/ =~ s
      s.dup.force_encoding('US-ASCII')
    else
      unless Riso.strict
        s1 = s.dup.force_encoding('US-ASCII')
        return s1 if s1.valid_encoding?
      end
      raise DStringError, s
    end
  end
  
  def astr(s)
    if /\A[\dA-Z_ !"%&'\(\)\*\+,\-\.\/:;<=>\?]*\z/ =~ s
      s.dup.force_encoding('US-ASCII')
    else
      unless Riso.strict
        s1 = s.dup.force_encoding('US-ASCII')
        return s1 if s1.valid_encoding?
      end
      raise AStringError, s
    end
  end
  
  def fileid(s)
    if /\A[\dA-Z_\.\?]*\z/ =~ s
      s.dup.force_encoding('US-ASCII')
    else
      unless Riso.strict
        s1 = s.dup.force_encoding('US-ASCII')
        return s1 if s1.valid_encoding?
      end
      raise EncodingError, s
    end
    
  end
  
end

class BootRecord < DescriptorBase
  
  def initialize(iso, desc)
    super
    @system_id = astr(desc[7, 32]).rstrip
    @boot_id = dstr(desc[39, 32]).rstrip
    @info.push(:system_id, :boot_id)
  end
  
end

class VolumeDescriptor < DescriptorBase
  
  attr_reader :system_id, :volume_id, :block_count, :volume_count, :volume_index
  attr_reader :block_size, :path_table_size, :lpath, :lpath_opt, :mpath, :mpath_opt
  attr_reader :root, :volume_set, :publisher, :editor, :application_id, :copyright, :abstract, :biblio
  attr_reader :encoding_le, :encoding_be, :path_table
  attr_reader :susp_skip
  
  def initialize(iso, desc)
    super
    io = StringIO.new(desc, 'rb:ASCII-8BIT')
    io.read(8)
    @system_id = astr(io.read(32)).rstrip               # 40
    @volume_id = dstr(io.read(32)).rstrip
    io.read(8)                                          # 80
    @block_count = io.read(8).unpack('L<')[0]
    io.read(32)                                         # 120
    @volume_count = io.read(4).unpack('S<')[0]
    @volume_index = io.read(4).unpack('S<')[0]
    @block_size = io.read(4).unpack('S<')[0]
    @path_table_size = io.read(8).unpack('L<')[0]       # 140
    @lpath, @lpath_opt, @mpath, @mpath_opt = io.read(16).unpack('L<L<L>L>')
    record_size = io.read(1).ord
    @susp_skip = 0  # IEEE P1281; skip bytes of System Use Area in Directory Descriptor
    #@root = FileRecord.new(@iso, self, record_size.chr + io.read(record_size - 1))
    _root = io.read(record_size - 1)
    @volume_set = dstr(io.read(128)).rstrip
    @publisher = astr(io.read(128)).rstrip
    @editor = astr(io.read(128)).rstrip
    @application_id = astr(io.read(128)).rstrip
    @copyright = fileid(io.read(37)).rstrip
    @abstract = fileid(io.read(37)).rstrip
    @biblio = fileid(io.read(37)).rstrip
    @creation_time     = DateTimeL.new(io.read(17))
    @modification_time = DateTimeL.new(io.read(17))
    @expiration_time   = DateTimeL.new(io.read(17))
    @effective_time    = DateTimeL.new(io.read(17))
    
    @encoding_le, @encoding_be = get_encoding
    construct_path_table
    @root = @path_table.root
    
    @info.push(*%i{ system_id volume_id block_count volume_count volume_index block_size path_table_size
                   lpath mpath lpath_opt mpath_opt root volume_set publisher editor application_id copyright abstract biblio
                   creation_time modification_time expiration_time effective_time })
    
    @rr = @root.rockridge?
    @joilet = false
    
    if @root.susp[:SP]
      # SUSP/RockRidge extension
      @susp_skip = @root.susp[:SP][:skip] || 0
    end
  end
  
  def rockridge?
    @rr
  end
  
  def joilet?
    @joilet
  end
  
  private
  
  def construct_path_table
    l = @lpath == 0 ? nil : @lpath
    m = @mpath == 0 ? nil : @mpath
    lo = @lpath_opt == 0 ? nil : @lpath_opt
    mo = @mpath_opt == 0 ? nil : @mpath_opt
    @path_table = case
    when @lpath != 0 then TypeL.new(@iso, self, @lpath)
    when @mpath != 0 then TypeM.new(@iso, self, @mpath)
    when @lpath_opt != 0 then TypeL.new(@iso, self, @lpath_opt)
    when @mpath_opt != 0 then TypeM.new(@iso, self, @mpath_opt)
    else raise ISO9660Error, 'Path Table not found'
    end
  end
  
end

class PrimaryVolumeDescriptor < VolumeDescriptor
  
  attr_reader :supplements
  
  def initialize(iso, desc)
    super
    @supplements = []
  end
  
  private
  
  def get_encoding
    [nil, nil]
  end
  
end

class SupplementaryVolumeDescriptor < VolumeDescriptor
  
  attr_reader :pvd, :volume_flag, :escape_sequence
  
  def initialize(iso, desc)
    @volume_flag = desc[7].ord
    @escape_sequence = desc[88, 32].rstrip
    # ECMA-119 §8.5.6
    #   "If all the bytes of this field are set to (00), it shall mean that the set of a1-characters is
    #    identical with the set of a-characters and that the set of d1-characters is identical
    #    with the set of d-characters. In this case both sets are coded according to ECMA-6."
    
    super
    @info.push(:volume_flag, :escape_sequence)
  end
  
  private
  
  def dstr(s); s.b end
  def astr(s); s.b end
  def fileid(s); s.b end
  def set_pvd(pvd); @pvd = pvd end
  def get_encoding
    joilet = false
    le, be = case @escape_sequence
    when /\A\x1b?%\/[@CE]\z/
      joilet = true
      ['utf-16be', 'utf-16be']  # Joilet extention
    when /\A\x1b?%\/[JKL]\z/ then ['utf-16le', 'utf-16be']
    when /\A\x1b?%\/[ADF]\z/ then ['utf-32le', 'utf-32be']
    when /\A\x1b?%\/[GHI]\z/ then ['utf-8', 'utf-8']
    when /\A\x1b?%G\z/       then ['utf-8', 'utf-8']
    else nil
    end
    
    if joilet
      @joilet = true
      %i{ system_id volume_id volume_set publisher editor
       application_id copyright abstract biblio }.each {|attr| instance_variable_set("@#{attr}", instance_variable_get("@#{attr}").force_encoding('utf-16be').encode('utf-8'))}
    end
    
    [le, be]
  end
end

class VolumePartitionDescriptor < DescriptorBase
  
  def initialize(iso, desc)
    super
    @system_id = astr(desc[8, 32]).rstrip
    @partition_id = dstr(desc[40, 32]).rstrip
    @location = desc[72, 8].unpack('L<')[0]
    @size = desc[80, 8].unpack('L<')[0]
    @info.push(*%i{ system_id partition_id location size })
  end
  
end

class BeginningExtendedAreaDescriptor < DescriptorBase
end

class TerminatingExtendedAreaDescriptor < DescriptorBase
end

class BootDescriptor < DescriptorBase
end

class NsrDescriptor < DescriptorBase
end

class Nsr02Descriptor < NsrDescriptor
end

class Nsr03Descriptor < NsrDescriptor
end

class CdwDescriptor < DescriptorBase
end

class Cdw02Descriptor < CdwDescriptor
end

end
