-- WezTerm Agent Deck Plugin
-- Monitor and display AI coding agent status in terminal panes
local wezterm = require('wezterm')

local M = {}

-- Determine platform-specific separator
local is_windows = string.match(wezterm.target_triple or '', 'windows') ~= nil
local separator = is_windows and '\\' or '/'

-- Set up package.path for sub-modules
local function setup_package_path()
    local plugin_list = wezterm.plugin.list()
    if not plugin_list or #plugin_list == 0 then
        return nil
    end
    
    -- Find our plugin directory by looking for agent-deck in the path
    local plugin_dir = nil
    for _, plugin in ipairs(plugin_list) do
        if plugin.plugin_dir and plugin.plugin_dir:find('agent%-deck') then
            plugin_dir = plugin.plugin_dir
            break
        end
    end
    
    if not plugin_dir then
        -- Fallback: use the first plugin's directory (useful during local dev)
        plugin_dir = plugin_list[1].plugin_dir
    end
    
    if plugin_dir then
        -- Add plugin directory to package.path for requiring sub-modules
        local plugin_path = plugin_dir .. separator .. '?.lua'
        local components_path = plugin_dir .. separator .. 'components' .. separator .. '?.lua'
        
        if not package.path:find(plugin_path, 1, true) then
            package.path = package.path .. ';' .. plugin_path .. ';' .. components_path
        end
    end
    
    return plugin_dir
end

-- Initialize package path
local plugin_dir = setup_package_path()

-- Internal state
local state = {
    initialized = false,
    agent_states = {},  -- pane_id -> { agent_type, status, last_update, cooldown_start }
    last_notification = {},  -- pane_id -> timestamp
}

--[[ ============================================
     Configuration Management (inline)
     ============================================ ]]

local default_config = {
    update_interval = 5000,
    cooldown_ms = 2000,
    max_lines = 100,
    enabled_agents = nil,
    
    agents = {
        opencode = {
            patterns = { 'opencode' },
            executable_patterns = {
                'opencode%-darwin',
                'opencode%-linux',
                'opencode%-win',
                '%.opencode/bin/opencode',
                '/opencode%-ai/',
                '/opencode$',
            },
            argv_patterns = {
                'bunx%s+opencode',
                'npx%s+opencode',
                '/opencode$',
            },
            title_patterns = { 'opencode' },
        },
        claude = {
            patterns = { 'claude', 'claude%-code' },
            executable_patterns = {
                '@anthropic%-ai/claude%-code',
                '/claude%-code/',
                '/claude$',
                '^claude%s*$',
            },
            argv_patterns = {
                '@anthropic%-ai/claude%-code',
                'claude%-code',
                '^claude%s*$',
            },
            title_patterns = {
                'claude code',
                'claude',
            },
        },
        gemini = { patterns = { 'gemini' } },
        codex = { patterns = { 'codex' } },
        aider = { patterns = { 'aider' } },
    },
    
    tab_title = {
        enabled = true,
        position = 'left',
        components = {
            { type = 'icon' },
            { type = 'separator', text = ' ' },
        },
    },
    
    right_status = {
        enabled = true,
        components = {
            { type = 'badge', filter = 'waiting', label = 'waiting' },
            { type = 'separator', text = ' | ' },
            { type = 'badge', filter = 'working', label = 'working' },
        },
    },
    
    colors = {
        working = 'green',
        waiting = 'yellow',
        idle = 'blue',
        inactive = 'gray',
    },
    
    icons = {
        style = 'unicode',
        unicode = {
            working = '●',
            waiting = '◔',
            idle = '○',
            inactive = '◌',
        },
        nerd = {
            working = '',  -- nf-fa-circle
            waiting = '',  -- nf-fa-adjust
            idle = '',  -- nf-fa-circle_o
            inactive = '',  -- nf-cod-circle_outline
        },
        emoji = {
            working = '🟢',
            waiting = '🟡',
            idle = '🔵',
            inactive = '⚪',
        },
    },
    
    notifications = {
        enabled = true,
        on_waiting = true,
        timeout_ms = 4000,
        -- Notification backend: 'native' (wezterm toast) or 'terminal-notifier' (macOS only, supports sound)
        backend = 'native',
        -- terminal-notifier specific options (only used when backend = 'terminal-notifier')
        terminal_notifier = {
            path = nil,
            sound = 'default',
            group = 'wezterm-agent-deck',
            title = 'WezTerm Agent Deck',
            activate = true,
        },
    },
}

local current_config = nil

local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 0
    for _ in pairs(t) do
        i = i + 1
        if t[i] == nil then return false end
    end
    return i > 0
end

local function deep_merge(t1, t2)
    local result = {}
    for k, v in pairs(t1) do
        if type(v) == 'table' and type(t2[k]) == 'table' then
            if is_array(v) or is_array(t2[k]) then
                result[k] = t2[k]  -- arrays: replace wholesale
            else
                result[k] = deep_merge(v, t2[k])
            end
        elseif t2[k] ~= nil then
            result[k] = t2[k]
        else
            result[k] = v
        end
    end
    for k, v in pairs(t2) do
        if result[k] == nil then
            result[k] = v
        end
    end
    return result
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local result = {}
    for k, v in pairs(t) do
        result[k] = deep_copy(v)
    end
    return result
end

local function set_config(opts)
    if not opts then
        current_config = deep_copy(default_config)
    else
        current_config = deep_merge(default_config, opts)
    end
end

local function get_config()
    if not current_config then
        current_config = deep_copy(default_config)
    end
    return current_config
end

local function get_status_color(status_name)
    local cfg = get_config()
    return cfg.colors[status_name] or cfg.colors.inactive
end

local function get_status_icon(status_name)
    local cfg = get_config()
    local style = cfg.icons.style or 'unicode'
    local icons = cfg.icons[style] or cfg.icons.unicode
    return icons[status_name] or icons.inactive
end

--[[ ============================================
     Agent Detection (inline)
     ============================================ ]]

local detection_cache = {}
local CACHE_TTL_S = 5

local last_cache_prune = 0
local CACHE_PRUNE_INTERVAL_S = 60

local function prune_detection_cache()
    local now = os.time()
    if (now - last_cache_prune) < CACHE_PRUNE_INTERVAL_S then
        return
    end
    last_cache_prune = now
    for pane_id, entry in pairs(detection_cache) do
        if (now - entry.timestamp) >= CACHE_TTL_S then
            detection_cache[pane_id] = nil
        end
    end
end

local function get_executable_name(path)
    if not path then return '' end
    local name = path:match('[/\\]([^/\\]+)$') or path
    return name:gsub('%.exe$', '')
end

local function matches_any_pattern(str, patterns)
    if not str or not patterns then return false end
    local str_lower = str:lower()
    for _, pattern in ipairs(patterns) do
        local success, result = pcall(function()
            return str_lower:find(pattern:lower())
        end)
        if success and result then return true end
        if not success and str_lower:find(pattern:lower(), 1, true) then return true end
    end
    return false
end

local function is_agent_enabled(agent_name, config)
    if not config.enabled_agents then return true end
    for _, enabled in ipairs(config.enabled_agents) do
        if enabled == agent_name then return true end
    end
    return false
end

local function get_patterns_for_phase(agent_config, pattern_type, agent_name)
    local specific_key = pattern_type .. '_patterns'
    if agent_config[specific_key] and #agent_config[specific_key] > 0 then
        return agent_config[specific_key]
    end
    if agent_config.patterns and #agent_config.patterns > 0 then
        return agent_config.patterns
    end
    return { agent_name }
end

local function detect_from_process_info(executable, argv_str, config)
    local exe_name = get_executable_name(executable)
    for agent_name, agent_config in pairs(config.agents) do
        if is_agent_enabled(agent_name, config) then
            local exe_patterns = get_patterns_for_phase(agent_config, 'executable', agent_name)
            if matches_any_pattern(executable, exe_patterns) or matches_any_pattern(exe_name, exe_patterns) then
                return agent_name
            end
            local argv_patterns = get_patterns_for_phase(agent_config, 'argv', agent_name)
            if matches_any_pattern(argv_str, argv_patterns) then
                return agent_name
            end
        end
    end
    return nil
end

local function detect_from_title(pane_title, config)
    if not pane_title or pane_title == '' then return nil end
    for agent_name, agent_config in pairs(config.agents) do
        if is_agent_enabled(agent_name, config) then
            local title_patterns = get_patterns_for_phase(agent_config, 'title', agent_name)
            if matches_any_pattern(pane_title, title_patterns) then
                return agent_name
            end
        end
    end
    return nil
end

local function detect_agent(pane, config)
    local pane_id = pane:pane_id()
    local now = os.time()

    local cached = detection_cache[pane_id]
    if cached and (now - cached.timestamp) < CACHE_TTL_S then
        return cached.agent_type
    end
    
    local agent_type = nil
    
    local success, process_info = pcall(function()
        return pane:get_foreground_process_info()
    end)
    
    if success and process_info then
        local executable = process_info.executable or ''
        local name = process_info.name or ''
        local argv_str = table.concat(process_info.argv or {}, ' ')
        agent_type = detect_from_process_info(executable, argv_str, config)
        if not agent_type and name ~= '' then
            agent_type = detect_from_process_info(name, argv_str, config)
        end
        
        if not agent_type and process_info.children then
            for _, child in pairs(process_info.children) do
                local child_exe = child.executable or ''
                local child_name = child.name or ''
                local child_argv = table.concat(child.argv or {}, ' ')
                agent_type = detect_from_process_info(child_exe, child_argv, config)
                if not agent_type and child_name ~= '' then
                    agent_type = detect_from_process_info(child_name, child_argv, config)
                end
                if agent_type then break end
            end
        end
    end
    
    if not agent_type then
        local name_success, process_name = pcall(function()
            return pane:get_foreground_process_name()
        end)
        if name_success and process_name then
            agent_type = detect_from_process_info(process_name, '', config)
        end
    end
    
    if not agent_type then
        local title_success, pane_title = pcall(function()
            return pane:get_title()
        end)
        if title_success then
            agent_type = detect_from_title(pane_title, config)
        end
        if not agent_type then
            local prop_success, prop_title = pcall(function()
                return pane.title
            end)
            if prop_success and prop_title then
                agent_type = detect_from_title(prop_title, config)
            end
        end
    end
    
    detection_cache[pane_id] = { agent_type = agent_type, timestamp = now }
    return agent_type
end

--[[ ============================================
     Status Detection (inline)
     ============================================ ]]

-- Check if a string starts with a braille pattern character (U+2800-U+28FF).
-- Claude Code uses braille spinners in the pane title while working.
-- In UTF-8, braille block is: E2 A0 80 through E2 A3 BF.
-- Note: ✳ (U+2733, idle icon) is NOT braille and won't match.
local function starts_with_braille(s)
    if not s or #s < 3 then return false end
    local b1, b2, b3 = s:byte(1), s:byte(2), s:byte(3)
    return b1 == 0xE2 and b2 >= 0xA0 and b2 <= 0xA3 and b3 >= 0x80 and b3 <= 0xBF
end

local default_patterns = {
    -- Working: authoritative text indicators (checked after spinner chars)
    working = {
        'esc to interrupt',
        'esc interrupt',
        'ctrl%+c to interrupt',
    },
    -- Waiting: permission prompts and interactive questions
    waiting = {
        -- Permission dialogs
        'yes, allow once', 'yes, allow always',
        'allow once', 'allow always',
        'no, and tell claude what to do differently',
        'do you trust the files',
        -- Selection indicators
        '❯ yes', '❯ no', '❯ allow',
        -- Generic prompts
        'run this command%?', 'execute this%?',
        'continue%?', 'proceed%?',
        'approve this plan', 'do you want to proceed',
        '%(y/n%)', '%(Y/n%)', '%[y/n%]', '%[Y/n%]',
        '%(y/N%)', '%(Y/N%)', '%[y/N%]', '%[Y/N%]',
        -- OpenCode plan mode
        'enter confirm', 'esc dismiss', 'type your own answer',
    },
    idle = { '^>%s*$', '^> $', '^>$', '^❯%s*$', '^❯ $', '^❯$' },
}

local function strip_ansi(text)
    if not text then return '' end
    local result = text
    result = result:gsub('\27%[%d*;?%d*;?%d*[A-Za-z]', '')
    result = result:gsub('\27%].-\007', '')
    result = result:gsub('\27%].-\27\\', '')
    result = result:gsub('\27%[%?%d+[hl]', '')
    result = result:gsub('\27%[%d*[ABCDEFGJKST]', '')
    result = result:gsub('\27%[%d*;%d*[Hf]', '')
    result = result:gsub('\27%[[0-9;]*m', '')
    result = result:gsub('\r', '')
    return result
end

local function matches_any_status(text, patterns)
    if not text or not patterns then return false end
    local text_lower = text:lower()
    for _, pattern in ipairs(patterns) do
        local success, result = pcall(function()
            return text_lower:find(pattern:lower())
        end)
        if success and result then return true end
        if not success and text_lower:find(pattern:lower(), 1, true) then return true end
    end
    return false
end

local function get_last_lines(text, n)
    if not text then return '' end
    local lines = {}
    for line in text:gmatch('[^\n]+') do
        table.insert(lines, line)
    end
    local start = math.max(1, #lines - n + 1)
    local result = {}
    for i = start, #lines do
        table.insert(result, lines[i])
    end
    return table.concat(result, '\n')
end

-- ================================================================
-- Hook-based state detection via /tmp/wezterm-agent-deck/
-- Claude Code hooks write state files with session_id as key.
-- We match pane to state file by comparing CWDs.
-- ================================================================
local STATE_DIR = '/tmp/wezterm-agent-deck'
local state_file_cache = {}
local last_state_scan = 0
local STATE_SCAN_INTERVAL_S = 2

-- Normalize path: resolve /private/tmp <-> /tmp symlink on macOS
local function normalize_path(path)
    if not path then return nil end
    path = path:gsub('^/private/tmp', '/tmp')
    path = path:gsub('^/private/var', '/var')
    return path
end

-- Scan state files and build pid->state and cwd->state maps
local function scan_state_files()
    local now = os.time()
    if (now - last_state_scan) < STATE_SCAN_INTERVAL_S then
        return state_file_cache
    end
    last_state_scan = now

    local result = { by_pid = {}, by_cwd = {} }
    local priority = { waiting = 3, working = 2, idle = 1 }
    local dir_handle = io.popen('ls "' .. STATE_DIR .. '/"*.state 2>/dev/null')
    if dir_handle then
        for path in dir_handle:lines() do
            local session_id = path:match('/([^/]+)%.state$')
            if session_id then
                local sf = io.open(path)
                if sf then
                    local s = sf:read('*l')
                    sf:close()
                    if s then
                        -- Read PID and check if process is still alive
                        local pf = io.open(STATE_DIR .. '/' .. session_id .. '.pid')
                        if pf then
                            local pid = pf:read('*l')
                            pf:close()
                            if pid then
                                -- Check if process is alive (signal 0 = existence check)
                                local alive = os.execute('kill -0 ' .. pid .. ' 2>/dev/null')
                                if alive then
                                    result.by_pid[pid] = s
                                else
                                    -- Process dead, clean up stale state files
                                    os.remove(path)
                                    os.remove(STATE_DIR .. '/' .. session_id .. '.cwd')
                                    os.remove(STATE_DIR .. '/' .. session_id .. '.pid')
                                    s = nil  -- skip CWD mapping
                                end
                            end
                        end
                        -- Read CWD
                        local cf = io.open(STATE_DIR .. '/' .. session_id .. '.cwd')
                        if cf then
                            local cwd = normalize_path(cf:read('*l'))
                            cf:close()
                            if cwd then
                                local existing = result.by_cwd[cwd]
                                if not existing or (priority[s] or 0) > (priority[existing] or 0) then
                                    result.by_cwd[cwd] = s
                                end
                            end
                        end
                    end
                end
            end
        end
        dir_handle:close()
    end

    state_file_cache = result
    return result
end

-- Get pane's CWD
local function get_pane_cwd(pane)
    local ok, info = pcall(function()
        return pane:get_current_working_dir()
    end)
    if ok and info then
        local path = type(info) == 'string' and info or (info.file_path or tostring(info))
        path = path:gsub('^file://', ''):gsub('/$', '')
        path = path:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        return normalize_path(path)
    end
    return nil
end

-- Collect PIDs from pane's process tree
local function get_pane_pids(pane)
    local pids = {}
    local ok, info = pcall(function() return pane:get_foreground_process_info() end)
    if ok and info then
        if info.pid then pids[tostring(info.pid)] = true end
        if info.ppid then pids[tostring(info.ppid)] = true end
        if info.children then
            for _, child in pairs(info.children) do
                if child.pid then pids[tostring(child.pid)] = true end
            end
        end
    end
    -- Also try simpler API
    local ok2, pid = pcall(function() return pane:get_foreground_process_info().pid end)
    if ok2 and pid then pids[tostring(pid)] = true end
    return pids
end

local function detect_status(pane, agent_type, config)
    if not agent_type then return 'inactive' end

    -- Try hook-based state files (authoritative, no false positives)
    local states = scan_state_files()

    -- Match by PID first (most reliable)
    local pids = get_pane_pids(pane)
    for pid in pairs(pids) do
        local s = states.by_pid[pid]
        if s then return s end
    end

    -- Match by CWD (fallback)
    local cwd = get_pane_cwd(pane)
    if cwd then
        local s = states.by_cwd[cwd]
        if s then return s end
    end

    -- Fallback: text-based detection for agents without hooks
    local success, text = pcall(function()
        return pane:get_lines_as_text(config.max_lines or 100)
    end)

    if not success or not text or text == '' then
        return 'inactive'
    end

    local clean_text = strip_ansi(text)

    local agent_config = config.agents[agent_type]
    local patterns = default_patterns
    if agent_config and agent_config.status_patterns then
        patterns = {
            working = agent_config.status_patterns.working or default_patterns.working,
            waiting = agent_config.status_patterns.waiting or default_patterns.waiting,
            idle = agent_config.status_patterns.idle or default_patterns.idle,
        }
    end

    local all_lines = {}
    for line in clean_text:gmatch('[^\n]+') do
        table.insert(all_lines, line)
    end

    local function tail_lines(n)
        local start = math.max(1, #all_lines - n + 1)
        local r = {}
        for i = start, #all_lines do
            table.insert(r, all_lines[i])
        end
        return r
    end

    local last_10 = tail_lines(10)
    local last_10_text = table.concat(last_10, '\n')

    if matches_any_status(last_10_text, patterns.working) then
        return 'working'
    end

    return 'idle'
end

--[[ ============================================
     Rendering (inline)
     ============================================ ]]

local function get_default_title(tab)
    local pane = tab.active_pane
    local title = pane.title or ''
    if title == '' then
        local process_name = pane.foreground_process_name or ''
        if process_name ~= '' then
            title = process_name:match('[/\\]([^/\\]+)$') or process_name
        end
    end
    if title == '' then title = 'Terminal' end
    return title
end

local function render_icon(status_name)
    local icon = get_status_icon(status_name)
    local color = get_status_color(status_name)
    return {
        { Foreground = { Color = color } },
        { Text = icon },
        { Attribute = { Intensity = 'Normal' } },
    }
end

local function render_badge(counts, filter, label)
    local count = 0
    if filter == 'all' then
        for _, c in pairs(counts) do count = count + c end
    else
        count = counts[filter] or 0
    end
    
    if count == 0 then return {} end
    
    local color = get_status_color(filter ~= 'all' and filter or 'working')
    local text = tostring(count)
    if label then text = text .. ' ' .. label end
    
    return {
        { Foreground = { Color = color } },
        { Text = text },
        { Attribute = { Intensity = 'Normal' } },
    }
end

local function render_separator(text)
    return { { Text = text or ' ' } }
end

local function render_component(comp, context)
    local comp_type = comp.type
    
    if comp_type == 'icon' then
        return render_icon(context.status or 'inactive')
    elseif comp_type == 'separator' then
        return render_separator(comp.text)
    elseif comp_type == 'badge' then
        return render_badge(context.counts or {}, comp.filter or 'all', comp.label)
    elseif comp_type == 'label' then
        local format = comp.format or '{status}'
        local text = format:gsub('{status}', context.status or 'inactive')
        text = text:gsub('{agent_type}', context.agent_type or 'unknown')
        text = text:gsub('{agent_name}', context.agent_type or 'unknown')
        local color = get_status_color(context.status or 'inactive')
        return {
            { Foreground = { Color = color } },
            { Text = text },
            { Attribute = { Intensity = 'Normal' } },
        }
    elseif comp_type == 'agent_name' then
        local agent_type = context.agent_type or 'unknown'
        local text = comp.short and agent_type:sub(1, 1):upper() or agent_type
        local color = get_status_color(context.status or 'inactive')
        return {
            { Foreground = { Color = color } },
            { Text = text },
            { Attribute = { Intensity = 'Normal' } },
        }
    end
    
    return {}
end

local function render_components(component_list, context)
    local result = {}
    for _, comp in ipairs(component_list) do
        local items = render_component(comp, context)
        for _, item in ipairs(items) do
            table.insert(result, item)
        end
    end
    return result
end

local function render_tab_title(agent_state, tab, tab_config)
    local default_title = get_default_title(tab)
    
    if not agent_state then
        return { { Text = ' ' .. default_title .. ' ' } }
    end
    
    local context = {
        status = agent_state.status or 'inactive',
        agent_type = agent_state.agent_type,
    }
    
    local component_items = render_components(tab_config.components or {}, context)
    local result = { { Text = ' ' } }
    
    if tab_config.position == 'left' then
        for _, item in ipairs(component_items) do
            table.insert(result, item)
        end
        table.insert(result, { Text = default_title })
    else
        table.insert(result, { Text = default_title })
        for _, item in ipairs(component_items) do
            table.insert(result, item)
        end
    end
    
    table.insert(result, { Text = ' ' })
    return result
end

local function render_tab_title_multi(all_pane_states, tab, tab_config)
    local default_title = get_default_title(tab)
    local result = { { Text = ' ' } }
    
    if tab_config.position == 'left' then
        for i, pane_data in ipairs(all_pane_states) do
            local status = pane_data.state.status or 'inactive'
            local icon = get_status_icon(status)
            local color = get_status_color(status)
            table.insert(result, { Foreground = { Color = color } })
            table.insert(result, { Text = icon })
            if i < #all_pane_states then
                table.insert(result, { Text = '' })
            end
        end
        table.insert(result, { Attribute = { Intensity = 'Normal' } })
        table.insert(result, { Text = ' ' .. default_title })
    else
        table.insert(result, { Text = default_title .. ' ' })
        for i, pane_data in ipairs(all_pane_states) do
            local status = pane_data.state.status or 'inactive'
            local icon = get_status_icon(status)
            local color = get_status_color(status)
            table.insert(result, { Foreground = { Color = color } })
            table.insert(result, { Text = icon })
            if i < #all_pane_states then
                table.insert(result, { Text = '' })
            end
        end
        table.insert(result, { Attribute = { Intensity = 'Normal' } })
    end
    
    table.insert(result, { Text = ' ' })
    return result
end

local function render_right_status(counts)
    local cfg = get_config()
    local total = 0
    for _, count in pairs(counts) do total = total + count end
    if total == 0 then return {} end
    
    local context = { counts = counts }
    local result = render_components(cfg.right_status.components or {}, context)
    
    -- Filter empty items and trailing separators
    local filtered = {}
    local last_was_text = false
    for _, item in ipairs(result) do
        local is_separator = item.Text and item.Text:match('^[%s|%-]+$')
        local is_empty = item.Text and item.Text == ''
        if not is_empty then
            if is_separator and not last_was_text then
                -- skip
            else
                table.insert(filtered, item)
                last_was_text = item.Text and not item.Text:match('^[%s|%-]+$')
            end
        end
    end
    
    while #filtered > 0 do
        local last = filtered[#filtered]
        if last.Text and last.Text:match('^[%s|%-]+$') then
            table.remove(filtered)
        else
            break
        end
    end
    
    if #filtered > 0 then
        table.insert(filtered, 1, { Text = ' ' })
        table.insert(filtered, { Text = ' ' })
    end
    
    return filtered
end

--[[ ============================================
     Notifications (inline)
     ============================================ ]]

local MIN_NOTIFICATION_GAP_S = 10

local function shell_escape(str)
    if not str then return '' end
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

local function send_terminal_notifier(subtitle, message, config)
    local tn_config = config.notifications.terminal_notifier or {}
    local binary = tn_config.path or 'terminal-notifier'
    local title = tn_config.title or 'WezTerm Agent Deck'
    
    local cmd = binary
        .. ' -title ' .. shell_escape(title)
        .. ' -subtitle ' .. shell_escape(subtitle)
        .. ' -message ' .. shell_escape(message)
    
    if tn_config.sound then
        cmd = cmd .. ' -sound ' .. shell_escape(tn_config.sound)
    end
    
    if tn_config.group then
        cmd = cmd .. ' -group ' .. shell_escape(tn_config.group)
    end
    
    if tn_config.activate then
        cmd = cmd .. ' -sender com.github.wez.wezterm'
    end
    
    os.execute(cmd .. ' >/dev/null 2>&1 &')
    return true
end

local function notify_waiting(pane, agent_type, config)
    if not config.notifications.enabled or not config.notifications.on_waiting then
        return
    end
    
    local agent_names = {
        opencode = 'OpenCode',
        claude = 'Claude',
        gemini = 'Gemini',
        codex = 'Codex',
        aider = 'Aider',
    }
    local agent_name = agent_names[agent_type] or agent_type
    local subtitle = agent_name .. ' - Attention Needed'
    local message = 'Needs your input'
    local timeout_ms = config.notifications.timeout_ms or 4000
    local backend = config.notifications.backend or 'native'
    
    if backend == 'terminal-notifier' then
        if send_terminal_notifier(subtitle, message, config) then
            wezterm.log_info('[agent-deck] terminal-notifier sent: ' .. subtitle)
        end
        return
    end
    
    local tab = pane:tab()
    if not tab then
        wezterm.log_warn('[agent-deck] notification failed: pane has no tab')
        return
    end
    
    local mux_window = tab:window()
    if not mux_window then
        wezterm.log_warn('[agent-deck] notification failed: tab has no window')
        return
    end
    
    local gui_window = mux_window:gui_window()
    if not gui_window then
        wezterm.log_warn('[agent-deck] notification failed: mux_window has no gui_window (headless?)')
        return
    end
    
    gui_window:toast_notification(subtitle, message, nil, timeout_ms)
    wezterm.log_info('[agent-deck] notification sent: ' .. subtitle)
end

--[[ ============================================
     Core Plugin Logic
     ============================================ ]]

local function get_agent_state(pane_id)
    return state.agent_states[pane_id]
end

local function update_agent_state(pane, config)
    local pane_id = pane:pane_id()
    local current_state = state.agent_states[pane_id]
    local now = os.time()

    local agent_type = detect_agent(pane, config)
    
    if not agent_type then
        if current_state then
            local old_status = current_state.status
            state.agent_states[pane_id] = nil
            wezterm.emit('agent_deck.agent_finished', nil, pane, current_state.agent_type)
            if old_status ~= 'inactive' then
                wezterm.emit('agent_deck.status_changed', nil, pane, old_status, 'inactive', nil)
            end
        end
        return nil
    end
    
    local new_status = detect_status(pane, agent_type, config)
    
    if not current_state then
        current_state = {
            agent_type = agent_type,
            status = new_status,
            last_update = now,
            cooldown_start = nil,
        }
        state.agent_states[pane_id] = current_state
        wezterm.emit('agent_deck.agent_detected', nil, pane, agent_type)
        wezterm.emit('agent_deck.status_changed', nil, pane, 'inactive', new_status, agent_type)
        
        if new_status == 'waiting' then
            notify_waiting(pane, agent_type, config)
        end
        
        return current_state
    end
    
    local old_status = current_state.status
    
    -- Cooldown logic
    if old_status == 'working' and new_status == 'idle' then
        if not current_state.cooldown_start then
            current_state.cooldown_start = now
            current_state.last_update = now
            return current_state
        elseif (now - current_state.cooldown_start) < math.ceil(config.cooldown_ms / 1000) then
            current_state.last_update = now
            return current_state
        end
        current_state.cooldown_start = nil
    elseif new_status == 'working' then
        current_state.cooldown_start = nil
    end
    
    if old_status ~= new_status then
        current_state.status = new_status
        current_state.last_update = now
        wezterm.emit('agent_deck.status_changed', nil, pane, old_status, new_status, agent_type)
        
        if new_status == 'waiting' then
            local last_notify = state.last_notification[pane_id] or 0
            if (now - last_notify) > MIN_NOTIFICATION_GAP_S then
                notify_waiting(pane, agent_type, config)
                state.last_notification[pane_id] = now
                wezterm.emit('agent_deck.attention_needed', nil, pane, agent_type, 'waiting_for_input')
            end
        end
    else
        current_state.last_update = now
    end
    
    current_state.agent_type = agent_type
    return current_state
end

local function get_all_agent_states()
    return state.agent_states
end

local function count_agents_by_status()
    local counts = { working = 0, waiting = 0, idle = 0, inactive = 0 }
    for _, agent_state in pairs(state.agent_states) do
        local s = agent_state.status or 'inactive'
        counts[s] = (counts[s] or 0) + 1
    end
    return counts
end

--[[ ============================================
     Public API
     ============================================ ]]

function M.setup(opts)
    set_config(opts)
    state.initialized = true
    wezterm.log_info('[agent-deck] Plugin initialized')
end

function M.apply_to_config(config, opts)
    if opts then set_config(opts) end
    
    local plugin_config = get_config()
    config.status_update_interval = plugin_config.update_interval
    
    if plugin_config.tab_title.enabled then
        wezterm.on('format-tab-title', function(tab, tabs, panes, wezterm_config, hover, max_width)
            local active_pane_id = tab.active_pane.pane_id
            local all_pane_states = {}
            
            for _, pane_info in ipairs(tab.panes or {}) do
                local p_state = get_agent_state(pane_info.pane_id)
                if p_state then
                    table.insert(all_pane_states, {
                        state = p_state,
                        is_active = (pane_info.pane_id == active_pane_id)
                    })
                end
            end
            
            if #all_pane_states == 0 then
                return nil
            end
            
            return render_tab_title_multi(all_pane_states, tab, plugin_config.tab_title)
        end)
    end
    
    -- Status bar (right status)
    if plugin_config.right_status.enabled then
        wezterm.on('update-status', function(window, pane)
            prune_detection_cache()
            local active_panes = {}
            for _, mux_tab in ipairs(window:mux_window():tabs()) do
                for _, p in ipairs(mux_tab:panes()) do
                    active_panes[p:pane_id()] = true
                    update_agent_state(p, plugin_config)
                end
            end
            -- Prune stale state for closed panes
            for pane_id in pairs(state.agent_states) do
                if not active_panes[pane_id] then
                    state.agent_states[pane_id] = nil
                    state.last_notification[pane_id] = nil
                    detection_cache[pane_id] = nil
                end
            end

            local counts = count_agents_by_status()
            local right_status = render_right_status(counts)

            if right_status and #right_status > 0 then
                window:set_right_status(wezterm.format(right_status))
            end
        end)
    else
        wezterm.on('update-status', function(window, pane)
            prune_detection_cache()
            local active_panes = {}
            for _, mux_tab in ipairs(window:mux_window():tabs()) do
                for _, p in ipairs(mux_tab:panes()) do
                    active_panes[p:pane_id()] = true
                    update_agent_state(p, plugin_config)
                end
            end
            -- Prune stale state for closed panes
            for pane_id in pairs(state.agent_states) do
                if not active_panes[pane_id] then
                    state.agent_states[pane_id] = nil
                    state.last_notification[pane_id] = nil
                    detection_cache[pane_id] = nil
                end
            end
        end)
    end
    
    state.initialized = true
    wezterm.log_info('[agent-deck] Plugin applied to config')
end

-- Export for advanced users
M.get_agent_state = get_agent_state
M.get_all_agent_states = get_all_agent_states
M.count_agents_by_status = count_agents_by_status
M.get_config = get_config
M.set_config = set_config
M.get_status_color = get_status_color
M.get_status_icon = get_status_icon
M.update_pane = function(pane)
    return update_agent_state(pane, get_config())
end

return M
