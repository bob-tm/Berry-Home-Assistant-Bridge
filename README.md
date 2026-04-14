# Berry Home Assistant Bridge
Connect Tasmota devices to Home Assistant using Berry scripting
The current version implements a Virtual Light Driver. It supports more than five PWM channels with full Home Assistant integration. It works by controlling Tasmota's PWM1, PWM2, … commands.

## Features
0. Create Virtual Light on top of Tasmota Console commands PWM1, PWM2, etc
1. Automatic integration into Home Assistant under the correct Tasmota device
2. Full support for PWM dimming and ON/OFF. Remembers the last PWM (brightness) value when turned OFF and then back ON
3. Full integration with the Tasmota web UI — sliders with real-time updates and toggle button
4. Individual PWM channels can be limited to ON/OFF mode (acting as simple switches) if you decide not to use brightness for some channels in the future. Or use some PWM channels with relays (PCA9865)
5. New console commands in Tasmota: light1, light2, …
6. Provides native light entities in Home Assistant
7. Lights Naming is fully independed from tasmota 


## Tasmota Config for built in PWMs

Disable Tasmota Light control with
```
SetOption15 0
```


## Example
1. LightTasmotaPwm - class for pwm lights
2. LightTasmotaPwmOnOff - limits pwm to 0 (OFF) or pwm_max_value (ON)

Create Virtual Light for PWM6 with 'LightPwm 6' title
```
ha_bridge.LightTasmotaPwm(6, 'LightPwm 6')
```

Full Example for 6 PWM lights. 2 and 3 is limited to ON/OFF
```
import ha_bridge as ha

var bridge = ha.HaBridge()
bridge.add(ha.LightTasmotaPwm(1, 'LightPwm 1'))
bridge.add(ha.LightTsmtaOnOff(2, 'PwmOnOff 2'))
bridge.add(ha.LightTsmtaOnOff(3, 'PwmOnOff 3'))
bridge.add(ha.LightTasmotaPwm(4, 'LightPwm 4'))
bridge.add(ha.LightTasmotaPwm(5, 'LightPwm 5'))
bridge.add(ha.LightTasmotaPwm(6, 'LightPwm 6'))
bridge.finish_and_publish()
```


PCA9685 Example

This code will create UI in Tasmota and integrate it to HA with Light and Switch enitines.  

```
var bridge
import ha_bridge as ha

ha.enable_log(true)

def start()
	tasmota.cmd("driver15 reset")

	bridge = ha.HaBridge()
	bridge.add(ha.LightPCA9685Pwm(0,  1,  'Light 01'))
	bridge.add(ha.LightPCA9685Pwm(1,  2,  'Light 02').clamp(95))
	bridge.add(ha.LightPCA9685Pwm(2,  3,  'Light 03'))
	bridge.add(ha.LightPCA9685Pwm(3,  4,  'Light 04'))
	bridge.add(ha.LightPCA9685Pwm(4,  5,  'Light 05'))
	bridge.add(ha.LightPCA9685Pwm(5,  6,  'Light 06'))
	bridge.add(ha.LightPCA9685Pwm(6,  7,  'Light 07'))
	bridge.add(ha.LightPCA9685Pwm(7,  8,  'Light 08'))
	bridge.add(ha.LightPCA9685Pwm(8,  9,  'Ext Led'))
	bridge.add(ha.Switch9685OnOff(9,  13, 'Ext 3'))
	bridge.add(ha.Switch9685OnOff(10, 12, 'Ext 2'))
	bridge.add(ha.Switch9685OnOff(11, 11, 'Ext 1'))
	bridge.add(ha.Switch9685OnOff(12, 4,  'Relay 4'))
	bridge.add(ha.Switch9685OnOff(13, 1,  'Relay 1'))
	bridge.add(ha.Switch9685OnOff(14, 2,  'Relay 2'))
	bridge.add(ha.Switch9685OnOff(15, 3,  'Relay 3'))

	bridge.finish_and_publish()

	# Buttons and RF Handle
	sm=switch_matrix.switch_matrix()
	ir=input_rules.InputRules()

	# Sensors
	local=sensors.Sensors(ha.get_full_topic('tele', 'SENSOR'))
	local.add_sensor('Temperature', 'DS18B20')
	local.add_sensor('INA226-1'   , ['Voltage', 'Current', 'Power'], true)
	local.register_rules()
	local.SetLimits(15.0, 60.0)
end

start()
```

.clamp(95) -  Clamp PWM. With poor gate drivers, MOSFETs heat significantly at PWM duty cycles between 95% and 99%.
If the PWM is in the 95–99% range, force it to 100%.
