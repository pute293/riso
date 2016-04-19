# coding: utf-8

require 'fileutils'
require_relative './pathtable'

module Riso

class Volume
  
  attr_reader :name, :block_size, :block_count, :index, :pvd, :svd
  
  include Enumerable
  
  def initialize(iso, pvd)
    @iso = iso
    @name, @block_size, @block_count, @index = %i{ volume_id block_size  block_count volume_index }.collect{|sym| pvd.send(sym)}
    @pvd = pvd
    @svd = pvd.supplements
  end
  
  def descriptor
    case
    when pvd.rockridge?
      pvd
    when svd.empty?
      pvd
    else
      svd.first
    end
  end
  
  def ls
    entries = descriptor.path_table.to_a
    entries.collect {|record|
      mode = record.mode_string
      nlink = record.nlink || ??
      uid = record.uid || ??
      gid = record.gid || ??
      size = record.data_size
      time = record.time
      sym = record.symlink? ? " -> #{record.symlink}" : ''
      path = record.path + sym
      lbn = record.extent_location
      from = record.relocated_from? ? "RELOCATED" : ''
      to_lbn = record.relocated_to
      if to_lbn
        to = entries.find{|r| r.extent_location == to_lbn}
        to = "~> #{to ? to.path : ??} [LBN #{to_lbn}]"
      else
        to = ''
      end
      [mode, nlink, uid, gid, size, time, path, lbn, from, to].collect(&:to_s)
    }.transpose.collect {|strs|
      len = strs.max_by{|str|str.size}.size
      strs.collect{|str| [len, str]}
    }.transpose.collect {|mode, nlink, uid, gid, size, time, path, lbn, from, to|
      mode = mode[1].ljust(mode[0])
      nlink = nlink[1].rjust(nlink[0])
      uid = uid[1].rjust(uid[0])
      gid = gid[1].rjust(gid[0])
      size = size[1].rjust(size[0])
      time = time[1].ljust(time[0])
      path = path[1].ljust(path[0])
      lbn = "[LBN #{lbn[1].rjust(lbn[0])}]"
      from = from[1].ljust(from[0])
      to = to[1].ljust(to[0])
      "#{mode} #{nlink} #{uid} #{gid} #{size} #{time} #{path} #{lbn} #{from} #{to}".rstrip
    }.join(?\n)
  end
  
  def each_file
    return enum_for(__method__) unless block_given?
    descriptor.path_table.each {|x| yield x}
  end
  
  alias :each :each_file
  
  def binwrite(dir)
    d = Dir.pwd
    io = @iso
    begin
      dir = File.expand_path(dir)
      FileUtils.mkdir_p(dir)
      Dir.chdir(dir)
      d1 = Dir.pwd
      each_file do |record|
        Dir.chdir(d1)
        
        target_dir = record.dir.sub(/\A\/+/, '')
        unless target_dir.empty?
          FileUtils.mkdir_p(target_dir)
          Dir.chdir(target_dir)
        end
        
        if record.is_directory?
          FileUtils.mkdir_p(record.name) if !record.name.empty?
          next
        end
        
        record.binwrite
      end
    ensure
      Dir.chdir(d)
    end
  end
  
  def to_s
    <<EOS[0..-2]
Volume Name: #{name} (#{index}/#{pvd.volume_count})
  System Identifier:   #{pvd.system_id}
  Logical Block Size:  #{block_size} (0x#{block_size.to_s(16)}) bytes
  Logical Block Count: #{block_count} (0x#{block_count.to_s(16)})
  Publisher Identifier:   #{pvd.publisher}
  Editor Identifier:      #{pvd.editor}
  Application Identifier: #{pvd.application_id}
  Copyright File:         #{pvd.copyright}
  Abstract File:          #{pvd.abstract}
  Bibliographic File:     #{pvd.biblio}
EOS
  end
  
end

end
