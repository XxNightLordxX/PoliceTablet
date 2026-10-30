-- CP.Access (client): the latest officer and department the server sent.

CP.Access = CP.Access or {}
local A = CP.Access
local TAG = 'access'

local current = nil
local roles = { officer = false, supervisor = false, admin = false }

local function CopyTable(t)
    if type(t) ~= 'table' then return nil end
    return CP.U.deepcopy(t)
end

-- CP.Options (modules/options/client.lua) compares the officer's options with the last ones: hooks, NUI message.
local function OptionsChanged()
    if CP.Options and CP.Options.refresh then CP.Options.refresh() end
end

function A.setSession(session)
    if type(session) ~= 'table' then return end
    if type(session.roles) == 'table' then
        roles = {
            officer = session.roles.officer == true,
            supervisor = session.roles.supervisor == true,
            admin = session.roles.admin == true,
        }
    end
    local o = session.officer
    if type(o) ~= 'table' then
        current = nil
        OptionsChanged()
        return
    end
    -- The Admin UI carries the admin theme: keep the department look from the last officer session.
    local theme, logo
    if session.ui == 'admin' then
        if current and current.department == o.department then
            theme, logo = current.theme, current.logo
        end
    else
        theme, logo = CopyTable(session.theme), CopyTable(session.logo)
    end
    current = {
        citizenid = o.citizenid,
        name = o.name,
        department = o.department,
        departmentLabel = o.departmentLabel,
        departmentShort = o.departmentShort,
        rank = o.rank,
        callsign = o.callsign,
        gradeLevel = o.gradeLevel,
        roles = CP.U.copy(roles),
        theme = theme,
        logo = logo,
        -- the officer's look (profile prefs) and options (CP.Options.get reads them)
        prefs = CopyTable(session.prefs),
        options = CopyTable(session.options),
        officerOptions = CopyTable(type(session.config) == 'table' and session.config.officerOptions or nil),
    }
    CP.log(TAG, 'session: %s %s (%s)', tostring(o.departmentShort), tostring(o.rank), tostring(o.callsign))
    OptionsChanged()
end

-- The push 'options' ({ values }): the officer's server options changed (My options on any of his tablets).
function A.setOptions(values)
    if not current or type(values) ~= 'table' then return end
    current.options = CopyTable(values)
    OptionsChanged()
end

function A.clear()
    current = nil
    roles = { officer = false, supervisor = false, admin = false }
    OptionsChanged()
end

function A.current()
    if not current then return nil end
    return CP.U.deepcopy(current)
end

function A.department()
    if not current then return nil end
    return {
        key = current.department,
        label = current.departmentLabel,
        short = current.departmentShort,
        theme = CopyTable(current.theme),
        logo = CopyTable(current.logo),
    }
end

-- The officer's options as the session gave them (CP.Options reads them; do not change the tables): the server
-- values, the resolved Config.OfficerOptions of his department ({ enabled, allow, defaults, bounds }), his department.
function A.optionsView()
    if not current then return nil, nil, nil end
    return current.options, current.officerOptions, current.department
end

function A.roles()
    return CP.U.copy(roles)
end

CreateThread(function()
    if not CP.Qbx then return end
    CP.Qbx.onUnload(function() A.clear() end)
    CP.Qbx.onDutyChange(function(onDuty)
        if not onDuty then
            current = nil
            roles.officer, roles.supervisor = false, false
        end
    end)
end)
