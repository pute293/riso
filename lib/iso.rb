# coding: utf-8

require 'stringio'
require_relative './descriptor'
require_relative './volume'

# = ISO image extractor
# Author:: pute
# License:: zlib
# 
# usage:
#   # open iso image
#   iso = Riso.open('ubuntu.iso')
#  
#   # enumerate volumes in an iso image
#   iso.volumes.each do |volume|
#     puts volume.name
#     puts volume
#     
#     # enumerate files in a volume (you can also use #each method)
#     volume.each_file.with_index do |file, idx|
#       # dump file content
#       IO.binwrite(idx.to_s, file.dump)
#     end
#   end
#
module Riso

class ISO9660Error < Exception; end
class EncodingError < ISO9660Error; end
class AStringError < EncodingError; end
class DStringError < EncodingError; end

  # open ISO image at path
  def self.open(path, sector_size=2048)
    ISO.new(Kernel.open(path, 'rb:ASCII-8BIT'), sector_size)
  end
  
  # open ISO image from binary blob
  def self.from_blob(binary, sector_size=2048)
    ISO.new(StringIO.new(binary, 'rb:ASCII-8BIT'), sector_size)
  end
  
  def self.strict
    @strict
  end
  
  def self.strict=(v)
    @strict = v
  end
  
  # get standard output encoding
  def self.external_encoding
    @encoding
  end
  
  # set standard output encoding
  def self.external_encoding=(enc)
    @encoding = enc
  end
  
  # get default directory permission (set to dumped directory)
  def directory_mode
    @st_mode_dir
  end
  
  # set default directory permission (set to dumped directory)
  def directory_mode=(st_mode)
    @st_mode_dir = st_mode
  end
  
  # get default file permission (set to dumped file)
  def file_mode
    @st_mode_file
  end
  
  # set default file permission (set to dumped file)
  def file_mode=(st_mode)
    @st_mode_file = st_mode
  end
  
  @strict = false
  @encoding = Encoding.default_external
  @st_mode_dir  = 0o755 | 0o004000  # drwxr-xr-x
  @st_mode_file = 0o644 | 0o100000  # -rw-r--r--

# main class to handle ISO image file
class ISO
  
  attr_reader :sector_size, :descriptors, :volumes
  
  # - [io: IO-like object]
  # - [sector_size: Integer] logical sector size
  def initialize(io, sector_size)
    @io = io
    @sector_size = sector_size
    parse(io)
  end
  
  # move file pointer to head of specified sector
  # - [n: Integer] logical sector number
  def sector!(n)
    @io.seek(sector_size * n)
  end
  
  # get file position
  # - return: [Integer]
  def pos; @io.pos end
  
  # move file position
  # see IO#seek
  def seek(offset, wherece=IO::SEEK_SET)
    @io.seek(offset, wherece)
  end
  
  # read binary from image file
  # see IO#read
  def read(length, outbuf='')
    outbuf.force_encoding('ASCII-8BIT') if @io.binmode?
    @io.read(length, outbuf)
  end
  
  # get n-th volume
  def [](n)
    volumes[n]
  end
  
  # enumerate all volumes this image file consists of
  # - return: [Volume]
  def each_volume
    return enum_for(__method__) unless block_given?
    volumes.each{|vol| yield vol}
  end
  
  alias :each :each_volume
  
  # enumerate all files in this image file
  # - return: [FileRecord]
  def each_file
    return enum_for(__method__) unless block_given?
    volumes.each do |vol|
      vol.each_file{|f| yield f}
    end
  end
  
  private
  
  # - read and parse ISO image file from input IO-like object
  # - input must be opened with binary mode and binary (ASCII-8BIT) encoding
  # - file position will be undefined if error occured
  def parse(io)
    # read System Area
    system_area = io.read(sector_size * 16)
    
    # read Volume Descriptors
    descs = Hash.new {|h,k| h[k] = []}
    last_pos = io.pos
    loop do
      io.seek(last_pos)
      desc = io.read(sector_size)
      last_pos = io.pos
      desc_type, desc = create_descriptor(desc)
      if desc
        warn "duplicated descriptor #{desc_type} was found" if (descs[desc_type] && !descs[desc_type].empty?)
        descs[desc_type] << desc
      end
      break unless desc_type
      
      # ECMA-167 §8.3.1 Note 1
      #   "The volume recognition sequence is terminated by the first sector which is not a valid descriptor,
      #    rather than by an explicit descriptor. This sector might be an unrecorded or blank sector."
    end
    io.seek(last_pos - sector_size)
    
    pvds = descs[:pvd]
    svds = descs[:svd].group_by{|svd| svd.volume_index}
    raise ISO9660Error, "Primary Volume Descriptor was not found" if (pvds.nil? || pvds.empty?)
    
    # check volume configuration mismatching
    volumes = []
    pvds.each do |pvd|
      vds = svds[pvd.volume_index]
      attrs = %i{ block_size block_count volume_count }
      raise ISO9660Error, 'multiple Primary Volume' if volumes[pvd.volume_index]
      raise ISO9660Error, 'volume configuration mismatching' if (vds && vds.any?{|svd| attrs.any?{|attr| svd.send(attr) != pvd.send(attr) }})
      pvd.supplements.push(*vds)
      vds.each{|vd| vd.send(:set_pvd, pvd)} if vds
      v = Volume.new(self, pvd)
      volumes[pvd.volume_index] = v
    end
    volumes.shift
    volumes.freeze
    descs.delete(:svd) if svds.empty?
    descs.freeze
    
    raise ISO9660Error, 'volume configuration mismatching' if volumes.any?{|vol| vol.pvd.volume_count != volumes.size}
    
    @volumes = volumes
    @descriptors = descs
  end
  
  def create_descriptor(desc)
    type = desc[0].ord
    ident = desc[1, 5]
    raise_strict ISO9660Error, "unexpected eof" if desc.bytesize < sector_size
    case ident
    when 'BEA01'.b
      raise_strict ISO9660Error, "invalid Descriptor Type #{type}; 0 expected" if type != 0
      [:bet01, BeginningExtendedAreaDescriptor.new(self, desc)]
    when 'TEA01'.b
      raise_strict ISO9660Error, "invalid Descriptor Type #{type}; 0 expected" if type != 0
      [:tea01, TerminatingExtendedAreaDescriptor.new(self, desc)]
    when 'BOOT2'.b
      raise_strict ISO9660Error, "invalid Descriptor Type #{type}; 0 expected" if type != 0
      [:boot2, BootDescriptor.new(self, desc)]
    when 'CD001'.b
      case type
      when 0 then [:boot, BootRecord.new(self, desc)]
      when 1 then [:pvd,  PrimaryVolumeDescriptor.new(self, desc)]
      when 2 then [:svd,  SupplementaryVolumeDescriptor.new(self, desc)]
      when 3 then [:vpd,  PartitionDescriptor.new(self, desc)]
      when 255
        # do nothing
        [:dummy, nil]
      else raise ISO9660Error, "invalid Descriptor Type #{type}; 0..3 expected"
      end
    when 'CDW02'.b
      [:cdw02, Cdw02Descriptor.new(self, desc)]
    when 'NSR02'.b
      [:nsr02, Nsr02Descriptor.new(self, desc)]
    when 'NSR03'.b
      [:nsr03, Nsr03Descriptor.new(self, desc)]
    #else raise ISO9660Error, "invalid Descriptor Identifier #{ident}"
    end
  end
  
  def raise_strict(klass, message)
    raise klass, message, caller(1) if Riso.strict
  end
  
end

end

