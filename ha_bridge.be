# Version 0.2
import mqtt
import json
import string


def json_add(dest, src)
	for key : src.keys()
		dest[key] = src[key]
	end
end

def get_tasmota_prefix()
	var p = tasmota.cmd('_Prefix')
	return {
		'cmnd': p['Prefix1'],
		'stat': p['Prefix2'],
		'tele': p['Prefix3']
	}
end

def get_ha_mac_id()
	var mac = false
	var wifi_info = tasmota.wifi()
		
	if wifi_info  mac = wifi_info.find('mac', false) end 
	if mac==false
		var eth_info  = tasmota.eth()
		if eth_info mac = eth_info.find('mac', false) end 
	end
	
	if mac 
		#print(f"MAC is {mac}")
		var mac_clean = string.replace(mac, ":", "")
		return mac_clean[-12..-1]
	else
		return false
	end
end

var tasmota_ha_mac_id = get_ha_mac_id()
var tasmota_topic     = tasmota.cmd('_Status')['Status']['Topic']
var tasmota_prefix 	  = get_tasmota_prefix()
var tasmota_fulltopic = string.replace(tasmota.cmd('_FullTopic')['FullTopic'], '%topic%', tasmota_topic)

def get_full_topic(prefix, cmd) return string.replace(tasmota_fulltopic, '%prefix%', tasmota_prefix[prefix])+cmd end
def get_data_topic() return get_full_topic('stat', 'DATA') end
def get_result_topic() return get_full_topic('stat', 'RESULT') end

	
	
# Basic Entity Integration
class HaEntity
	var cmd 			# LIGHT1, LIGHT2, ...
	var cmd_idx			# 1, 2, 3 ...
	var params			# Json with config
	var title			# User Friednly Title
	var update_web_ui	# Last Update Time in ms
	
	def log(s) print(self.cmd, s) 			end
	def init_params() 						end		# supported features
	def getConfig() return {} 				end		# json for HA Discovery

	def stateJson() return false		    end		# will be added to Tasmota TelePeriod JSON
	def handle_rule(payload)				end		# triggered by Tasmota Rules
	def handle_stat(payload) return false 	end 	# hack to convert mqtt stat to tele
	def handle_cmd(payload, src) 			end 	# handle action
	
	# unique topic
	def getTopic() 	return f"{tasmota_ha_mac_id}_{self.cmd}" end
	
	def init(cmd_idx, title)
		self.title	 = title
		self.cmd_idx = cmd_idx
		self.update_web_ui = 0
		
		self.init_params()
		self.cmd     = self.params['cmd']
	end
	
	def publish_state()	
		mqtt.publish(get_data_topic(), json.dump(self.stateJson()) ) 
	end
end

# Basic Pwm Light
class LightPwm: HaEntity
	var state, pwm, pwm_user
	
	def init_params()
		self.pwm      = 0
		self.state    = "OFF"
		self.pwm_user = 0		
		self.params   = {
			'type'   : 'light',						# HA Class
			'cmd'    : f"LIGHT{self.cmd_idx}",		# Topic
			'max_pwm': 255,							# Max PWM Value
			'pwm'    : true							# On / Off (max_pwm or 0) if pwm = false 
		}
	end
	
	def getConfig()
		var cmnd_topic = get_full_topic('cmnd', self.cmd)
		var data_topic = get_data_topic()
		
		var config = {
		  "command_topic"				: cmnd_topic,
		  "state_topic"					: data_topic,
		  "state_value_template"		: "{{value_json."+self.cmd+"}}",
		  "payload_on"					: "ON",
		  "payload_off"					: "OFF"
		}
		
		if self.params['pwm']
			json_add(config,
			{
			  "brightness_command_topic"	: cmnd_topic,
			  "brightness_state_topic"		: data_topic,
			  "brightness_value_template"	: "{{value_json."+self.cmd+"_PWM}}",
			  "on_command_type"				: "brightness",
			  "brightness_scale"			: self.params['max_pwm']
			})
		end
		  
		return config
	end
	

	# decode state and pwm from message from HA
	def decode_payload(payload, debug_text)
		#self.log(f"decode_payload: {payload} {debug_text}")
		
		#web_ui on/off
		if payload=='t'
			#self.log('web_ui toggle')
			self.state = (self.state == 'ON') ? 'OFF' : 'ON'
			if self.state=='ON' self.pwm = self.pwm_user end
		elif payload == 'ON'
			self.state = 'ON'
		elif payload == 'OFF'
			self.state = 'OFF'
		else
			self.pwm = int(payload)
			if self.pwm>0
				self.state = 'ON'
			else
				self.state = 'OFF'
			end
		end
	end
		
	def calc_effective_pwm()
		if !self.params['pwm']
			if self.state == 'ON'
				self.pwm = self.params['max_pwm']
			else
				self.state = 'OFF'
				self.pwm = 0
			end
		end
		
		if self.state == 'OFF'
			return 0
		elif self.pwm <= self.params['max_pwm']
			return self.pwm
		else
			return 0
		end
	end
	
	def handle_cmd(payload, src)	
		#self.log(f"handle_cmd: {payload} from {src}")
		self.decode_payload(payload, 'cmd')
		self.do_cmd()		
		self.update_web_ui = tasmota.millis()
	end
	
	# for override 
	def do_cmd()	return true end
end


#Tasmota PWM Light 
#uses native PWM1 ... PWM16 commands
class LightTasmotaPwm: LightPwm
	def init_params()
		super(self).init_params()
		self.params['max_pwm']=1023
	end
	
	def do_cmd()
		var pwm = self.calc_effective_pwm()
		var res = tasmota.cmd(f"PWM{self.cmd_idx} {pwm}")
		self.publish_state()
		return true
	end
	
	# triggered by rules
	def handle_rule(payload)
		if payload.contains("PWM") && payload["PWM"].contains(f"PWM{self.cmd_idx}")
			var x = int(payload["PWM"][f"PWM{self.cmd_idx}"])
			#print(f"handle_rule {self.pwm} -> {x}")
			if x != self.pwm 	
				#self.log(f"Handle_rule: {self.pwm} -> {x}")
				self.pwm = x				
				self.state = self.pwm > 0 ? 'ON' : 'OFF'
				self.update_web_ui = tasmota.millis()
				#self.log("update_web_ui = true 2")
				
				# fix PWM for ON/OFF mode
				if !self.params['pwm'] && (x > 0) && (x != self.params['max_pwm']) 
					self.log(f"fix PWM  from {x} to {self.params['max_pwm']}")
					self.pwm = self.params['max_pwm'] 
					self.do_cmd()
				end
			end
			
			# save non zero pwm for on/off
			if self.pwm !=0  
				self.pwm_user=self.pwm 
			end
 		end
	end
	
	def stateJson()
		return {
			f"{self.cmd}"	   : self.state, 
			f"{self.cmd}_PWM"  : self.pwm
		}
	end
	
	#generate modified message
	def handle_stat(payload)
		if payload.contains("PWM") && payload["PWM"].contains(f"PWM{self.cmd_idx}")
			return self.stateJson()
		end
		return false
	end
end

class LightTasmotaPwmOnOff: LightTasmotaPwm
	def init_params()
		super(self).init_params()
		self.params['pwm']=false
	end
end


# this is tasmota driver
# used to display sliders
class UI
  var id, globalname, started, bridge

  def init(bridge)
    self.id = "ha_bridge_ui"
    self.globalname = 'slider_instance_' + self.id
	self.bridge = bridge
  end

  def start()
    if self.started return end
    if global.member(self.globalname) global.member(self.globalname).stop() end
    tasmota.add_driver(self)
    global.setmember(self.globalname, self)
    self.started = true
    return self
  end

  def stop()
    self.started = false
    tasmota.remove_driver(self)
    global.setmember(self.globalname, nil)
    return self
  end
  
  def btn_style(state) return (state == 'ON') ?  '--c_btn' : '--c_btnoff' end
  
  def web_send_slider_update(id, value, state)
	var slider_update_code=f"let obj=eb('{id}');if (obj) obj.{value=}"
	var button_update_code=f"eb('b_{id}').style.background='var({self.btn_style(state)})'"
	return f"<img src='data:x,' style='display:none' onerror=\"{slider_update_code};{button_update_code};this.remove();\">"
  end

  def content_send_slider(id, title, min, max, value, state)
	var btn_html  = f'<button id="b_{id}" onclick=la("&{id}=t") style="background: var({self.btn_style(state)});" name="b_{id}">{title}</button>'
	
	return f'<tr><td style="width:25%">{btn_html}</td><td><input type="range" class="slider" id="{id}" min={min} max={max} value={value} onchange=la("&{id}="+value)></td></tr>'
  end
  
  def web_sensor()
    import webserver

	# check for ui input commands
	for k : self.bridge.entities.keys()
		if webserver.has_arg(k)
			self.bridge.entities[k].handle_cmd(webserver.arg(k), 'web_ui')
		end
	end
	
	# update ui
	for k : self.bridge.entities.keys()
		var e=self.bridge.entities[k]
		
		# send update code for 5 seconds. 
		# sometimes it doesn't work from first time.
		if tasmota.millis() - e.update_web_ui < 5000
			# e.log(f"update_web_ui, {k} {e.pwm}")
			tasmota.web_send(self.web_send_slider_update(k, e.pwm, e.state))
		end
	end
  end

  def web_add_main_button()
    import webserver
	webserver.content_send('<table style="width:100%">')
	
	for e : self.bridge.entities
		webserver.content_send(self.content_send_slider(string.tolower(e.cmd), e.title, 0, e.params['max_pwm'], e.pwm, e.state))
	end

	webserver.content_send('</table>')
  end
end


# this class handle unique id, discovery and events
class HaBridge
	var discovery_published		# true, if mqtt connected and discovery published
	var ready_to_publish		#
	var entities				# List of controls
	var ui						# UI sliders
	
	def log(s) print(f"{s}") end
	
	def finish_and_publish_on_mqtt_connected()
		# init is finished
		if self.ready_to_publish 
			self.finish_and_publish()
		end
	end
	
	def init()
		self.discovery_published = false
		self.ready_to_publish	 = false
		self.entities            = {}
		
		# executed at boot
		tasmota.add_rule("mqtt#connected", 		/-> self.finish_and_publish_on_mqtt_connected())

		self.log('Ha Bridge initialized')
	end


	def publish_result(res)
		var s=json.dump(res)
		
		if s != "{}"
			mqtt.publish(get_data_topic(), s)
		end
	end

	# convert mqtt stat to tele
	# currently disabled
	def handle_stat(payload)
		var tele_results={}
		var j = json.load(payload)
		
		#self.log(j)
		for e : self.entities
			var r = e.handle_stat(j)
			if r 
				json_add(tele_results, r) 
			end
		end
		
		#self.log(f"handle_stat: {tele_results}")
		self.publish_result(tele_results)
	end

	def finish_and_publish()
		self.add_rule_TasmotaPWM()
		self.add_rule_TeleData()
		self.start_ui()

		self.ready_to_publish = true
		
		# check if mqtt is connected. Publish only once
		if !self.discovery_published && mqtt.connected()
			if tasmota_ha_mac_id
				self.publish_discovery()
				self.discovery_published = true
			
				#handle_stat is disabled
				#mqtt.subscribe(get_result_topic(), / topic, idx, payload -> self.handle_stat(payload))					
				#for e : self.entities e.subscribe() end	
			else
				print('Error parsing MAC address')
			end
		end 
	end

	def start_ui()
		self.ui = UI(self)
		self.ui.start()
	end
  
  
	# generate HA discovery MQTT Messages for each control
	def publish_discovery() 
		for e : self.entities
			var config = e.getConfig()
			var entity_topic = e.getTopic()
			
			var device_config = {
				"name"					: e.title,
				"unique_id"				: f"{entity_topic}",
				"availability_topic"	: get_full_topic('tele', 'LWT'),
				"payload_available"		: "Online",
				"payload_not_available"	: "Offline",			
				"device"				: {
											"identifiers":  [entity_topic],  
											"connections":  [["mac", tasmota_ha_mac_id]]    
											#"name":         "Virtual Name",
											#"model":        "ESP32C3",
											#"manufacturer": "Tasmota",
											#"sw_version":   "15.2.0.4(tasmota32)"
										}
			}
			
			# append device_config to config
			json_add(config, device_config)
			
			var topic = f"homeassistant/{e.params['type']}/{entity_topic}/config"
			
			# clear old config
			# mqtt.publish(topic, "", true)
			
			# set new
			mqtt.publish(topic, json.dump(config), true)
		end
		 
		self.log('HA discovery published')
	end

	def do_tasmota_cmd(cmd_indx, payload)
		self.entities[cmd_indx].handle_cmd(payload, 'tasmota')
	end
	
	def handle_tasmota_cmd(cmd, idx, payload)
		var cmd_indx = f"{cmd}{idx}"
		if self.entities.contains(cmd_indx)
			tasmota.resp_cmnd_done()
			
			# using timer, because tasmota.cmd call broke responce
			tasmota.set_timer(0, / -> self.do_tasmota_cmd(cmd_indx, payload))
		else
			tasmota.resp_cmnd_error()
		end 
	end
	
	def add(e)
		# check for alredy registered tasmota command
		var cmd_found = false
		for k:self.entities.keys()
			if string.startswith(k, e.params['type'])
				cmd_found = true
				break
			end
		end

		# new type. register it as tasmota command
		if !cmd_found
			var tsmt_cmd = string.tolower(e.params['type'])
			self.log(f"register cmd: {tsmt_cmd}")
			tasmota.add_cmd(tsmt_cmd, / cmd, idx, payload -> self.handle_tasmota_cmd(cmd, idx, payload))
		end

		self.entities[string.tolower(e.cmd)]=e		
	end
	
	def rule_TasmotaPWM(value, trigger, json)
		for e : self.entities
			if isinstance(e, LightTasmotaPwm)
				e.handle_rule(json)
			end
		end	
	end

	def do_teledata_cmd()
		var tele_results={}
		for e : self.entities
			json_add(tele_results, e.stateJson()) 
		end
		
		#print(f"TeleData {tele_results}")
		self.publish_result(tele_results)
	end
	
	def rule_TeleData()
		#using timer, because mqtt.publish from rule_TeleData reboots device (v15.2.0.4)
		tasmota.set_timer(0, / -> self.do_teledata_cmd())
	end
	
	def add_rule_TasmotaPWM()
		tasmota.add_rule('PWM', / value, trigger, json -> self.rule_TasmotaPWM(value, trigger, json))
		# execute to get current values
		tasmota.cmd('PWM1')
	end

	def add_rule_TeleData()
		tasmota.add_rule('tele#', /-> self.rule_TeleData())
	end	
end

def demo()
	var bridge = HaBridge()
	bridge.add(     LightTasmotaPwm(1, 'LightPwm 1' ))
	bridge.add(LightTasmotaPwmOnOff(2, 'LightOnOff 2'))
	bridge.add(     LightTasmotaPwm(6, 'LightPwm 6'))
	bridge.finish_and_publish()
end

var m=module('ha_bridge')
m.HaBridge=HaBridge
m.LightTasmotaPwm=LightTasmotaPwm
m.LightTasmotaPwmOnOff=LightTasmotaPwmOnOff

return m
#demo()
