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
    }
    CP.log(TAG, 'session: %s %s (%s)', tostring(o.departmentShort), tostring(o.rank), tostring(o.callsign))
end

function A.clear()
    current = nil
    roles = { officer = false, supervisor = false, admin = false }
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
