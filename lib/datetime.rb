# coding: utf-8

module Riso

class DateTime
  
  def year
    @year
  end
  
  def month
    @month % 13
  end
  
  def day
    @day % 32
  end
  
  def hour
    @hour % 25
  end
  
  def min
    @minute % 60
  end
  
  def sec
    @second % 60
  end
  
  def csec
    @centi_second % 100
  end
  
  def zone
    dutc_hour, dutc_min = @dutc.divmod(4)
    if dutc_hour < 0 && dutc_min != 0
      dutc_hour += 1
      dutc_min = [0, 3, 2, 1][dutc_min]
    end
    dutc_min *= 15
    "#{dutc_hour < 0 ? ?- : ?+}#{'%02d' % dutc_hour.abs}:#{'%02d' % dutc_min}"
  end
  
  def d
    day.to_s
  end
  
  def dd
    '%02d' % day
  end
  
  def ddd
    raise NotImplementedError
  end
  
  def dddd
    raise NotImplementedError
  end
  
  def M
    month.to_s
  end
  
  def MM
    '%02d' % month
  end
  
  def MMM
    %w{ ??? Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec }[month]
  end
  
  def MMMM
    %w{ ? January February March April May June July August September October November December }[month]
  end
  
  def gg
    'A.D.'
  end
  
  def h
    (hour % 12).to_s
  end
  
  def hh
    '%02d' % (hour % 12)
  end
  
  def H
    hour.to_s
  end
  
  def HH
    '%02d' % hour
  end
  
  def m
    min.to_s
  end
  
  def mm
    '%02d' % min
  end
  
  def s
    sec.to_s
  end
  
  def ss
    '%02d' % sec
  end
  
  def f
    (csec / 10).to_s
  end
  
  def ff
    csec.to_s
  end
  
  def y
    (year % 1000).to_s
  end
  
  def yy
    (year % 100).to_s
  end
  
  def yyyy
    year.to_s
  end
  
  def iso8601
    "#{yyyy}-#{self.MM}-#{dd}T#{hh}:#{mm}:#{ss}#{zone}"
  end
  
  def to_s
    "#{self.MMM} #{dd} #{hh}:#{mm}"
  end
  
end

class DateTimeS < DateTime
  
  def initialize(bin)
    dy, m, d, h, mi, s, dutc = bin.unpack('C6c')
    
    @year = 1900 + (dy || 0)
    @month  = (m || 0) % 13
    @day    = (d || 0) % 32
    @hour   = (h || 0) % 25
    @minute = (mi || 0) % 60
    @second = (s || 0) % 60
    @centi_second = 0
    @dutc = dutc || 0
  end
  
end

class DateTimeL < DateTime
  
  def initialize(bin)
    y, m, d, h, mi, s, cs, dutc = bin.unpack('A4A2A2A2A2A2A2c')
    
    @year   = (y || 0).to_i
    @month  = (m || 0).to_i % 13
    @day    = (d || 0).to_i % 32
    @hour   = (h || 0).to_i % 25
    @minute = (mi || 0).to_i % 60
    @second = (s || 0).to_i % 60
    @centi_second = cs || 0
  end
  
end

end
