# Berry Home Assistant Bridge
Connect Tasmota devices to Home Assistant using Berry scripting
The current version implements a Virtual Light Driver. It supports more than five PWM channels with full Home Assistant integration. It works by controlling Tasmota's PWM1, PWM2, … commands.


## Features
0. Create Virtual Light on top of Tasmota Console commands PWM1, PWM2, 
1. Automatic integration into Home Assistant under the correct Tasmota device
2. Full support for PWM dimming and ON/OFF. Remembers the last PWM (brightness) value when turned off and then back on from Home Assistant
3. Full integration with the Tasmota web UI — sliders with real-time updates
4. Individual PWM channels can be limited to ON/OFF mode (acting as simple switches) if you decide not to use brightness for some channels in the future. Or use some PWM channels with relays (PCA9865)
5. New console commands in Tasmota: light1, light2, …
6. Provides native light entities in Home Assistant
7. Lights Naming is fully independed from tasmota 


## Coming soon features
1. Native PCA9865 web ui and HA Integration
2. Clamp PWM. With poor gate drivers, MOSFETs heat significantly at PWM duty cycles between 95% and 99%.
If the PWM is in the 95–99% range, force it to 100%.

## Example
1. LightTasmotaPwm - class for pwm lights
2. LightTasmotaPwmOnOff - limits pwm to 0 (OFF) or pwm_max_value (ON)

Create Virtual Light for PWM6 with 'LightPwm 6' title
```
ha_bridge.LightTasmotaPwm(6, 'LightPwm 6')
```

Full Example for lights on PWM1, PWM2 (ON/OFF) and PWM6
```
import ha_bridge

var bridge = ha_bridge.HaBridge()
bridge.add(     ha_bridge.LightTasmotaPwm(1, 'LightPwm 1' ))
bridge.add(ha_bridge.LightTasmotaPwmOnOff(2, 'LightOnOff 2'))
bridge.add(     ha_bridge.LightTasmotaPwm(6, 'LightPwm 6'))
bridge.finish_and_publish()
```
