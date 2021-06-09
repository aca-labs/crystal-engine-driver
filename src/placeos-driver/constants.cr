class PlaceOS::Driver
  VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
end
