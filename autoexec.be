import ha_bridge as ha

var bridge = ha.HaBridge()
bridge.add(ha.LightTasmotaPwm(1, 'LightPwm 1'))
bridge.add(ha.LightTsmtaOnOff(2, 'PwmOnOff 2'))
bridge.add(ha.LightTsmtaOnOff(3, 'PwmOnOff 3'))
bridge.add(ha.LightTasmotaPwm(4, 'LightPwm 4'))
bridge.add(ha.LightTasmotaPwm(5, 'LightPwm 5'))
bridge.add(ha.LightTasmotaPwm(6, 'LightPwm 6'))
bridge.finish_and_publish()
