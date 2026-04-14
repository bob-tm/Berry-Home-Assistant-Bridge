# Version 0.5
import mqtt
import json
import string

var step_up_down = 9 
var print_log    = false

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

def enable_log(en)
	print_log=en
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
	var pin_id			# cmd_idx not always == pin_id				
	var params			# Json with config
	var title			# User Friednly Title
	var update_web_ui	# Last Update Time in ms
	
	def log(s) if print_log print(self.cmd, s); end; end
	def init_params() 						end		# supported features
	def getConfig() return {} 				end		# json for HA Discovery

	def stateJson() return false		    end		# will be added to Tasmota TelePeriod JSON
	def handle_rule(payload)				end		# triggered by Tasmota Rules
	def handle_stat(payload) return false 	end 	# hack to convert mqtt stat to tele
	def handle_cmd(payload, src) 			end 	# handle action
	
	# unique topic
	def getTopic() 	return f"{tasmota_ha_mac_id}_{self.cmd}" end
	
	def init(pin_id, p2, p3)
		var title   = p2
		var cmd_idx = nil
		
		if p3!=nil 
			title   = p3
			cmd_idx = p2
		end
		
		self.title	= title
		self.pin_id  = pin_id
		self.cmd_idx = cmd_idx==nil ? pin_id:cmd_idx
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
	var state, pwm, pwm_switch_on	#ON/OFF, PWM, PWM after ON
	var cmd_setpwm, rule_json_key
	
	def init_params()
		self.pwm      		= 0
		self.state    		= "OFF"
		self.pwm_switch_on  = 0		
		self.params   = {
			'type'   : 'light',						# HA Class
			'cmd'    : f"LIGHT{self.cmd_idx}",		# Topic
			'max_pwm': 255,							# Max PWM Value
			'pwm'    : true							# On / Off (max_pwm or 0) if pwm = false
		}
	end

	
	# force pwm to max_pwm, if pwm in range clamp_percent..99%
	# this is lowers mossfet temperature with bad gate drivers. 
	def clamp(clamp_percent)
		self.params['clamp_pwm'] = int(self.params['max_pwm'] * clamp_percent / 100)
		return self
	end
	
	def pwm_percent() return int(self.pwm*100/self.params['max_pwm']) end
	def on_off_mode() return !self.params['pwm'] end
	
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
		
		if self.params['type'] == 'switch'
			config["value_template"] = config["state_value_template"]
			config.remove("state_value_template")
		end
		
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
	
	def calc_pwm(x)
		#self.log(f"calc_pwm: {x}")	
		# on/off mode
		if self.on_off_mode()
			var p=x>0 ? self.params['max_pwm'] : 0
			if p!=x; self.log(f"fix PWM  from {x} to {p}") end
			return p
		end
		
		# clamp_pwm
		if self.params.contains('clamp_pwm')
			if (x>self.params['clamp_pwm']) && (x<self.params['max_pwm']) 
				self.log(f"Clamp PWM from {x} to {self.params['max_pwm']}")
				return self.params['max_pwm']
			end
		end
		
		return x
	end

	# decode state and pwm from message from HA
	def decode_payload(payload, debug_text)		
		#self.log(f"decode_payload: {payload} {debug_text}")	

		if self.pwm_switch_on==0; self.pwm_switch_on=self.params['max_pwm'] end
		
		# important force to string. string.toupper makes payload=nil if payload is int
		payload = string.toupper(str(payload))
		#toggle (webui or cmd)
		if payload=='+' || payload=='UP'
			if self.state=='OFF' 
				self.pwm   = 0
				self.state ='ON' 
			end

			self.pwm = self.pwm + self.params['max_pwm']/step_up_down
				
			if self.pwm > self.params['max_pwm'] 
				self.pwm = self.params['max_pwm']
			end
		elif payload=='-' || payload=='DOWN'
			if self.state=='ON' 
				self.pwm = self.pwm - self.params['max_pwm']/step_up_down
				if self.pwm <= 0 
					self.pwm   = 0
					self.state ='OFF' 
				end
			end
		elif payload=='T' || payload=='TOGGLE'
			self.state = (self.state == 'ON') ? 'OFF' : 'ON'
			self.pwm   = (self.state == 'ON') ? self.pwm_switch_on : 0
		elif payload == 'ON'
			self.state = 'ON'
			self.pwm   = self.pwm_switch_on
		elif payload == 'OFF'
			self.state = 'OFF'
			self.pwm   = 0
		else
			self.pwm      = self.calc_pwm(int(payload))
			
			# save last on value
			if self.pwm>0; self.pwm_switch_on = self.pwm end
			
			if self.pwm>0
				self.state = 'ON'
			else
				self.state = 'OFF'
			end
		end
		
		self.update_web_ui = tasmota.millis()
	end
		
	def handle_cmd(payload, src)	
		if payload!=''
			#self.log(f"handle_cmd: {payload} from {src}")
			self.decode_payload(payload, src)
			self.do_cmd(self.pwm)		
			self.update_web_ui = tasmota.millis()
		else
			#self.log(f"handle_cmd: Empty payload from {src}")
			self.publish_state()
			return self.stateJson()
		end
	end
	
	
	# triggered by rules  
	def handle_rule(payload)
		if payload.contains(self.rule_json_key) && payload[self.rule_json_key].contains(f"PWM{self.pin_id}")
			var x = int(payload[self.rule_json_key][f"PWM{self.pin_id}"])	# current hardware value
			#self.log(f"Handle_rule: {self.pwm} -> {x}")
	
			if x != self.pwm 
				var prev_pwm = self.pwm
				self.decode_payload(x, 'rule')
				self.log(f"Update self.pwm: {prev_pwm} -> {self.pwm}")
				if (x != self.pwm) # && init_done
					self.log(f"Update real pwm: {x} -> {self.pwm}")
					self.do_cmd(self.pwm)
				end
			end
 		end
	end
	
	#generate modified message
	def handle_stat(payload)
		if payload.contains(self.rule_json_key) && payload[self.rule_json_key].contains(f"PWM{self.pin_id}")
			return self.stateJson()
		end
		return false
	end

	def stateJson()
		return {
			f"{self.cmd}"	   : self.state, 
			f"{self.cmd}_PWM"  : self.pwm
		}
	end

	def do_cmd(pwm)
		var cmd=string.format(self.cmd_setpwm, pwm)
		self.log(f"do_cmd: {cmd}; self.pwm={self.pwm}; self.pwm_switch_on={self.pwm_switch_on}; self.state={self.state}")
		var res = tasmota.cmd(cmd)
		self.publish_state()
		return true
	end
end


#Tasmota PWM Light 
#uses native PWM1 ... PWM16 commands
class LightTasmotaPwm: LightPwm
	def init_params()
		super(self).init_params()
		self.params['max_pwm']	= 1023
		self.cmd_setpwm			= f"PWM{self.pin_id} %s"
		self.rule_json_key		= "PWM"
		self.params['rule']     = {'class_inst': LightTasmotaPwm, 'status_cmd': 'pwm'}
	end
end

class LightTasmotaPwmOnOff: LightTasmotaPwm
	def init_params()
		super(self).init_params()
		self.params['pwm']=false
	end
end

class LightPCA9685Pwm: LightPwm
	def init_params()
		super(self).init_params()
		self.params['max_pwm']	= 4096
		self.cmd_setpwm			= f"driver15 pwm,{self.pin_id},%s"
		self.rule_json_key		= "PCA9685"
		self.params['rule']     = {'class_inst': LightPCA9685Pwm, 'status_cmd': 'driver15 status'}
	end
	
	def handle_rule(payload)
		if payload.contains(self.rule_json_key) && payload[self.rule_json_key].contains(f"PIN")
			if payload[self.rule_json_key]['PIN']==self.pin_id
				payload[self.rule_json_key][f"PWM{self.pin_id}"]=payload[self.rule_json_key]['PWM']
				#print(self.pin_id, payload)
				super(self).handle_rule(payload)
			end
		else
			super(self).handle_rule(payload)
		end
	end
end

class LightPCA9685OnOff: LightPCA9685Pwm
	def init_params()
		super(self).init_params()
		self.params['pwm']=false
	end
end

class SwitchPCA9685OnOff: LightPCA9685Pwm
	def init_params()
		super(self).init_params()
		self.params['type']='switch'
		self.params['cmd' ]=f"SWITCH{self.cmd_idx}"
		self.params['pwm' ]=false
	end
end


# this is tasmota driver
# used to display sliders
class UI
  var id, globalname, started, bridge, slider_for_onoff

  def init(bridge)
    self.id = "ha_bridge_ui"
    self.globalname = 'slider_instance_' + self.id
	self.bridge = bridge
	self.slider_for_onoff = false
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
  
  def web_send_slider_update(id, value, state, pwm_percent, on_off_mode)
	var slider_update_code=f"let obj=eb('{id}');if (obj) obj.{value=}"
	var button_update_code=f"eb('b_{id}').style.background='var({self.btn_style(state)})'"
	var text_update_code=f"eb('t_{id}').innerHTML={pwm_percent}"
	
	slider_update_code = on_off_mode ? '' : slider_update_code
	
	return f"<img src='data:x,' style='display:none' onerror=\"{slider_update_code};{button_update_code};{text_update_code};this.remove();\">"
  end

  def content_send_slider(id, title, min, max, value, state, pwm_percent, on_off_mode)
	var btn_html  = f'<button id="b_{id}" onclick=la("&{id}=t") style="background: var({self.btn_style(state)});" name="b_{id}">{title}</button>'
	var span_html = f'<span id="t_{id}">{pwm_percent}</span>'
	var slider_html = f'<input type="range" class="slider" id="{id}" min={min} max={max} value={value} onchange=la("&{id}="+value)>'
	
	slider_html = on_off_mode ? '' : slider_html
	
	return f'<tr><td style="width:25%">{btn_html}</td><td>{slider_html}</td><td style="min-width:2em; text-align:right">{span_html}</td></tr>'
  end
  
  def web_sensor()
    import webserver

	# check for ui input commands
	for e : self.bridge.entities
		var k=string.tolower(e.cmd)
		if webserver.has_arg(k)
			e.handle_cmd(webserver.arg(k), 'web_ui')
		end
	end
	
	# update ui
	for e : self.bridge.entities
		# send update code for 5 seconds. 
		# sometimes it doesn't work from first time.
		if tasmota.millis() - e.update_web_ui < 5000
			# e.log(f"update_web_ui, {k} {e.pwm}")
			tasmota.web_send(self.web_send_slider_update(string.tolower(e.cmd), e.pwm, e.state, e.pwm_percent(), e.on_off_mode()))
		end
	end
  end

  def web_add_main_button()
    import webserver
	var html='<table style="width:100%">'
	
	for e : self.bridge.entities
		html = html + self.content_send_slider(string.tolower(e.cmd), e.title, 0, e.params['max_pwm'], e.pwm, e.state, e.pwm_percent(), e.on_off_mode())
	end
	
	html = html + '</table>'

	webserver.content_send(html)
  end
end


# this class handle unique id, discovery and events
class HaBridge
	var discovery_published		# true, if mqtt connected and discovery published
	var ready_to_publish		#
	var entities				# List of controls
	var ui						# UI sliders
	var rules					# rules for items
	
	def log(s) print(f"{s}") end
	
	def finish_and_publish_on_mqtt_connected()
		# init is finished
		if self.ready_to_publish && mqtt.connected()
			self.finish_and_publish()
		end
	end
	
	def init()
		self.discovery_published  = false
		self.ready_to_publish	  = false
		self.entities             = []
		
		self.rules                = {}
		
		# executed at boot
		tasmota.add_rule("mqtt#connected", 		/-> self.finish_and_publish_on_mqtt_connected())

		self.log('Ha Bridge initialized')
	end

	def limit(group, by_percent)
		for e : self.entities
			if (group.find(e.cmd_idx) != nil) && e.params['pwm']
				e.handle_cmd(f"{e.pwm - int(e.pwm*by_percent/100)}", 'limiter')
			end
		end
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
		# print(f"finish_and_publish. Ready={self.ready_to_publish}")
		if !self.ready_to_publish
			for k:self.rules.keys()
				self.add_rule_PWM(k, self.rules[k]['status_cmd'])
			end
					
			self.add_rule_TeleData()
			self.start_ui()

			self.ready_to_publish = true
		end
		
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

	def do_tasmota_cmd(e, payload)
		#print('do_tasmota_cmd', payload)
		return e.handle_cmd(payload, 'tasmota')
	end
	
	def handle_tasmota_cmd(cmd, idx, payload)
		var cmd_indx = string.tolower(f"{cmd}{idx}")
		var x = false
		for e:self.entities
			if string.tolower(e.cmd) == cmd_indx
				x=e
				break
			end
		end
		
		if x
			if payload=='' 
				tasmota.resp_cmnd(self.do_tasmota_cmd(x, payload))
			else
				# using timer, because tasmota.cmd call broke responce
				tasmota.resp_cmnd_done()
				tasmota.set_timer(0, / -> self.do_tasmota_cmd(x, payload))
			end
		else
			tasmota.resp_cmnd_error()
		end 
	end
	
	def add(e)
		# check for alredy registered tasmota command
		var cmd_found = false
		for x:self.entities
			if string.startswith(string.tolower(x.cmd), e.params['type'])
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

		if !self.rules.contains(e.rule_json_key) self.rules[e.rule_json_key] = e.params['rule'] end
		
		self.entities.push(e)
		
		print(f"Register {e.cmd} for {e.title}")
	end

	def rule_PWM(value, trigger, json)
		if json.contains(trigger)
			for e : self.entities
				if isinstance(e, self.rules[trigger]['class_inst'])
					e.handle_rule(json)
				end
			end
		end
	end

	def do_teledata_cmd()
		#print("do_teledata_cmd")
		var tele_results={}
		for e : self.entities
			json_add(tele_results, e.stateJson()) 
		end
		
		#print(f"TeleData {tele_results}")
		self.publish_result(tele_results)
	end
	
	def rule_TeleData(value, trigger, json)
		# sometimes 2 tele messages. Check for main
		# print(f"rule_TeleData {json}")
		if json.contains('Tele') && json['Tele'].contains('Uptime')
			#using timer, because mqtt.publish from rule_TeleData reboots device (v15.2.0.4)
			tasmota.set_timer(0, / -> self.do_teledata_cmd())
		end
	end

	def add_rule_PWM(trigger, status_cmd)
		tasmota.add_rule(trigger, / value, trigger, json -> self.rule_PWM(value, trigger, json))
		tasmota.cmd(status_cmd)
	end
	
	def add_rule_TeleData()
		tasmota.add_rule('tele#', / value, trigger, json -> self.rule_TeleData(value, trigger, json))
	end	
end

def demo()
	var bridge = HaBridge()
	#bridge.add(     LightTasmotaPwm(1, 'LightPwm 1' ).clamp(80))
	#bridge.add(LightTasmotaPwmOnOff(2, 'LightOnOff 2'))
	#bridge.add(     LightTasmotaPwm(6, 'LightPwm 6'))
	#bridge.add(     LightTasmotaPwm(6, 'LightPwm 6'))
	#bridge.add(     LightPCA9685Pwm(8, 'pca9685-8'))
	#bridge.add(  SwitchPCA9685OnOff(9, 'pca9685-9'))
	bridge.add(     LightPCA9685Pwm(00, 'pca9685-00'))
	bridge.add(     LightPCA9685Pwm(01, 'pca9685-01'))
	bridge.add(     LightPCA9685Pwm(14, 'pca9685-14'))
	bridge.add(     LightPCA9685Pwm(15, 'pca9685-15'))	
	bridge.finish_and_publish()
end

var m=module('ha_bridge')
m.enable_log=enable_log
m.HaBridge=HaBridge
m.get_full_topic=get_full_topic
m.LightTasmotaPwm=LightTasmotaPwm
m.LightTsmtaOnOff=LightTasmotaPwmOnOff
m.LightPCA9685Pwm=LightPCA9685Pwm
m.Light_9685OnOff=LightPCA9685OnOff
m.Switch9685OnOff=SwitchPCA9685OnOff

return m
#demo()