require "json"
require "s2_cells"

module PlaceOS::Driver::Interface::Sensor
  enum SensorType
    Temperature # https://en.wikipedia.org/wiki/Celsius
    Humidity    # https://en.wikipedia.org/wiki/Humidity#Relative_humidity (percentage)
    Illuminance # https://en.wikipedia.org/wiki/Illuminance (lux)
    Pressure    # https://en.wikipedia.org/wiki/Pascal_(unit)
    Trigger     # Proximity or motion etc
    Switch      # On or Off - water leak, door open etc
    Level       # Percentage + raw value + technical human readable (battery, fuel, water tank, oxygen, Co2)
    Flow        # https://en.wikipedia.org/wiki/Cubic_metre_per_second (gas or liquid)
    Counter
    Acceleration # MetrePerSecondSquared
    Speed        # MetrePerSecond
    # Gyroscope: roll, pitch, yaw - Angle
    Roll
    Pitch
    Yaw
    Compass              # direction (magnetic field)
    Current              # https://en.wikipedia.org/wiki/Ampere
    Voltage              # https://en.wikipedia.org/wiki/Volt
    ElectricalResistance # https://en.wikipedia.org/wiki/Ohm
    Power                # https://en.wikipedia.org/wiki/Watt
    Energy               # https://en.wikipedia.org/wiki/Joule as WattSecond
    Capacitance
    Inductance
    Conductance
    MagneticFlux # https://en.wikipedia.org/wiki/Weber_(unit)
    MagneticFluxDensity
    Radiation # https://en.wikipedia.org/wiki/Sievert
    Distance
    Area
    SoundPressure
    Force
    Frequency
    Mass
    Momentum
    TimePeriod
    Volume
    Acidity

    def unit
      case self
      in Temperature          then Unit::Celsius
      in Humidity             then Unit::Percentage
      in Illuminance          then Unit::Lux
      in Pressure             then Unit::Pascal
      in Trigger              then Unit::Boolean
      in Switch               then Unit::Boolean
      in Level                then Unit::Percentage
      in Flow                 then Unit::LitrePerSecond
      in Counter              then Unit::Integer
      in Acceleration         then Unit::MetrePerSecondSquared
      in Speed                then Unit::MetrePerSecond
      in Roll                 then Unit::Angle
      in Pitch                then Unit::Angle
      in Yaw                  then Unit::Angle
      in Compass              then Unit::Angle
      in Current              then Unit::Ampere
      in Voltage              then Unit::Volt
      in ElectricalResistance then Unit::Ohm
      in Power                then Unit::Watt
      in Radiation            then Unit::Sievert
      in Distance             then Unit::Metre
      in Area                 then Unit::SquareMeter
      in SoundPressure        then Unit::Decibel
      in Capacitance          then Unit::Farad
      in Inductance           then Unit::Henry
      in Conductance          then Unit::Siemens
      in MagneticFlux         then Unit::Weber
      in MagneticFluxDensity  then Unit::Tesla
      in Energy               then Unit::WattSecond
      in Force                then Unit::Newton
      in Frequency            then Unit::Hertz
      in Mass                 then Unit::Kilogram
      in Momentum             then Unit::NewtonSecond
      in TimePeriod           then Unit::Second
      in Volume               then Unit::Litre
      in Acidity              then Unit::PH
      end
    end
  end

  # Using SI units and SI derived units
  enum Unit
    Celsius               # Temperature - celsius over Kelvin to avoid some conversions
    Percentage            # Humidity, Level
    Lux                   # Illuminance
    Pascal                # Pressure
    Boolean               # Trigger, Switch
    Integer               # Counter
    LitrePerSecond        # Liquid or gas flow rate
    MetrePerSecondSquared # Acceleration
    MetrePerSecond        # Speed
    Angle                 # Compass, Accel, Gyro
    Ampere                # Current
    Volt                  # Voltage
    Ohm                   # ElectricalResistance
    Watt                  # Power
    WattSecond
    Sievert # Radiation
    Metre   # Distance
    SquareMeter
    Decibel
    Farad
    Henry
    Weber
    Newton
    Hertz
    Kilogram
    NewtonSecond
    Second
    Litre
    PH
  end

  enum Status
    Normal
    Alarm
    Fault
    OutOfService
  end

  # return the specified sensor details
  abstract def sensor(unique_id : String) : Detail?

  # return an array of sensor details
  # zone_id can be ignored if location is unknown by the sensor provider
  # mac_address can be used to grab data from a single device (basic grouping)
  abstract def sensors(type : String? = nil, mac_address : String? = nil, zone_id : String? = nil) : Array(Detail)

  abstract class Location
    include JSON::Serializable

    use_json_discriminator "type", {
      "geo" => GeoLocation,
      "map" => MapLocation,
    }
  end

  class GeoLocation < Location
    getter type : String = "geo"

    def initialize(@lat, @lon)
    end

    property lat : Float64
    property lon : Float64

    def s2_cell_id(s2_level : Int32 = 21)
      S2Cells::LatLon.new(lat, lon).to_token(s2_level)
    end
  end

  class MapLocation < Location
    getter type : String = "map"

    def initialize(@x, @y)
    end

    # this is expected to be the raw unadjusted values
    property x : Float64
    property y : Float64
  end

  abstract class Detail
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    def initialize(
      @type, @value, @unix_ms, @mac, @id,
      @name, @raw, @loc, @status = Status::Normal
    )
    end

    property status : Status
    property type : SensorType

    delegate unit, to: type

    property value : Float64
    property unix_ms : Int64

    property limit_high : Float64?
    property limit_low : Float64?
    property resolution : Float64?

    # the id can be optional if the mac address represents a single value
    property mac : String
    property id : String?

    # `name` is some useful human itentifying information about the sensor
    # i.e. "lobby motion detector" or "Globalsat LS-113P"
    property name : String?

    # `raw` is a human readable original value
    # i.e. Temperature is always celsius but the sensor may be reporting Fahrenheit
    #      so an example raw string would be `"88.2°F"`
    property raw : String?

    # unadjusted location if the sensor platform has this information
    property loc : Location?

    def value
      case unit
      when .integer?
        @value.to_i64
      when .boolean?
        !@value.zero?
      else
        @value
      end
    end

    def seen_at : Time
      Time.unix_ms(unix_ms)
    end
  end
end
