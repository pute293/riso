# coding: utf-8

module Riso

class DateTimeS
  
  def initialize(bin)
    dy, m, d, h, mi, s, dutc = bin.unpack('C6c')
    
    @year = 1900 + (dy || 0)
    @month  = (m || 0) % 13
    @day    = (d || 0) % 32
    @hour   = (h || 0) % 24
    @minute = (mi || 0) % 60
    @second = (s || 0) % 60
    dutc_hour, dutc_minute = (dutc || 0).divmod(4)
    if dutc_hour < 0 && dutc_minute != 0
      dutc_hour += 1
      dutc_minute = [0, 3, 2, 1][dutc_minute]
    end
    dutc_minute *= 15
    @utc = "#{dutc_hour < 0 ? ?- : ?+}#{'%02d' % dutc_hour.abs}:#{'%02d' % dutc_minute}"
  end
  
  def to_s
    '%04d-%02d-%02dT%02d:%02d:%02d%s' % [@year, @month, @day, @hour, @minute, @second, @utc]
  end
  
  alias :inspect :to_s
  
end

class DateTimeL
  
  def initialize(bin)
    y, m, d, h, mi, s, cs, dutc = bin.unpack('A4A2A2A2A2A2A2c')
    
    @year   = (y || 0).to_i
    @month  = (m || 0).to_i % 13
    @day    = (d || 0).to_i % 32
    @hour   = (h || 0).to_i % 24
    @minute = (mi || 0).to_i % 60
    @second = (s || 0).to_i % 60
    @centi_second = cs ? ".#{cs}" : ''
    dutc_hour, dutc_minute = (dutc || 0).divmod(4)
    if dutc_hour < 0 && dutc_minute != 0
      dutc_hour += 1
      dutc_minute = [0, 3, 2, 1][dutc_minute]
    end
    dutc_minute *= 15
    @utc = "#{dutc_hour < 0 ? ?- : ?+}#{'%02d' % dutc_hour.abs}:#{'%02d' % dutc_minute}"
  end
  
  def to_s
    '%04d-%02d-%02dT%02d:%02d:%02d%s%s' % [@year, @month, @day, @hour, @minute, @second, @centi_second, @utc]
  end
  
  alias :inspect :to_s
  
end

end
