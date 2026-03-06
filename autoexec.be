import ha_bridge

var bridge = ha_bridge.HaBridge()
bridge.add(     ha_bridge.LightTasmotaPwm(1, 'LightPwm 1' ))
bridge.add(ha_bridge.LightTasmotaPwmOnOff(2, 'LightOnOff 2'))
bridge.add(     ha_bridge.LightTasmotaPwm(6, 'LightPwm 6'))
bridge.finish_and_publish()