-- This config acts as a sink that will discard all received mail
local kumo = require 'kumo'
package.path = package.path .. ';/opt/kumomta/share/?.lua'
local utils = require 'policy-extras.policy_utils'

local SINK_DATA_FILE = os.getenv 'SINK_DATA'
  or '/opt/kumomta/etc/policy/responses.toml'

-- Resolve our hostname, then derive the docker network from that.
local function resolve_docker_network()
  local hostname = os.getenv 'HOSTNAME' or 'localhost'
  local MY_IPS = kumo.dns.lookup_addr(hostname)
  if MY_IPS and MY_IPS[1] then
    return string.match(MY_IPS[1], '^(.*)%.%d+$') .. '.0/24'
  end
  return '172.17.0.0/16'  -- safe fallback
end

kumo.on('init', function()
  kumo.configure_accounting_db_path(os.tmpname())
  kumo.set_config_monitor_globs { SINK_DATA_FILE }
  local DOCKER_NETWORK = resolve_docker_network()
  local SINK_PORT = os.getenv 'SINK_PORT' or '25'
  kumo.start_esmtp_listener {
    listen = '0:' .. SINK_PORT,
    relay_hosts = { '0.0.0.0/0' },
    banner = 'This system will sink and discard all mail',
  }

  local SINK_HTTP = os.getenv 'SINK_HTTP' or '8000'
  kumo.start_http_listener {
    listen = '0.0.0.0:' .. SINK_HTTP,
    trusted_hosts = { '127.0.0.1', '::1', DOCKER_NETWORK },
  }

  local spool_dir = os.getenv 'SINK_SPOOL' or '/var/spool/kumomta'

  for _, name in ipairs { 'data', 'meta' } do
    kumo.define_spool {
      name = name,
      path = spool_dir .. '/' .. name,
    }
  end
end)

local function load_data_for_domain(domain)
  local data = kumo.toml_load(SINK_DATA_FILE)
  local config = data.domain[domain] or data.default
  config.bounces = data.bounce[domain] or { { code = 550, msg = 'boing!' } }
  config.defers = data.defer[domain] or { { code = 451, msg = 'later!' } }
  return config
end

local resolve_domain = kumo.memoize(load_data_for_domain, {
  name = 'response-data-cache',
  ttl = '1 hour',
  capacity = 100,
})

kumo.on('smtp_server_message_received', function(msg)
  local recipient = msg:recipient()

  if string.find(recipient.user, 'tempfail') then
    kumo.reject(400, 'tempfail requested')
  end
  if string.find(recipient.user, 'permfail') then
    kumo.reject(500, 'permfail requested')
  end
  if utils.starts_with(recipient.user, '450-') then
    kumo.reject(450, 'you said ' .. recipient.user)
  end
  if utils.starts_with(recipient.user, '250-') then
    msg:set_meta('queue', 'null')
    return
  end

  local domain = recipient.domain
  local config = resolve_domain(domain)

  local d100 = math.random(100)
  local selection = nil
  if d100 < config.bounce then
    selection = config.bounces
  elseif d100 < config.bounce + config.defer then
    selection = config.defers
  end

  if selection then
    local choice = selection[math.random(#selection)]
    kumo.reject(choice.code, choice.msg)
  end

  msg:set_meta('queue', 'null')
end)

kumo.on('http_message_generated', function(msg)
  msg:set_meta('queue', 'null')
end)